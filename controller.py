#!/usr/bin/env python3
"""
LotMonitor Real-time Controller

使用训练好的 MDP 模型进行实时拥塞控制。

功能:
1. 从内核模块读取 TCP 连接状态
2. 使用 DQN 模型决策 rwnd 调整
3. 通过 /proc/lotmonitor/control 发送控制指令

Usage:
    python3 controller.py start
    python3 controller.py start --model mdp_data/best_model.pth
    python3 controller.py stop
    python3 controller.py status
"""

import os
import sys
import time
import argparse
import json
import signal
import threading
from pathlib import Path
from dataclasses import dataclass
from typing import Dict, Optional, List, Tuple
from enum import IntEnum
from collections import deque
import numpy as np

# 导入本地模块
from collector import DataCollector, Sample, ConnectionState

# 尝试导入 PyTorch
try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False


# =============================================================================
# MDP 定义 (与 trainer.py 保持一致)
# =============================================================================

class Action(IntEnum):
    """动作空间: rwnd 调整因子"""
    DECREASE_LARGE = 0   # rwnd *= 0.5
    DECREASE_MEDIUM = 1  # rwnd *= 0.7
    DECREASE_SMALL = 2   # rwnd *= 0.9
    MAINTAIN = 3         # rwnd *= 1.0
    INCREASE_SMALL = 4   # rwnd *= 1.1
    INCREASE_MEDIUM = 5  # rwnd *= 1.3
    INCREASE_LARGE = 6   # rwnd *= 1.5


ACTION_FACTORS = {
    Action.DECREASE_LARGE: 0.5,
    Action.DECREASE_MEDIUM: 0.7,
    Action.DECREASE_SMALL: 0.9,
    Action.MAINTAIN: 1.0,
    Action.INCREASE_SMALL: 1.1,
    Action.INCREASE_MEDIUM: 1.3,
    Action.INCREASE_LARGE: 1.5,
}


@dataclass
class State:
    """MDP 状态"""
    rtt_ratio: float
    rtt_trend: float
    loss_rate: float
    utilization: float

    def to_array(self) -> np.ndarray:
        return np.array([
            min(self.rtt_ratio, 10.0) / 10.0,
            (self.rtt_trend + 1) / 2,
            min(self.loss_rate, 0.1) / 0.1,
            self.utilization,
        ], dtype=np.float32)

    def discretize(self) -> Tuple[int, int, int, int]:
        if self.rtt_ratio < 1.05:
            rtt_level = 0
        elif self.rtt_ratio < 1.15:
            rtt_level = 1
        elif self.rtt_ratio < 1.3:
            rtt_level = 2
        elif self.rtt_ratio < 1.5:
            rtt_level = 3
        elif self.rtt_ratio < 2.0:
            rtt_level = 4
        elif self.rtt_ratio < 3.0:
            rtt_level = 5
        elif self.rtt_ratio < 5.0:
            rtt_level = 6
        else:
            rtt_level = 7

        if self.loss_rate < 0.001:
            loss_level = 0
        elif self.loss_rate < 0.01:
            loss_level = 1
        elif self.loss_rate < 0.05:
            loss_level = 2
        else:
            loss_level = 3

        if self.utilization < 0.5:
            util_level = 0
        elif self.utilization < 0.8:
            util_level = 1
        elif self.utilization < 0.95:
            util_level = 2
        else:
            util_level = 3

        trend = int(self.rtt_trend) + 1

        return (rtt_level, loss_level, util_level, trend)


# =============================================================================
# DQN 网络 (与 trainer.py 保持一致)
# =============================================================================

if HAS_TORCH:
    class DQN(nn.Module):
        def __init__(self, state_dim=4, action_dim=7, hidden_dim=128):
            super(DQN, self).__init__()
            self.fc1 = nn.Linear(state_dim, hidden_dim)
            self.fc2 = nn.Linear(hidden_dim, hidden_dim)
            self.fc3 = nn.Linear(hidden_dim, action_dim)

        def forward(self, x):
            x = F.relu(self.fc1(x))
            x = F.relu(self.fc2(x))
            return self.fc3(x)


# =============================================================================
# 控制器
# =============================================================================

class Controller:
    """实时拥塞控制器"""

    PROC_CONTROL = "/proc/lotmonitor/control"
    RWND_MIN = 1460
    RWND_MAX = 65535
    RWND_DEFAULT = 65535

    def __init__(self, model_path: Optional[str] = None,
                 policy_table_path: Optional[str] = None):
        """
        初始化控制器

        Args:
            model_path: DQN 模型路径 (PyTorch)
            policy_table_path: 策略查找表路径 (JSON)
        """
        self.collector = DataCollector()
        self.running = False
        self.control_thread = None

        # 连接状态缓存
        self.conn_states: Dict[str, dict] = {}
        self.rtt_history: Dict[str, deque] = {}

        # 统计
        self.decisions = 0
        self.rwnd_changes = 0

        # 加载模型
        self.model = None
        self.policy_table = None

        if model_path and os.path.exists(model_path):
            self._load_model(model_path)
        elif policy_table_path and os.path.exists(policy_table_path):
            self._load_policy_table(policy_table_path)
        else:
            # 尝试加载默认模型
            default_model = "mdp_data/best_model.pth"
            default_table = "mdp_data/policy_table.json"

            if os.path.exists(default_model):
                self._load_model(default_model)
            elif os.path.exists(default_table):
                self._load_policy_table(default_table)
            else:
                print("Warning: No model found. Using heuristic policy.")

    def _load_model(self, path: str):
        """加载 DQN 模型"""
        if not HAS_TORCH:
            print("Warning: PyTorch not available. Cannot load DQN model.")
            return

        try:
            self.model = DQN()
            checkpoint = torch.load(path, map_location="cpu")
            self.model.load_state_dict(checkpoint["policy_net"])
            self.model.eval()
            print(f"已加载 DQN 模型: {path}")
        except Exception as e:
            print(f"加载模型失败: {e}")
            self.model = None

    def _load_policy_table(self, path: str):
        """加载策略查找表"""
        try:
            with open(path, "r") as f:
                table = json.load(f)
                # 转换键为整数
                self.policy_table = {int(k): v for k, v in table.items()}
            print(f"已加载策略表: {path} ({len(self.policy_table)} 条)")
        except Exception as e:
            print(f"加载策略表失败: {e}")
            self.policy_table = None

    def sample_to_state(self, sample: Sample) -> State:
        """将样本转换为 MDP 状态"""
        conn_key = f"{sample.saddr}:{sample.sport}->{sample.daddr}:{sample.dport}"

        # RTT ratio
        rtt_ratio = sample.curr_rtt / sample.min_rtt if sample.min_rtt > 0 else 1.0
        rtt_ratio = min(rtt_ratio, 10.0)

        # RTT 趋势
        if conn_key not in self.rtt_history:
            self.rtt_history[conn_key] = deque(maxlen=20)

        self.rtt_history[conn_key].append(sample.curr_rtt)
        history = self.rtt_history[conn_key]

        if len(history) >= 5:
            recent = np.mean(list(history)[-5:])
            older = np.mean(list(history)[-10:-5]) if len(history) >= 10 else recent
            if recent < older * 0.9:
                rtt_trend = -1.0
            elif recent > older * 1.1:
                rtt_trend = 1.0
            else:
                rtt_trend = 0.0
        else:
            rtt_trend = 0.0

        # 丢包率
        loss_rate = sample.loss_rate_ppm / 1_000_000.0

        # 窗口利用率
        utilization = sample.inflight / sample.rwnd if sample.rwnd > 0 else 0.0
        utilization = min(utilization, 1.0)

        return State(
            rtt_ratio=rtt_ratio,
            rtt_trend=rtt_trend,
            loss_rate=loss_rate,
            utilization=utilization,
        )

    def get_action(self, state: State) -> Action:
        """获取动作"""
        # 使用 DQN 模型
        if self.model is not None and HAS_TORCH:
            with torch.no_grad():
                state_tensor = torch.FloatTensor(state.to_array()).unsqueeze(0)
                q_values = self.model(state_tensor)
                return Action(q_values.argmax().item())

        # 使用策略查找表
        if self.policy_table is not None:
            discrete = state.discretize()
            key = (discrete[0] << 5) | (discrete[1] << 3) | (discrete[2] << 1) | discrete[3]
            if key in self.policy_table:
                return Action(self.policy_table[key])

        # 使用启发式策略
        return self._heuristic_policy(state)

    def _heuristic_policy(self, state: State) -> Action:
        """启发式策略 (BBR 风格)"""
        # 严重拥塞或丢包
        if state.loss_rate > 0.01 or state.rtt_ratio > 3.0:
            return Action.DECREASE_LARGE

        # 中等拥塞
        if state.rtt_ratio > 2.0:
            return Action.DECREASE_MEDIUM

        # 轻微拥塞
        if state.rtt_ratio > 1.5:
            return Action.DECREASE_SMALL

        # 有拥塞趋势
        if state.rtt_ratio > 1.2 or state.rtt_trend > 0.5:
            return Action.MAINTAIN

        # 低利用率，增加
        if state.utilization < 0.5:
            return Action.INCREASE_LARGE
        elif state.utilization < 0.8:
            return Action.INCREASE_MEDIUM
        else:
            return Action.INCREASE_SMALL

    def send_control(self, command: str):
        """发送控制命令到内核模块"""
        try:
            with open(self.PROC_CONTROL, "w") as f:
                f.write(command + "\n")
        except Exception as e:
            print(f"发送控制命令失败: {e}")

    def apply_action(self, daddr: str, dport: int, current_rwnd: int, action: Action) -> int:
        """应用动作"""
        factor = ACTION_FACTORS[action]
        new_rwnd = int(current_rwnd * factor)
        new_rwnd = max(self.RWND_MIN, min(self.RWND_MAX, new_rwnd))

        if new_rwnd != current_rwnd:
            self.send_control(f"{daddr}:{dport}={new_rwnd}")
            self.rwnd_changes += 1

        return new_rwnd

    def control_loop(self, interval: float = 0.1):
        """主控制循环"""
        print(f"\n开始控制循环 (间隔: {interval}s)")
        print("-" * 70)

        while self.running:
            try:
                # 读取样本
                samples = self.collector.read_samples()

                # 处理每个有效样本
                for sample in samples:
                    if sample.curr_rtt <= 0:
                        continue

                    conn_key = f"{sample.daddr}:{sample.dport}"

                    # 转换为状态
                    state = self.sample_to_state(sample)

                    # 获取动作
                    action = self.get_action(state)
                    self.decisions += 1

                    # 获取当前 rwnd (或使用默认值)
                    current_rwnd = self.conn_states.get(conn_key, {}).get(
                        "rwnd", self.RWND_DEFAULT)

                    # 应用动作
                    new_rwnd = self.apply_action(
                        sample.daddr, sample.dport, current_rwnd, action)

                    # 更新状态缓存
                    self.conn_states[conn_key] = {
                        "rwnd": new_rwnd,
                        "rtt_ratio": state.rtt_ratio,
                        "loss_rate": state.loss_rate,
                        "last_action": action.name,
                    }

                time.sleep(interval)

            except Exception as e:
                print(f"控制循环错误: {e}")
                time.sleep(1)

    def start(self, interval: float = 0.1):
        """启动控制器"""
        # 检查权限
        if not os.access(self.PROC_CONTROL, os.W_OK):
            print(f"错误: 无法写入 {self.PROC_CONTROL}")
            print("请使用 sudo 运行或检查模块是否加载")
            return False

        # 启用控制
        self.send_control("enable")

        self.running = True
        self.control_thread = threading.Thread(
            target=self.control_loop, args=(interval,))
        self.control_thread.daemon = True
        self.control_thread.start()

        print("控制器已启动")
        return True

    def stop(self):
        """停止控制器"""
        self.running = False

        if self.control_thread:
            self.control_thread.join(timeout=2)

        # 禁用控制并重置
        self.send_control("disable")
        self.send_control("reset")

        print(f"控制器已停止 (决策: {self.decisions}, rwnd变更: {self.rwnd_changes})")

    def status(self):
        """显示状态"""
        stats = self.collector.read_stats()

        print("=" * 60)
        print("LotMonitor 控制器状态")
        print("=" * 60)
        print(f"运行中: {self.running}")
        print(f"决策次数: {self.decisions}")
        print(f"rwnd 变更: {self.rwnd_changes}")
        print(f"活跃连接: {len(self.conn_states)}")
        print("-" * 60)
        print(f"模块状态:")
        print(f"  活跃连接: {stats.active_conns}")
        print(f"  控制启用: {stats.control_enabled}")
        print(f"  控制命令: {stats.control_cmds}")
        print(f"  rwnd 修改: {stats.rwnd_modifications}")
        print("=" * 60)

        # 显示连接详情
        if self.conn_states:
            print("\n活跃控制连接:")
            print(f"{'地址':30} {'rwnd':>8} {'RTT比':>8} {'丢包':>8} {'动作':>15}")
            print("-" * 75)

            for conn_key, state in list(self.conn_states.items())[:10]:
                print(f"{conn_key:30} {state['rwnd']:>8} "
                      f"{state['rtt_ratio']:>8.2f} {state['loss_rate']*100:>7.2f}% "
                      f"{state.get('last_action', 'N/A'):>15}")


# =============================================================================
# 交互式模式
# =============================================================================

def interactive_mode(controller: Controller):
    """交互式控制模式"""
    print("\n交互式控制模式 (输入 'help' 查看命令)")
    print("-" * 60)

    while True:
        try:
            cmd = input("\n> ").strip().lower()

            if cmd in ("quit", "exit", "q"):
                break
            elif cmd == "help":
                print("可用命令:")
                print("  status    - 显示状态")
                print("  start     - 启动控制")
                print("  stop      - 停止控制")
                print("  enable    - 启用 rwnd 控制")
                print("  disable   - 禁用 rwnd 控制")
                print("  reset     - 重置所有 rwnd")
                print("  all=N     - 设置所有连接的 rwnd 为 N")
                print("  quit      - 退出")
            elif cmd == "status":
                controller.status()
            elif cmd == "start":
                controller.start()
            elif cmd == "stop":
                controller.stop()
            elif cmd == "enable":
                controller.send_control("enable")
                print("控制已启用")
            elif cmd == "disable":
                controller.send_control("disable")
                print("控制已禁用")
            elif cmd == "reset":
                controller.send_control("reset")
                print("所有 rwnd 已重置")
            elif cmd.startswith("all="):
                controller.send_control(cmd)
                print(f"已发送: {cmd}")
            elif "=" in cmd:
                controller.send_control(cmd)
                print(f"已发送: {cmd}")
            else:
                print(f"未知命令: {cmd}")

        except KeyboardInterrupt:
            break
        except EOFError:
            break

    controller.stop()
    print("\n已退出")


# =============================================================================
# 主程序
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="LotMonitor Real-time Controller - MDP 实时拥塞控制"
    )

    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # start 命令
    start_parser = subparsers.add_parser("start", help="启动控制器")
    start_parser.add_argument("--model", "-m", type=str,
                             default="mdp_data/best_model.pth",
                             help="模型路径")
    start_parser.add_argument("--table", "-t", type=str,
                             help="策略表路径 (JSON)")
    start_parser.add_argument("--interval", "-i", type=float, default=0.1,
                             help="控制间隔 (秒)")
    start_parser.add_argument("--interactive", action="store_true",
                             help="交互式模式")

    # stop 命令
    subparsers.add_parser("stop", help="停止控制并重置")

    # status 命令
    subparsers.add_parser("status", help="显示状态")

    # interactive 命令
    inter_parser = subparsers.add_parser("interactive", help="交互式模式")
    inter_parser.add_argument("--model", "-m", type=str,
                             default="mdp_data/best_model.pth",
                             help="模型路径")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return

    try:
        if args.command == "start":
            controller = Controller(
                model_path=args.model,
                policy_table_path=args.table,
            )

            if args.interactive:
                controller.start(interval=args.interval)
                interactive_mode(controller)
            else:
                if controller.start(interval=args.interval):
                    print("按 Ctrl+C 停止...")
                    try:
                        while True:
                            time.sleep(1)
                            # 定期显示状态
                            stats = controller.collector.read_stats()
                            print(f"\r决策: {controller.decisions}, "
                                  f"rwnd变更: {controller.rwnd_changes}, "
                                  f"连接: {stats.active_conns}",
                                  end="", flush=True)
                    except KeyboardInterrupt:
                        print()
                    finally:
                        controller.stop()

        elif args.command == "stop":
            controller = Controller()
            controller.send_control("disable")
            controller.send_control("reset")
            print("控制已停止并重置")

        elif args.command == "status":
            controller = Controller()
            controller.status()

        elif args.command == "interactive":
            controller = Controller(model_path=args.model)
            interactive_mode(controller)

    except Exception as e:
        print(f"错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

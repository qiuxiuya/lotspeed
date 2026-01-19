#!/usr/bin/env python3
"""
LotMonitor DQN Trainer

使用 Deep Q-Network (DQN) 训练拥塞控制策略。

功能:
1. 从采集的数据训练 DQN 模型
2. 使用网络模拟器进行在线训练
3. 导出模型用于实时控制

Usage:
    python3 trainer.py train --episodes 500
    python3 trainer.py evaluate
    python3 trainer.py export
"""

import os
import sys
import argparse
import json
import csv
import random
from pathlib import Path
from dataclasses import dataclass
from typing import List, Tuple, Optional
from collections import deque
from enum import IntEnum

import numpy as np

# 尝试导入 PyTorch
try:
    import torch
    import torch.nn as nn
    import torch.optim as optim
    import torch.nn.functional as F
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False
    print("Warning: PyTorch not found. Using numpy-based Q-learning.")


# =============================================================================
# MDP 定义
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
    rtt_ratio: float      # curr_rtt / min_rtt (1.0-10.0)
    rtt_trend: float      # RTT 变化趋势 (-1, 0, 1)
    loss_rate: float      # 丢包率 (0-1)
    utilization: float    # 窗口利用率 (0-1)

    def to_array(self) -> np.ndarray:
        """转换为特征数组"""
        return np.array([
            min(self.rtt_ratio, 10.0) / 10.0,  # 归一化到 0-1
            (self.rtt_trend + 1) / 2,           # 归一化到 0-1
            min(self.loss_rate, 0.1) / 0.1,     # 归一化到 0-1
            self.utilization,
        ], dtype=np.float32)

    def discretize(self) -> Tuple[int, int, int, int]:
        """离散化状态 (用于 Q-table)"""
        # RTT ratio: 0-7
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

        # Loss rate: 0-3
        if self.loss_rate < 0.001:
            loss_level = 0
        elif self.loss_rate < 0.01:
            loss_level = 1
        elif self.loss_rate < 0.05:
            loss_level = 2
        else:
            loss_level = 3

        # Utilization: 0-3
        if self.utilization < 0.5:
            util_level = 0
        elif self.utilization < 0.8:
            util_level = 1
        elif self.utilization < 0.95:
            util_level = 2
        else:
            util_level = 3

        # Trend: 0-2
        trend = int(self.rtt_trend) + 1  # -1,0,1 -> 0,1,2

        return (rtt_level, loss_level, util_level, trend)


# =============================================================================
# 网络模拟器
# =============================================================================

class NetworkSimulator:
    """简化的网络模拟器用于训练"""

    def __init__(self, bandwidth_mbps=100, base_rtt_ms=20, buffer_pkts=100):
        self.bandwidth = bandwidth_mbps * 1e6 / 8  # bytes/sec
        self.base_rtt = base_rtt_ms / 1000
        self.buffer_size = buffer_pkts
        self.mss = 1500

        self.reset()

    def reset(self):
        """重置环境"""
        self.rwnd = 65535
        self.inflight = 0
        self.queue_len = 0
        self.packets_sent = 0
        self.packets_lost = 0
        self.bytes_acked = 0
        self.time = 0

        self.rtt_history = [self.base_rtt]
        self.min_rtt = self.base_rtt

        return self._get_state()

    def step(self, action: Action) -> Tuple[State, float, bool, dict]:
        """执行一步"""
        # 应用动作到 rwnd
        factor = ACTION_FACTORS[action]
        self.rwnd = int(max(1460, min(65535, self.rwnd * factor)))

        # 模拟发送
        can_send = min(self.rwnd // self.mss, 10) - self.inflight
        for _ in range(max(0, can_send)):
            self.packets_sent += 1
            if self.queue_len < self.buffer_size:
                self.queue_len += 1
                self.inflight += 1
            else:
                self.packets_lost += 1

        # 模拟时间和 ACK
        self.time += 0.01  # 10ms
        drain = int(self.bandwidth / self.mss * 0.01)
        acked = min(drain, self.queue_len, self.inflight)
        self.queue_len = max(0, self.queue_len - drain)
        self.inflight = max(0, self.inflight - acked)
        self.bytes_acked += acked * self.mss

        # 计算 RTT
        queue_delay = self.queue_len * self.mss / self.bandwidth
        curr_rtt = self.base_rtt + queue_delay
        self.rtt_history.append(curr_rtt)
        if len(self.rtt_history) > 100:
            self.rtt_history.pop(0)

        # 获取状态
        state = self._get_state()

        # 计算奖励
        reward = self._calculate_reward(acked, curr_rtt)

        # 检查结束
        done = self.time > 30  # 30秒

        info = {
            "rwnd": self.rwnd,
            "rtt_ms": curr_rtt * 1000,
            "loss_rate": self.packets_lost / max(1, self.packets_sent),
            "throughput_mbps": self.bytes_acked * 8 / (self.time * 1e6),
        }

        return state, reward, done, info

    def _get_state(self) -> State:
        """获取当前状态"""
        curr_rtt = self.rtt_history[-1] if self.rtt_history else self.base_rtt
        rtt_ratio = curr_rtt / self.min_rtt if self.min_rtt > 0 else 1.0

        # RTT 趋势
        if len(self.rtt_history) >= 5:
            recent = np.mean(self.rtt_history[-5:])
            older = np.mean(self.rtt_history[-10:-5]) if len(self.rtt_history) >= 10 else recent
            if recent < older * 0.9:
                trend = -1.0
            elif recent > older * 1.1:
                trend = 1.0
            else:
                trend = 0.0
        else:
            trend = 0.0

        loss_rate = self.packets_lost / max(1, self.packets_sent)
        utilization = self.inflight * self.mss / max(1, self.rwnd)

        return State(
            rtt_ratio=rtt_ratio,
            rtt_trend=trend,
            loss_rate=loss_rate,
            utilization=min(1.0, utilization),
        )

    def _calculate_reward(self, acked: int, curr_rtt: float) -> float:
        """计算奖励"""
        # 吞吐量奖励
        throughput_reward = acked * self.mss / self.bandwidth

        # 延迟惩罚
        delay_penalty = max(0, (curr_rtt / self.min_rtt - 1)) * 0.3

        # 丢包惩罚
        loss_rate = self.packets_lost / max(1, self.packets_sent)
        loss_penalty = loss_rate * 5

        return throughput_reward - delay_penalty - loss_penalty


# =============================================================================
# DQN 网络
# =============================================================================

if HAS_TORCH:
    class DQN(nn.Module):
        """Deep Q-Network"""

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
# 经验回放
# =============================================================================

class ReplayBuffer:
    """经验回放缓冲区"""

    def __init__(self, capacity=10000):
        self.buffer = deque(maxlen=capacity)

    def push(self, state, action, reward, next_state, done):
        self.buffer.append((state, action, reward, next_state, done))

    def sample(self, batch_size):
        batch = random.sample(self.buffer, min(batch_size, len(self.buffer)))
        states, actions, rewards, next_states, dones = zip(*batch)
        return (
            np.array([s.to_array() for s in states]),
            np.array(actions),
            np.array(rewards, dtype=np.float32),
            np.array([s.to_array() for s in next_states]),
            np.array(dones, dtype=np.float32),
        )

    def __len__(self):
        return len(self.buffer)


# =============================================================================
# DQN Agent
# =============================================================================

class DQNAgent:
    """DQN 智能体"""

    def __init__(self, state_dim=4, action_dim=7, lr=1e-3, gamma=0.99,
                 epsilon_start=1.0, epsilon_end=0.01, epsilon_decay=0.995):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.gamma = gamma

        self.epsilon = epsilon_start
        self.epsilon_end = epsilon_end
        self.epsilon_decay = epsilon_decay

        if HAS_TORCH:
            self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
            self.policy_net = DQN(state_dim, action_dim).to(self.device)
            self.target_net = DQN(state_dim, action_dim).to(self.device)
            self.target_net.load_state_dict(self.policy_net.state_dict())
            self.optimizer = optim.Adam(self.policy_net.parameters(), lr=lr)
        else:
            # 使用 Q-table
            self.q_table = np.zeros((8, 4, 4, 3, action_dim))
            self.lr = lr

        self.replay_buffer = ReplayBuffer()
        self.batch_size = 64
        self.target_update = 10

    def select_action(self, state: State, explore=True) -> Action:
        """选择动作"""
        if explore and random.random() < self.epsilon:
            return Action(random.randint(0, self.action_dim - 1))

        if HAS_TORCH:
            with torch.no_grad():
                state_tensor = torch.FloatTensor(state.to_array()).unsqueeze(0).to(self.device)
                q_values = self.policy_net(state_tensor)
                return Action(q_values.argmax().item())
        else:
            discrete_state = state.discretize()
            q_values = self.q_table[discrete_state]
            return Action(np.argmax(q_values))

    def update(self, state, action, reward, next_state, done):
        """更新模型"""
        self.replay_buffer.push(state, action, reward, next_state, done)

        if len(self.replay_buffer) < self.batch_size:
            return 0.0

        if HAS_TORCH:
            return self._update_dqn()
        else:
            return self._update_q_table(state, action, reward, next_state, done)

    def _update_dqn(self) -> float:
        """DQN 更新"""
        states, actions, rewards, next_states, dones = self.replay_buffer.sample(self.batch_size)

        states = torch.FloatTensor(states).to(self.device)
        actions = torch.LongTensor(actions).to(self.device)
        rewards = torch.FloatTensor(rewards).to(self.device)
        next_states = torch.FloatTensor(next_states).to(self.device)
        dones = torch.FloatTensor(dones).to(self.device)

        # 当前 Q 值
        current_q = self.policy_net(states).gather(1, actions.unsqueeze(1))

        # 目标 Q 值
        with torch.no_grad():
            next_q = self.target_net(next_states).max(1)[0]
            target_q = rewards + self.gamma * next_q * (1 - dones)

        # 损失
        loss = F.mse_loss(current_q.squeeze(), target_q)

        # 优化
        self.optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(self.policy_net.parameters(), 1.0)
        self.optimizer.step()

        return loss.item()

    def _update_q_table(self, state, action, reward, next_state, done) -> float:
        """Q-table 更新"""
        s = state.discretize()
        s_next = next_state.discretize()
        a = int(action)

        if done:
            target = reward
        else:
            target = reward + self.gamma * np.max(self.q_table[s_next])

        old_q = self.q_table[s + (a,)]
        self.q_table[s + (a,)] += self.lr * (target - old_q)

        return abs(target - old_q)

    def update_target(self):
        """更新目标网络"""
        if HAS_TORCH:
            self.target_net.load_state_dict(self.policy_net.state_dict())

    def decay_epsilon(self):
        """衰减探索率"""
        self.epsilon = max(self.epsilon_end, self.epsilon * self.epsilon_decay)

    def save(self, path: str):
        """保存模型"""
        if HAS_TORCH:
            torch.save({
                "policy_net": self.policy_net.state_dict(),
                "target_net": self.target_net.state_dict(),
                "optimizer": self.optimizer.state_dict(),
                "epsilon": self.epsilon,
            }, path)
        else:
            np.savez(path, q_table=self.q_table, epsilon=self.epsilon)

        print(f"模型已保存到: {path}")

    def load(self, path: str):
        """加载模型"""
        if HAS_TORCH:
            checkpoint = torch.load(path, map_location=self.device)
            self.policy_net.load_state_dict(checkpoint["policy_net"])
            self.target_net.load_state_dict(checkpoint["target_net"])
            self.optimizer.load_state_dict(checkpoint["optimizer"])
            self.epsilon = checkpoint["epsilon"]
        else:
            data = np.load(path)
            self.q_table = data["q_table"]
            self.epsilon = float(data["epsilon"])

        print(f"模型已加载: {path}")


# =============================================================================
# 训练
# =============================================================================

def train(episodes: int = 500, data_dir: str = "mdp_data"):
    """训练 DQN 模型"""
    data_dir = Path(data_dir)
    data_dir.mkdir(exist_ok=True)

    env = NetworkSimulator()
    agent = DQNAgent()

    print("=" * 60)
    print("开始 DQN 训练")
    print(f"后端: {'PyTorch' if HAS_TORCH else 'NumPy Q-table'}")
    print(f"回合数: {episodes}")
    print("=" * 60)

    rewards_history = []
    best_reward = float("-inf")

    for episode in range(episodes):
        state = env.reset()
        episode_reward = 0
        losses = []

        while True:
            action = agent.select_action(state, explore=True)
            next_state, reward, done, info = env.step(action)

            loss = agent.update(state, action, reward, next_state, done)
            if loss > 0:
                losses.append(loss)

            episode_reward += reward
            state = next_state

            if done:
                break

        # 更新目标网络
        if episode % agent.target_update == 0:
            agent.update_target()

        agent.decay_epsilon()
        rewards_history.append(episode_reward)

        # 保存最佳模型
        if episode_reward > best_reward:
            best_reward = episode_reward
            agent.save(str(data_dir / "best_model.pth"))

        # 打印进度
        if (episode + 1) % 10 == 0:
            avg_reward = np.mean(rewards_history[-10:])
            avg_loss = np.mean(losses) if losses else 0
            print(f"Episode {episode+1:4d}: "
                  f"reward={episode_reward:8.2f}, "
                  f"avg={avg_reward:8.2f}, "
                  f"best={best_reward:8.2f}, "
                  f"loss={avg_loss:.4f}, "
                  f"epsilon={agent.epsilon:.3f}")

    # 保存最终模型
    agent.save(str(data_dir / "final_model.pth"))

    # 保存训练历史
    with open(data_dir / "training_history.json", "w") as f:
        json.dump({
            "rewards": rewards_history,
            "best_reward": best_reward,
        }, f)

    print()
    print("=" * 60)
    print(f"训练完成!")
    print(f"最佳奖励: {best_reward:.2f}")
    print(f"最终平均奖励: {np.mean(rewards_history[-10:]):.2f}")
    print("=" * 60)

    return agent


def evaluate(model_path: str = "mdp_data/best_model.pth"):
    """评估模型"""
    env = NetworkSimulator()
    agent = DQNAgent()

    try:
        agent.load(model_path)
    except FileNotFoundError:
        print(f"模型文件不存在: {model_path}")
        print("请先运行训练: python3 trainer.py train")
        return

    print("=" * 60)
    print("模型评估")
    print("=" * 60)

    # 定义基线策略
    def aimd_policy(state):
        if state.loss_rate > 0.01:
            return Action.DECREASE_LARGE
        elif state.rtt_ratio > 2.0:
            return Action.DECREASE_SMALL
        else:
            return Action.INCREASE_SMALL

    def bbr_policy(state):
        if state.rtt_ratio > 1.25:
            return Action.DECREASE_SMALL
        elif state.utilization < 0.8:
            return Action.INCREASE_MEDIUM
        else:
            return Action.MAINTAIN

    def random_policy(state):
        return Action(random.randint(0, 6))

    def dqn_policy(state):
        return agent.select_action(state, explore=False)

    # 运行评估
    policies = [
        ("Random", random_policy),
        ("AIMD", aimd_policy),
        ("BBR-style", bbr_policy),
        ("DQN (trained)", dqn_policy),
    ]

    print(f"{'Policy':>15} | {'Reward':>10} | {'Throughput':>12} | {'Loss %':>8} | {'Avg RTT':>10}")
    print("-" * 65)

    for name, policy_fn in policies:
        total_rewards = []
        total_tps = []
        total_losses = []
        total_rtts = []

        for _ in range(10):  # 10次评估
            state = env.reset()
            episode_reward = 0

            while True:
                action = policy_fn(state)
                state, reward, done, info = env.step(action)
                episode_reward += reward

                if done:
                    total_rewards.append(episode_reward)
                    total_tps.append(info["throughput_mbps"])
                    total_losses.append(info["loss_rate"] * 100)
                    total_rtts.append(info["rtt_ms"])
                    break

        print(f"{name:>15} | {np.mean(total_rewards):10.2f} | "
              f"{np.mean(total_tps):10.2f} Mbps | "
              f"{np.mean(total_losses):8.2f} | "
              f"{np.mean(total_rtts):10.2f} ms")

    print("=" * 65)


def export_model(model_path: str = "mdp_data/best_model.pth",
                 output_path: str = "mdp_data/policy_table.json"):
    """导出模型为查找表格式 (用于内核模块)"""
    agent = DQNAgent()

    try:
        agent.load(model_path)
    except FileNotFoundError:
        print(f"模型文件不存在: {model_path}")
        return

    print("导出策略表...")

    policy_table = {}

    # 遍历所有离散状态
    for rtt_level in range(8):
        for loss_level in range(4):
            for util_level in range(4):
                for trend in range(3):
                    # 创建状态
                    rtt_ratio = [1.0, 1.1, 1.2, 1.4, 1.7, 2.5, 4.0, 6.0][rtt_level]
                    loss_rate = [0, 0.005, 0.03, 0.1][loss_level]
                    utilization = [0.25, 0.65, 0.9, 1.0][util_level]
                    rtt_trend = trend - 1  # 0,1,2 -> -1,0,1

                    state = State(
                        rtt_ratio=rtt_ratio,
                        rtt_trend=rtt_trend,
                        loss_rate=loss_rate,
                        utilization=utilization,
                    )

                    action = agent.select_action(state, explore=False)

                    # 状态键
                    key = (rtt_level << 5) | (loss_level << 3) | (util_level << 1) | trend
                    policy_table[key] = int(action)

    # 保存
    with open(output_path, "w") as f:
        json.dump(policy_table, f, indent=2)

    print(f"策略表已导出到: {output_path}")
    print(f"共 {len(policy_table)} 个状态")


# =============================================================================
# 主程序
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="LotMonitor DQN Trainer - MDP 拥塞控制训练器"
    )

    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # train 命令
    train_parser = subparsers.add_parser("train", help="训练模型")
    train_parser.add_argument("--episodes", "-e", type=int, default=500,
                             help="训练回合数")

    # evaluate 命令
    eval_parser = subparsers.add_parser("evaluate", help="评估模型")
    eval_parser.add_argument("--model", "-m", type=str,
                            default="mdp_data/best_model.pth",
                            help="模型路径")

    # export 命令
    export_parser = subparsers.add_parser("export", help="导出策略表")
    export_parser.add_argument("--model", "-m", type=str,
                              default="mdp_data/best_model.pth",
                              help="模型路径")
    export_parser.add_argument("--output", "-o", type=str,
                              default="mdp_data/policy_table.json",
                              help="输出路径")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return

    if args.command == "train":
        train(episodes=args.episodes)
    elif args.command == "evaluate":
        evaluate(model_path=args.model)
    elif args.command == "export":
        export_model(model_path=args.model, output_path=args.output)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
MDP 实时控制演示

演示如何使用训练好的 MDP 模型进行实时拥塞控制决策。
这个演示使用模拟数据，展示完整的控制流程。

Usage: python3 realtime_control_demo.py
"""

import time
import random
import threading
import queue
from dataclasses import dataclass
from enum import IntEnum
from typing import List, Tuple, Optional
import numpy as np

# =============================================================================
# MDP 定义
# =============================================================================

class Action(IntEnum):
    """动作空间"""
    DECREASE_LARGE = 0   # cwnd *= 0.5
    DECREASE_MEDIUM = 1  # cwnd *= 0.75
    DECREASE_SMALL = 2   # cwnd *= 0.9
    MAINTAIN = 3         # cwnd *= 1.0
    INCREASE_SMALL = 4   # cwnd *= 1.05
    INCREASE_MEDIUM = 5  # cwnd *= 1.1
    INCREASE_LARGE = 6   # cwnd *= 1.25

ACTION_FACTORS = {
    Action.DECREASE_LARGE: 0.5,
    Action.DECREASE_MEDIUM: 0.75,
    Action.DECREASE_SMALL: 0.9,
    Action.MAINTAIN: 1.0,
    Action.INCREASE_SMALL: 1.05,
    Action.INCREASE_MEDIUM: 1.1,
    Action.INCREASE_LARGE: 1.25,
}

@dataclass
class State:
    """MDP 状态"""
    rtt_ratio: float      # curr_rtt / min_rtt (延迟膨胀)
    rtt_trend: int        # -1/0/1 (下降/稳定/上升)
    loss_rate: float      # 丢包率
    utilization: float    # 窗口利用率

    def discretize(self) -> Tuple[int, int, int, int]:
        """离散化状态用于 Q 表查询"""
        # RTT ratio -> 0-7
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

        # Loss rate -> 0-3
        if self.loss_rate < 0.001:
            loss_level = 0
        elif self.loss_rate < 0.01:
            loss_level = 1
        elif self.loss_rate < 0.05:
            loss_level = 2
        else:
            loss_level = 3

        # Utilization -> 0-3
        if self.utilization < 0.5:
            util_level = 0
        elif self.utilization < 0.8:
            util_level = 1
        elif self.utilization < 0.95:
            util_level = 2
        else:
            util_level = 3

        # Trend -> 0-2
        trend = self.rtt_trend + 1  # -1,0,1 -> 0,1,2

        return (rtt_level, loss_level, util_level, trend)


# =============================================================================
# Q-Learning 训练器
# =============================================================================

class QLearningAgent:
    """Q-Learning 智能体"""

    def __init__(self, state_dims=(8, 4, 4, 3), n_actions=7,
                 lr=0.1, gamma=0.99, epsilon=0.1):
        self.state_dims = state_dims
        self.n_actions = n_actions
        self.lr = lr
        self.gamma = gamma
        self.epsilon = epsilon

        # Q 表: state_dims + (n_actions,)
        self.q_table = np.zeros(state_dims + (n_actions,))

        # 统计
        self.total_updates = 0

    def get_action(self, state: State, explore=True) -> Action:
        """选择动作 (epsilon-greedy)"""
        discrete_state = state.discretize()

        if explore and random.random() < self.epsilon:
            return Action(random.randint(0, self.n_actions - 1))

        q_values = self.q_table[discrete_state]
        return Action(np.argmax(q_values))

    def update(self, state: State, action: Action, reward: float,
               next_state: State, done: bool):
        """更新 Q 值"""
        s = state.discretize()
        a = int(action)
        s_next = next_state.discretize()

        # Q-Learning 更新
        if done:
            target = reward
        else:
            target = reward + self.gamma * np.max(self.q_table[s_next])

        self.q_table[s + (a,)] += self.lr * (target - self.q_table[s + (a,)])
        self.total_updates += 1

    def save(self, path: str):
        """保存 Q 表"""
        np.savez(path, q_table=self.q_table)
        print(f"Model saved to {path}")

    def load(self, path: str):
        """加载 Q 表"""
        data = np.load(path)
        self.q_table = data['q_table']
        print(f"Model loaded from {path}")


# =============================================================================
# 网络环境模拟器
# =============================================================================

class NetworkSimulator:
    """模拟网络环境"""

    def __init__(self, bandwidth_mbps=100, base_rtt_ms=20,
                 buffer_packets=100, random_loss=0.001):
        self.bandwidth = bandwidth_mbps * 1e6 / 8  # bytes/sec
        self.base_rtt = base_rtt_ms / 1000  # seconds
        self.buffer_size = buffer_packets
        self.random_loss = random_loss

        # 状态
        self.cwnd = 10  # packets
        self.inflight = 0
        self.queue_len = 0
        self.bytes_sent = 0
        self.bytes_acked = 0
        self.packets_lost = 0
        self.packets_sent = 0

        # RTT 历史
        self.rtt_history = [self.base_rtt]
        self.min_rtt = self.base_rtt

        # 时间
        self.time = 0
        self.last_ack_time = 0

    def step(self, action: Action) -> Tuple[State, float, bool]:
        """执行一步模拟"""
        # 应用动作
        factor = ACTION_FACTORS[action]
        self.cwnd = max(2, min(1000, int(self.cwnd * factor)))

        # 模拟发送
        packets_to_send = min(self.cwnd - self.inflight, 10)
        for _ in range(packets_to_send):
            self.send_packet()

        # 模拟时间流逝和 ACK
        self.time += 0.01  # 10ms 步长
        self.process_acks()

        # 计算当前状态
        curr_rtt = self.get_current_rtt()
        self.rtt_history.append(curr_rtt)
        if len(self.rtt_history) > 100:
            self.rtt_history.pop(0)

        state = self.get_state()

        # 计算奖励
        reward = self.calculate_reward()

        # 检查是否结束
        done = self.time > 60  # 60 秒模拟

        return state, reward, done

    def send_packet(self):
        """发送一个数据包"""
        self.packets_sent += 1
        self.bytes_sent += 1500  # MSS

        # 检查随机丢包
        if random.random() < self.random_loss:
            self.packets_lost += 1
            return

        # 入队
        if self.queue_len < self.buffer_size:
            self.queue_len += 1
            self.inflight += 1
        else:
            # 缓冲区满，丢包
            self.packets_lost += 1

    def process_acks(self):
        """处理 ACK"""
        # 计算在途时间内到达的 ACK
        rtt = self.get_current_rtt()
        acks_expected = max(0, self.inflight - int(self.cwnd * 0.1))

        for _ in range(acks_expected):
            if self.inflight > 0:
                self.inflight -= 1
                self.bytes_acked += 1500

        # 队列排空
        drain_rate = self.bandwidth / 1500  # packets/sec
        drained = int(drain_rate * 0.01)  # 10ms 内排空的包数
        self.queue_len = max(0, self.queue_len - drained)

    def get_current_rtt(self) -> float:
        """计算当前 RTT"""
        # RTT = 基础 RTT + 队列延迟
        queue_delay = self.queue_len * 1500 / self.bandwidth
        return self.base_rtt + queue_delay

    def get_state(self) -> State:
        """获取当前状态"""
        curr_rtt = self.get_current_rtt()

        # RTT ratio
        rtt_ratio = curr_rtt / self.min_rtt if self.min_rtt > 0 else 1.0

        # RTT trend
        if len(self.rtt_history) >= 2:
            recent = np.mean(self.rtt_history[-5:])
            older = np.mean(self.rtt_history[-10:-5]) if len(self.rtt_history) >= 10 else recent
            if recent < older * 0.9:
                trend = -1
            elif recent > older * 1.1:
                trend = 1
            else:
                trend = 0
        else:
            trend = 0

        # Loss rate
        loss_rate = self.packets_lost / max(1, self.packets_sent)

        # Utilization
        utilization = self.inflight / max(1, self.cwnd)

        return State(
            rtt_ratio=rtt_ratio,
            rtt_trend=trend,
            loss_rate=loss_rate,
            utilization=utilization
        )

    def calculate_reward(self) -> float:
        """计算奖励函数"""
        curr_rtt = self.get_current_rtt()
        loss_rate = self.packets_lost / max(1, self.packets_sent)

        # 吞吐量 (归一化)
        throughput = self.bytes_acked / max(1, self.time)
        normalized_tp = throughput / self.bandwidth

        # 延迟惩罚
        delay_penalty = max(0, (curr_rtt / self.min_rtt - 1)) * 0.5

        # 丢包惩罚
        loss_penalty = loss_rate * 10

        # 总奖励
        reward = normalized_tp - delay_penalty - loss_penalty

        return reward

    def reset(self):
        """重置环境"""
        self.cwnd = 10
        self.inflight = 0
        self.queue_len = 0
        self.bytes_sent = 0
        self.bytes_acked = 0
        self.packets_lost = 0
        self.packets_sent = 0
        self.rtt_history = [self.base_rtt]
        self.time = 0


# =============================================================================
# 实时控制演示
# =============================================================================

class RealtimeController:
    """实时控制器"""

    def __init__(self, agent: QLearningAgent):
        self.agent = agent
        self.running = False
        self.metrics_queue = queue.Queue()

    def control_loop(self, env: NetworkSimulator):
        """主控制循环"""
        state = env.get_state()
        episode_reward = 0
        step = 0

        print("\n" + "=" * 70)
        print("实时控制演示开始")
        print("=" * 70)
        print(f"{'Step':>5} | {'cwnd':>6} | {'RTT(ms)':>8} | {'Loss%':>6} | "
              f"{'Action':>15} | {'Reward':>8}")
        print("-" * 70)

        while self.running:
            # 获取动作
            action = self.agent.get_action(state, explore=False)

            # 执行动作
            next_state, reward, done = env.step(action)

            # 显示状态
            curr_rtt_ms = env.get_current_rtt() * 1000
            loss_pct = (env.packets_lost / max(1, env.packets_sent)) * 100

            action_name = Action(action).name
            print(f"{step:5d} | {env.cwnd:6d} | {curr_rtt_ms:8.2f} | "
                  f"{loss_pct:6.2f} | {action_name:>15} | {reward:8.4f}")

            # 记录指标
            self.metrics_queue.put({
                'step': step,
                'cwnd': env.cwnd,
                'rtt_ms': curr_rtt_ms,
                'loss_pct': loss_pct,
                'throughput_mbps': (env.bytes_acked / max(1, env.time)) * 8 / 1e6,
                'reward': reward,
            })

            episode_reward += reward
            state = next_state
            step += 1

            if done:
                break

            time.sleep(0.05)  # 50ms 显示间隔

        print("-" * 70)
        print(f"Episode finished. Total reward: {episode_reward:.2f}")

    def start(self, env: NetworkSimulator):
        """启动控制"""
        self.running = True
        thread = threading.Thread(target=self.control_loop, args=(env,))
        thread.start()
        return thread

    def stop(self):
        """停止控制"""
        self.running = False


# =============================================================================
# 训练流程
# =============================================================================

def train_agent(episodes=100, verbose=True):
    """训练 MDP 智能体"""
    agent = QLearningAgent(lr=0.1, gamma=0.99, epsilon=0.2)
    env = NetworkSimulator(bandwidth_mbps=100, base_rtt_ms=20)

    best_reward = float('-inf')
    rewards_history = []

    print("=" * 60)
    print("开始训练 MDP 智能体")
    print("=" * 60)

    for episode in range(episodes):
        env.reset()
        state = env.get_state()
        episode_reward = 0
        steps = 0

        # 逐渐减少探索率
        agent.epsilon = max(0.01, 0.2 - episode * 0.002)

        while True:
            action = agent.get_action(state, explore=True)
            next_state, reward, done = env.step(action)
            agent.update(state, action, reward, next_state, done)

            episode_reward += reward
            state = next_state
            steps += 1

            if done or steps > 6000:
                break

        rewards_history.append(episode_reward)

        if episode_reward > best_reward:
            best_reward = episode_reward

        if verbose and (episode + 1) % 10 == 0:
            avg_reward = np.mean(rewards_history[-10:])
            print(f"Episode {episode+1:3d}: reward={episode_reward:8.2f}, "
                  f"avg={avg_reward:8.2f}, best={best_reward:8.2f}, "
                  f"epsilon={agent.epsilon:.3f}")

    print("\n训练完成!")
    print(f"最佳奖励: {best_reward:.2f}")
    print(f"最终平均奖励: {np.mean(rewards_history[-10:]):.2f}")

    return agent


def run_demo():
    """运行完整演示"""
    print("=" * 70)
    print("MDP 拥塞控制演示")
    print("=" * 70)

    # Phase 1: 训练
    print("\n[Phase 1] 训练 Q-Learning 智能体...")
    agent = train_agent(episodes=50, verbose=True)

    # Phase 2: 保存模型
    print("\n[Phase 2] 保存模型...")
    agent.save("mdp_data/q_model.npz")

    # Phase 3: 实时控制演示
    print("\n[Phase 3] 实时控制演示...")
    input("按 Enter 开始实时控制演示...")

    env = NetworkSimulator(bandwidth_mbps=100, base_rtt_ms=20)
    controller = RealtimeController(agent)

    try:
        thread = controller.start(env)
        thread.join(timeout=30)  # 最多运行 30 秒
    except KeyboardInterrupt:
        print("\n用户中断")
    finally:
        controller.stop()

    # Phase 4: 与基线对比
    print("\n[Phase 4] 与基线算法对比...")
    compare_with_baselines(agent)


def compare_with_baselines(trained_agent: QLearningAgent):
    """与基线算法对比"""

    def run_episode(agent_fn, name):
        env = NetworkSimulator(bandwidth_mbps=100, base_rtt_ms=20)
        total_reward = 0
        total_throughput = 0
        total_loss = 0
        steps = 0

        while steps < 6000:
            state = env.get_state()
            action = agent_fn(state, env)
            _, reward, done = env.step(action)
            total_reward += reward
            steps += 1
            if done:
                break

        throughput_mbps = (env.bytes_acked / max(1, env.time)) * 8 / 1e6
        loss_pct = (env.packets_lost / max(1, env.packets_sent)) * 100

        return total_reward, throughput_mbps, loss_pct

    # 基线1: 固定 AIMD (类似 Reno)
    def aimd_policy(state, env):
        if state.loss_rate > 0.01:
            return Action.DECREASE_LARGE
        elif state.rtt_ratio > 2.0:
            return Action.DECREASE_SMALL
        else:
            return Action.INCREASE_SMALL

    # 基线2: 固定 BBR 风格
    def bbr_style_policy(state, env):
        if state.rtt_ratio > 1.25:
            return Action.DECREASE_SMALL
        elif state.utilization < 0.8:
            return Action.INCREASE_MEDIUM
        else:
            return Action.MAINTAIN

    # 基线3: 随机策略
    def random_policy(state, env):
        return Action(random.randint(0, 6))

    # MDP 策略
    def mdp_policy(state, env):
        return trained_agent.get_action(state, explore=False)

    print("\n" + "=" * 60)
    print("算法对比结果")
    print("=" * 60)
    print(f"{'Algorithm':>15} | {'Reward':>10} | {'Throughput':>12} | {'Loss %':>8}")
    print("-" * 60)

    for name, policy in [
        ("AIMD (Reno)", aimd_policy),
        ("BBR-style", bbr_style_policy),
        ("Random", random_policy),
        ("MDP (Trained)", mdp_policy),
    ]:
        reward, tp, loss = run_episode(policy, name)
        print(f"{name:>15} | {reward:10.2f} | {tp:10.2f} Mbps | {loss:8.2f}")

    print("=" * 60)


# =============================================================================
# 主程序
# =============================================================================

if __name__ == '__main__':
    import os
    os.makedirs("mdp_data", exist_ok=True)
    run_demo()

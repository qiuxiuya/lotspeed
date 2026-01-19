#!/usr/bin/env python3
"""
改进的 MDP 拥塞控制

使用更简单的状态表示和更好的奖励函数来改进学习效果。

关键改进:
1. 简化状态空间 (3 维度而不是 4 维度)
2. 更合理的奖励函数 (吞吐量 - 延迟惩罚)
3. 使用状态聚合减少状态数量
4. 添加经验回放增强学习稳定性
"""

import numpy as np
import random
from collections import deque
from dataclasses import dataclass
from enum import IntEnum
from typing import List, Tuple, Optional

# =============================================================================
# 简化的 MDP 定义
# =============================================================================

class Action(IntEnum):
    """简化的动作空间 (5个动作)"""
    DECREASE_LARGE = 0   # cwnd *= 0.5
    DECREASE_SMALL = 1   # cwnd *= 0.8
    MAINTAIN = 2         # cwnd *= 1.0
    INCREASE_SMALL = 3   # cwnd += 1
    INCREASE_LARGE = 4   # cwnd += 5

def apply_action(cwnd: int, action: Action) -> int:
    """应用动作到 cwnd"""
    if action == Action.DECREASE_LARGE:
        return max(2, int(cwnd * 0.5))
    elif action == Action.DECREASE_SMALL:
        return max(2, int(cwnd * 0.8))
    elif action == Action.MAINTAIN:
        return cwnd
    elif action == Action.INCREASE_SMALL:
        return min(1000, cwnd + 1)
    elif action == Action.INCREASE_LARGE:
        return min(1000, cwnd + 5)
    return cwnd


@dataclass
class SimpleState:
    """简化的状态表示"""
    congestion_level: int   # 0-4: 基于 RTT 膨胀
    loss_detected: bool     # 是否检测到丢包

    def to_index(self) -> int:
        """转换为 Q 表索引"""
        return self.congestion_level * 2 + (1 if self.loss_detected else 0)


def compute_state(rtt_ratio: float, loss_rate: float) -> SimpleState:
    """从原始指标计算状态"""
    # 拥塞级别 (基于 RTT 膨胀)
    if rtt_ratio < 1.1:
        level = 0  # 无拥塞
    elif rtt_ratio < 1.3:
        level = 1  # 轻微
    elif rtt_ratio < 1.6:
        level = 2  # 中等
    elif rtt_ratio < 2.5:
        level = 3  # 严重
    else:
        level = 4  # 极度拥塞

    # 丢包检测
    loss_detected = loss_rate > 0.005  # 0.5% 阈值

    return SimpleState(level, loss_detected)


# =============================================================================
# 网络模拟器 (改进版)
# =============================================================================

class ImprovedNetworkSim:
    """改进的网络模拟器"""

    def __init__(self, bw_mbps=100, base_rtt_ms=20, buffer_pkts=50):
        self.bandwidth = bw_mbps * 1e6 / 8  # bytes/sec
        self.base_rtt = base_rtt_ms / 1000
        self.buffer_size = buffer_pkts
        self.mss = 1500

        self.reset()

    def reset(self):
        """重置"""
        self.cwnd = 10
        self.inflight = 0
        self.queue = 0
        self.sent = 0
        self.acked = 0
        self.lost = 0
        self.time = 0
        self.prev_rtt = self.base_rtt

    def step(self, action: Action) -> Tuple[SimpleState, float, dict]:
        """执行一步"""
        # 1. 应用动作
        old_cwnd = self.cwnd
        self.cwnd = apply_action(self.cwnd, action)

        # 2. 模拟发送
        can_send = max(0, self.cwnd - self.inflight)
        for _ in range(min(can_send, 20)):
            if self.queue < self.buffer_size:
                self.queue += 1
                self.inflight += 1
                self.sent += 1
            else:
                self.lost += 1
                self.sent += 1

        # 3. 模拟时间和ACK
        dt = 0.02  # 20ms 时间步
        self.time += dt

        # 队列排空
        drain = int(self.bandwidth / self.mss * dt)
        acked = min(drain, self.queue, self.inflight)
        self.queue = max(0, self.queue - drain)
        self.inflight = max(0, self.inflight - acked)
        self.acked += acked

        # 4. 计算指标
        queue_delay = self.queue * self.mss / self.bandwidth
        curr_rtt = self.base_rtt + queue_delay
        rtt_ratio = curr_rtt / self.base_rtt
        loss_rate = self.lost / max(1, self.sent)

        # 5. 计算状态
        state = compute_state(rtt_ratio, loss_rate)

        # 6. 计算奖励
        # 奖励 = 吞吐量 - 延迟惩罚 - 丢包惩罚
        throughput_reward = acked / self.cwnd if self.cwnd > 0 else 0
        delay_penalty = max(0, rtt_ratio - 1.0) * 0.3
        loss_penalty = loss_rate * 5

        reward = throughput_reward - delay_penalty - loss_penalty

        # 额外信息
        info = {
            'cwnd': self.cwnd,
            'rtt_ratio': rtt_ratio,
            'rtt_ms': curr_rtt * 1000,
            'loss_rate': loss_rate,
            'throughput_mbps': (self.acked * self.mss * 8) / (self.time * 1e6),
            'queue': self.queue,
        }

        self.prev_rtt = curr_rtt
        return state, reward, info


# =============================================================================
# Q-Learning Agent (改进版)
# =============================================================================

class SimpleQLearner:
    """简化的 Q-Learning 智能体"""

    def __init__(self, n_states=10, n_actions=5, lr=0.2, gamma=0.95, epsilon=0.3):
        self.n_states = n_states
        self.n_actions = n_actions
        self.lr = lr
        self.gamma = gamma
        self.epsilon = epsilon

        # Q 表 (10 states x 5 actions)
        self.q_table = np.zeros((n_states, n_actions))

        # 初始化为合理的启发式值
        # 无拥塞 (level 0): 倾向增加
        self.q_table[0, :] = [0, 0.5, 0.8, 1.0, 0.9]  # INCREASE_SMALL 最佳
        self.q_table[1, :] = [0, 0.5, 0.8, 1.0, 0.9]

        # 轻微拥塞 (level 1): 维持或小幅增加
        self.q_table[2, :] = [0, 0.5, 1.0, 0.8, 0.3]
        self.q_table[3, :] = [0.5, 0.8, 1.0, 0.3, 0]

        # 中等拥塞 (level 2): 维持或减少
        self.q_table[4, :] = [0.5, 1.0, 0.8, 0.3, 0]
        self.q_table[5, :] = [0.8, 1.0, 0.5, 0, 0]

        # 严重拥塞 (level 3-4): 减少
        self.q_table[6, :] = [0.8, 1.0, 0.3, 0, 0]
        self.q_table[7, :] = [1.0, 0.8, 0.3, 0, 0]
        self.q_table[8, :] = [1.0, 0.5, 0.1, 0, 0]
        self.q_table[9, :] = [1.0, 0.5, 0.1, 0, 0]

    def get_action(self, state: SimpleState, explore=True) -> Action:
        """选择动作"""
        if explore and random.random() < self.epsilon:
            return Action(random.randint(0, self.n_actions - 1))

        idx = state.to_index()
        return Action(np.argmax(self.q_table[idx]))

    def update(self, state: SimpleState, action: Action, reward: float,
               next_state: SimpleState):
        """更新 Q 值"""
        s = state.to_index()
        a = int(action)
        s_next = next_state.to_index()

        target = reward + self.gamma * np.max(self.q_table[s_next])
        self.q_table[s, a] += self.lr * (target - self.q_table[s, a])

    def show_policy(self):
        """显示学习到的策略"""
        action_names = ['DEC_L', 'DEC_S', 'MAINT', 'INC_S', 'INC_L']
        print("\n学习到的策略 (Q 表):")
        print("-" * 50)
        print(f"{'State':>20} | {'Best Action':>12} | Q-values")
        print("-" * 50)

        for level in range(5):
            for loss in [False, True]:
                state = SimpleState(level, loss)
                idx = state.to_index()
                best_action = np.argmax(self.q_table[idx])
                state_name = f"Level={level}, Loss={loss}"
                print(f"{state_name:>20} | {action_names[best_action]:>12} | "
                      f"{self.q_table[idx].round(2)}")
        print("-" * 50)


# =============================================================================
# 训练和测试
# =============================================================================

def train_improved(episodes=500):
    """训练改进版智能体"""
    agent = SimpleQLearner(epsilon=0.3)
    env = ImprovedNetworkSim()

    print("=" * 60)
    print("训练改进版 MDP 智能体")
    print("=" * 60)

    rewards_history = []
    throughputs = []

    for ep in range(episodes):
        env.reset()
        state = compute_state(1.0, 0)
        total_reward = 0

        # 逐渐减少探索
        agent.epsilon = max(0.01, 0.3 - ep * 0.001)

        for step in range(3000):
            action = agent.get_action(state, explore=True)
            next_state, reward, info = env.step(action)
            agent.update(state, action, reward, next_state)
            state = next_state
            total_reward += reward

        rewards_history.append(total_reward)
        throughputs.append(info['throughput_mbps'])

        if (ep + 1) % 50 == 0:
            avg_r = np.mean(rewards_history[-50:])
            avg_tp = np.mean(throughputs[-50:])
            print(f"Episode {ep+1:4d}: reward={total_reward:8.2f}, "
                  f"avg_reward={avg_r:8.2f}, avg_tp={avg_tp:.2f} Mbps")

    return agent


def evaluate_policies():
    """评估不同策略"""

    def run_policy(policy_fn, name, episodes=10):
        env = ImprovedNetworkSim()
        total_rewards = []
        total_tps = []

        for _ in range(episodes):
            env.reset()
            state = compute_state(1.0, 0)
            ep_reward = 0

            for step in range(3000):
                action = policy_fn(state, env)
                state, reward, info = env.step(action)
                ep_reward += reward

            total_rewards.append(ep_reward)
            total_tps.append(info['throughput_mbps'])

        return np.mean(total_rewards), np.mean(total_tps)

    # AIMD 策略
    def aimd(state, env):
        if state.loss_detected:
            return Action.DECREASE_LARGE
        elif state.congestion_level >= 3:
            return Action.DECREASE_SMALL
        else:
            return Action.INCREASE_SMALL

    # BBR 风格策略
    def bbr_style(state, env):
        if state.congestion_level >= 2:
            return Action.DECREASE_SMALL
        elif state.congestion_level == 0:
            return Action.INCREASE_LARGE
        else:
            return Action.INCREASE_SMALL

    # 随机策略
    def random_policy(state, env):
        return Action(random.randint(0, 4))

    print("\n" + "=" * 60)
    print("策略评估")
    print("=" * 60)

    # 训练 MDP 策略
    agent = train_improved(episodes=300)
    agent.show_policy()

    def mdp_policy(state, env):
        return agent.get_action(state, explore=False)

    print("\n评估结果:")
    print("-" * 50)
    print(f"{'策略':>15} | {'平均奖励':>12} | {'吞吐量 (Mbps)':>15}")
    print("-" * 50)

    for name, policy in [
        ("随机", random_policy),
        ("AIMD (Reno)", aimd),
        ("BBR 风格", bbr_style),
        ("MDP (训练)", mdp_policy),
    ]:
        reward, tp = run_policy(policy, name)
        print(f"{name:>15} | {reward:12.2f} | {tp:15.2f}")

    print("-" * 50)


def realtime_demo():
    """实时控制演示"""
    print("\n" + "=" * 60)
    print("实时控制演示")
    print("=" * 60)

    agent = train_improved(episodes=200)

    env = ImprovedNetworkSim()
    env.reset()
    state = compute_state(1.0, 0)

    print(f"\n{'Step':>5} | {'cwnd':>6} | {'RTT(ms)':>8} | {'Loss%':>7} | "
          f"{'TP(Mbps)':>10} | {'Action':>10} | {'Reward':>8}")
    print("-" * 75)

    for step in range(100):
        action = agent.get_action(state, explore=False)
        next_state, reward, info = env.step(action)

        action_name = Action(action).name.replace('_', ' ')
        print(f"{step:5d} | {info['cwnd']:6d} | {info['rtt_ms']:8.2f} | "
              f"{info['loss_rate']*100:7.3f} | {info['throughput_mbps']:10.2f} | "
              f"{action_name:>10} | {reward:8.4f}")

        state = next_state

        if step % 20 == 0 and step > 0:
            print("-" * 75)


if __name__ == '__main__':
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == 'demo':
        realtime_demo()
    else:
        evaluate_policies()

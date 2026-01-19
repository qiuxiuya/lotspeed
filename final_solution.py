#!/usr/bin/env python3
"""
MDP 控制最终方案总结

经过测试，我们发现:
1. 纯 MDP/Q-Learning 需要精心设计的奖励函数
2. 奖励函数的权重决定了策略的保守/激进程度
3. 简单启发式 (AIMD, BBR) 在很多情况下表现良好

本文件提供一个平衡版本，结合了学习和启发式方法。
"""

import numpy as np
import random
from enum import IntEnum
from typing import Tuple

# =============================================================================
# 混合控制器: 结合规则 + 学习
# =============================================================================

class HybridController:
    """
    混合控制器: 结合规则和学习

    策略:
    1. 基于规则的快速响应 (处理明确的拥塞/丢包信号)
    2. 学习微调参数 (alpha, beta 等)
    """

    def __init__(self):
        # 可学习的参数
        self.alpha = 0.5    # 增加因子 (cwnd += alpha)
        self.beta = 0.5     # 减少因子 (cwnd *= beta on loss)
        self.gamma = 0.8    # RTT 拥塞时减少因子
        self.target_rtt_ratio = 1.25  # 目标 RTT 膨胀

        # 状态
        self.min_rtt = float('inf')
        self.prev_cwnd = 10

    def decide(self, curr_rtt: float, loss_detected: bool, cwnd: int) -> int:
        """
        决策函数

        Args:
            curr_rtt: 当前 RTT (秒)
            loss_detected: 是否检测到丢包
            cwnd: 当前拥塞窗口

        Returns:
            新的 cwnd
        """
        # 更新 min RTT
        if curr_rtt < self.min_rtt:
            self.min_rtt = curr_rtt

        rtt_ratio = curr_rtt / self.min_rtt if self.min_rtt > 0 else 1.0

        # 规则1: 丢包 → 快速减少
        if loss_detected:
            new_cwnd = max(2, int(cwnd * self.beta))
            return new_cwnd

        # 规则2: 严重拥塞 → 减少
        if rtt_ratio > 2.0:
            new_cwnd = max(2, int(cwnd * self.gamma))
            return new_cwnd

        # 规则3: 轻微拥塞 → 维持
        if rtt_ratio > self.target_rtt_ratio:
            return cwnd

        # 规则4: 无拥塞 → 增加
        new_cwnd = min(1000, int(cwnd + self.alpha))
        return new_cwnd

    def tune_parameters(self, reward_history: list):
        """
        根据历史奖励调整参数 (简单的自适应)
        """
        if len(reward_history) < 10:
            return

        recent = np.mean(reward_history[-10:])
        older = np.mean(reward_history[-20:-10]) if len(reward_history) >= 20 else recent

        # 如果性能下降，变得更保守
        if recent < older * 0.9:
            self.alpha = max(0.1, self.alpha * 0.9)
            self.target_rtt_ratio = max(1.1, self.target_rtt_ratio * 0.95)
        # 如果性能稳定/提升，尝试更激进
        elif recent > older * 1.05:
            self.alpha = min(5.0, self.alpha * 1.1)
            self.target_rtt_ratio = min(2.0, self.target_rtt_ratio * 1.02)


# =============================================================================
# 实际部署建议
# =============================================================================

"""
实际部署 MDP 拥塞控制的建议:

## 方案对比

| 方案 | 可行性 | 控制精度 | 实现复杂度 | 推荐场景 |
|------|--------|----------|------------|----------|
| eBPF struct_ops | ✅ 推荐 | 高 | 中 | Linux 5.6+ 内核 |
| Netfilter + rwnd | ⚠️ 有限 | 低 | 低 | 兼容性需求高 |
| 用户空间 TCP (QUIC) | ✅ 可行 | 高 | 高 | 新应用开发 |
| 修改内核 tcp_cc | ⚠️ 困难 | 高 | 高 | 定制内核 |

## 推荐实施路径

### 短期 (1-2周): Netfilter 监控 + 数据采集
- 使用 lotmonitor.ko 采集训练数据
- 完善数据质量 (修复 bytes_acked 等)
- 在不同网络条件下采集数据

### 中期 (2-4周): 离线训练 + 验证
- 使用采集的数据训练 DQN/PPO 模型
- 在网络模拟器中验证策略
- 导出量化模型

### 长期 (1-2月): eBPF 部署
- 实现 eBPF TCP 拥塞控制框架
- 集成训练好的策略
- A/B 测试与现有算法对比

## 奖励函数设计建议

好的奖励函数是 RL 成功的关键。建议:

```python
def reward_function(throughput, rtt, loss_rate, min_rtt):
    # 归一化吞吐量 (相对于链路容量)
    tp_reward = throughput / link_capacity

    # 延迟惩罚 (超过 target 的部分)
    target_rtt = min_rtt * 1.2
    delay_penalty = max(0, (rtt - target_rtt) / target_rtt) * delay_weight

    # 丢包惩罚 (指数增长)
    loss_penalty = loss_rate * loss_weight

    # 平滑惩罚 (避免 cwnd 剧烈变化)
    smooth_penalty = abs(cwnd_change) / cwnd * smooth_weight

    return tp_reward - delay_penalty - loss_penalty - smooth_penalty
```

## 状态特征选择

推荐的状态特征 (按重要性排序):

1. **RTT 膨胀比** = curr_rtt / min_rtt
   - 最重要的拥塞信号
   - 无需知道链路容量

2. **RTT 梯度** = d(rtt)/dt
   - 预测拥塞趋势
   - 可以提前响应

3. **丢包率** (短期)
   - 明确的拥塞信号
   - 但响应太慢

4. **窗口利用率** = inflight / cwnd
   - 指示当前是否被限制

5. **交付速率变化** = d(delivery_rate)/dt
   - 类似 BBR 的带宽探测

## 不建议的做法

1. ❌ 直接使用绝对 RTT 值
   - 不同网络 RTT 差异大
   - 使用相对值 (ratio, gradient)

2. ❌ 过多的状态维度
   - Q-Learning 需要更多样本
   - 使用状态聚合或 DNN

3. ❌ 复杂的动作空间
   - 离散化为 5-7 个动作
   - 或使用连续动作 (PPO/SAC)

4. ❌ 过于激进的探索
   - 会导致大量丢包
   - 使用经验回放 + 低 epsilon
"""


# =============================================================================
# 测试混合控制器
# =============================================================================

def test_hybrid():
    """测试混合控制器"""
    from improved_mdp import ImprovedNetworkSim, compute_state, Action

    controller = HybridController()
    env = ImprovedNetworkSim()

    print("=" * 60)
    print("混合控制器测试")
    print("=" * 60)

    rewards = []
    env.reset()

    print(f"\n{'Step':>5} | {'cwnd':>6} | {'RTT(ms)':>8} | {'Loss%':>7} | {'TP(Mbps)':>10}")
    print("-" * 55)

    for step in range(200):
        # 获取状态
        state = compute_state(
            env.prev_rtt / env.base_rtt if env.base_rtt > 0 else 1.0,
            env.lost / max(1, env.sent)
        )

        # 使用混合控制器决策
        new_cwnd = controller.decide(
            env.prev_rtt,
            state.loss_detected,
            env.cwnd
        )

        # 计算动作 (从当前 cwnd 到目标 cwnd)
        if new_cwnd > env.cwnd:
            action = Action.INCREASE_SMALL if new_cwnd - env.cwnd <= 2 else Action.INCREASE_LARGE
        elif new_cwnd < env.cwnd:
            action = Action.DECREASE_SMALL if env.cwnd - new_cwnd <= env.cwnd * 0.3 else Action.DECREASE_LARGE
        else:
            action = Action.MAINTAIN

        # 执行
        _, reward, info = env.step(action)
        rewards.append(reward)

        if step % 20 == 0:
            print(f"{step:5d} | {info['cwnd']:6d} | {info['rtt_ms']:8.2f} | "
                  f"{info['loss_rate']*100:7.3f} | {info['throughput_mbps']:10.2f}")

        # 自适应调整
        if step > 0 and step % 50 == 0:
            controller.tune_parameters(rewards)

    print("-" * 55)
    print(f"\n总奖励: {sum(rewards):.2f}")
    print(f"平均吞吐量: {info['throughput_mbps']:.2f} Mbps")
    print(f"参数: alpha={controller.alpha:.2f}, beta={controller.beta:.2f}")


if __name__ == '__main__':
    test_hybrid()

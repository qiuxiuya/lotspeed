#!/usr/bin/env python3
"""
LotMonitor MDP Data Collector & Trainer

用于从内核模块采集 TCP 连接数据，并训练马尔可夫决策过程(MDP)模型

Usage:
    python3 mdp_collector.py collect    # 采集数据
    python3 mdp_collector.py train      # 训练模型
    python3 mdp_collector.py analyze    # 分析数据
"""

import os
import sys
import time
import csv
import numpy as np
import pandas as pd
from datetime import datetime
from pathlib import Path
from collections import deque
import argparse
import json

# 数据文件路径
PROC_STATS = "/proc/lotmonitor/stats"
PROC_CONNS = "/proc/lotmonitor/conns"
PROC_SAMPLES = "/proc/lotmonitor/samples"
DATA_DIR = Path("./mdp_data")

# MDP 状态特征
STATE_FEATURES = [
    'min_rtt',
    'curr_rtt',
    'srtt',
    'rtt_var',
    'queue_delay',
    'loss_rate_ppm',
    'dup_ack',
    'throughput_kbps',
    'inflight',
    'rwnd',
]

# MDP 动作空间
ACTIONS = [
    'DECREASE_LARGE',   # cwnd *= 0.5
    'DECREASE_SMALL',   # cwnd *= 0.9
    'MAINTAIN',         # cwnd = cwnd
    'INCREASE_SMALL',   # cwnd += 1
    'INCREASE_LARGE',   # cwnd += 10
]


class SampleCollector:
    """从内核模块采集样本"""

    def __init__(self, output_dir: Path = DATA_DIR):
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.samples = []

    def check_module_loaded(self) -> bool:
        """检查内核模块是否加载"""
        return os.path.exists(PROC_STATS)

    def read_samples(self) -> pd.DataFrame:
        """从 /proc/lotmonitor/samples 读取样本"""
        if not os.path.exists(PROC_SAMPLES):
            return pd.DataFrame()

        try:
            with open(PROC_SAMPLES, 'r') as f:
                content = f.read()

            if not content.strip():
                return pd.DataFrame()

            lines = content.strip().split('\n')
            if len(lines) <= 1:  # 只有头部
                return pd.DataFrame()

            # 解析 CSV
            from io import StringIO
            df = pd.read_csv(StringIO(content))
            return df

        except Exception as e:
            print(f"Error reading samples: {e}")
            return pd.DataFrame()

    def read_stats(self) -> dict:
        """读取全局统计"""
        if not os.path.exists(PROC_STATS):
            return {}

        stats = {}
        try:
            with open(PROC_STATS, 'r') as f:
                for line in f:
                    if ':' in line:
                        key, value = line.split(':', 1)
                        key = key.strip().lower().replace(' ', '_')
                        value = value.strip()
                        try:
                            stats[key] = int(value)
                        except ValueError:
                            stats[key] = value
        except Exception as e:
            print(f"Error reading stats: {e}")

        return stats

    def collect_continuous(self, duration_sec: int = 60, interval_sec: float = 0.5):
        """持续采集数据"""
        print(f"开始采集数据，持续 {duration_sec} 秒...")

        if not self.check_module_loaded():
            print("错误: lotmonitor 模块未加载!")
            print("请运行: sudo insmod lotmonitor.ko")
            return

        start_time = time.time()
        all_samples = []
        sample_count = 0

        try:
            while time.time() - start_time < duration_sec:
                df = self.read_samples()
                if not df.empty:
                    all_samples.append(df)
                    sample_count += len(df)
                    print(f"\r已采集 {sample_count} 个样本...", end='', flush=True)

                time.sleep(interval_sec)

        except KeyboardInterrupt:
            print("\n采集被中断")

        print(f"\n采集完成，共 {sample_count} 个样本")

        if all_samples:
            # 合并所有样本
            combined = pd.concat(all_samples, ignore_index=True)

            # 去重
            combined = combined.drop_duplicates(subset=['timestamp_us', 'saddr', 'sport'])

            # 保存到文件
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = self.output_dir / f"samples_{timestamp}.csv"
            combined.to_csv(filename, index=False)
            print(f"数据已保存到: {filename}")

            return combined

        return pd.DataFrame()


class MDPStateBuilder:
    """构建 MDP 状态向量"""

    def __init__(self):
        # 特征归一化参数
        self.feature_stats = {}

    def normalize_features(self, df: pd.DataFrame) -> np.ndarray:
        """归一化特征"""
        features = []

        for col in STATE_FEATURES:
            if col in df.columns:
                values = df[col].values.astype(float)

                # 使用 log1p 处理大值
                if col in ['throughput_kbps', 'inflight', 'rwnd']:
                    values = np.log1p(values)

                # Z-score 归一化
                if col not in self.feature_stats:
                    self.feature_stats[col] = {
                        'mean': np.mean(values),
                        'std': np.std(values) + 1e-8
                    }

                values = (values - self.feature_stats[col]['mean']) / self.feature_stats[col]['std']
                features.append(values)
            else:
                features.append(np.zeros(len(df)))

        return np.column_stack(features)

    def build_state(self, sample: pd.Series) -> np.ndarray:
        """从单个样本构建状态向量"""
        state = []
        for col in STATE_FEATURES:
            if col in sample.index:
                value = float(sample[col])
                if col in ['throughput_kbps', 'inflight', 'rwnd']:
                    value = np.log1p(value)
                if col in self.feature_stats:
                    value = (value - self.feature_stats[col]['mean']) / self.feature_stats[col]['std']
                state.append(value)
            else:
                state.append(0.0)
        return np.array(state)


class RewardCalculator:
    """计算 MDP 奖励"""

    def __init__(self,
                 throughput_weight: float = 1.0,
                 delay_weight: float = 0.5,
                 loss_weight: float = 2.0):
        self.throughput_weight = throughput_weight
        self.delay_weight = delay_weight
        self.loss_weight = loss_weight

    def calculate(self,
                  throughput_kbps: float,
                  queue_delay_us: float,
                  loss_rate_ppm: float) -> float:
        """
        计算奖励

        奖励 = throughput - α * delay - β * loss
        """
        # 归一化吞吐量 (假设最大 100 Mbps)
        norm_throughput = min(throughput_kbps / 100000, 1.0)

        # 归一化延迟 (假设最大 100ms)
        norm_delay = min(queue_delay_us / 100000, 1.0)

        # 归一化丢包率
        norm_loss = min(loss_rate_ppm / 10000, 1.0)

        reward = (self.throughput_weight * norm_throughput -
                  self.delay_weight * norm_delay -
                  self.loss_weight * norm_loss)

        return reward


class QLearningAgent:
    """Q-Learning 智能体"""

    def __init__(self,
                 state_dim: int = len(STATE_FEATURES),
                 action_dim: int = len(ACTIONS),
                 learning_rate: float = 0.1,
                 discount_factor: float = 0.99,
                 epsilon: float = 0.1):
        self.state_dim = state_dim
        self.action_dim = action_dim
        self.lr = learning_rate
        self.gamma = discount_factor
        self.epsilon = epsilon

        # 使用简单的线性 Q 函数近似
        # Q(s, a) = w_a^T * s
        self.weights = np.zeros((action_dim, state_dim))

    def get_q_values(self, state: np.ndarray) -> np.ndarray:
        """获取所有动作的 Q 值"""
        return self.weights @ state

    def select_action(self, state: np.ndarray, training: bool = True) -> int:
        """选择动作 (ε-贪心)"""
        if training and np.random.random() < self.epsilon:
            return np.random.randint(self.action_dim)

        q_values = self.get_q_values(state)
        return np.argmax(q_values)

    def update(self, state: np.ndarray, action: int,
               reward: float, next_state: np.ndarray, done: bool):
        """更新 Q 函数"""
        current_q = self.weights[action] @ state

        if done:
            target = reward
        else:
            next_q_values = self.get_q_values(next_state)
            target = reward + self.gamma * np.max(next_q_values)

        # 梯度更新
        td_error = target - current_q
        self.weights[action] += self.lr * td_error * state

    def save(self, filepath: str):
        """保存模型"""
        np.savez(filepath, weights=self.weights)
        print(f"模型已保存到: {filepath}")

    def load(self, filepath: str):
        """加载模型"""
        data = np.load(filepath)
        self.weights = data['weights']
        print(f"模型已加载: {filepath}")


class MDPTrainer:
    """MDP 训练器"""

    def __init__(self, data_dir: Path = DATA_DIR):
        self.data_dir = data_dir
        self.state_builder = MDPStateBuilder()
        self.reward_calc = RewardCalculator()
        self.agent = QLearningAgent()

    def load_data(self) -> pd.DataFrame:
        """加载所有采集的数据"""
        all_data = []

        for csv_file in self.data_dir.glob("samples_*.csv"):
            df = pd.read_csv(csv_file)
            all_data.append(df)
            print(f"加载: {csv_file.name} ({len(df)} 样本)")

        if all_data:
            combined = pd.concat(all_data, ignore_index=True)
            combined = combined.sort_values('timestamp_us')
            return combined

        return pd.DataFrame()

    def prepare_episodes(self, df: pd.DataFrame) -> list:
        """将数据划分为训练回合"""
        episodes = []

        # 按连接分组
        grouped = df.groupby(['saddr', 'daddr', 'sport', 'dport'])

        for name, group in grouped:
            if len(group) < 10:
                continue

            group = group.sort_values('timestamp_us')
            episode = []

            for i in range(len(group) - 1):
                state = self.state_builder.build_state(group.iloc[i])
                next_state = self.state_builder.build_state(group.iloc[i + 1])

                # 计算奖励
                reward = self.reward_calc.calculate(
                    group.iloc[i + 1]['throughput_kbps'],
                    group.iloc[i + 1]['queue_delay'],
                    group.iloc[i + 1]['loss_rate_ppm']
                )

                # 推断动作 (基于吞吐量变化)
                throughput_change = (group.iloc[i + 1]['throughput_kbps'] -
                                     group.iloc[i]['throughput_kbps'])

                if throughput_change > 1000:
                    action = ACTIONS.index('INCREASE_LARGE')
                elif throughput_change > 100:
                    action = ACTIONS.index('INCREASE_SMALL')
                elif throughput_change < -1000:
                    action = ACTIONS.index('DECREASE_LARGE')
                elif throughput_change < -100:
                    action = ACTIONS.index('DECREASE_SMALL')
                else:
                    action = ACTIONS.index('MAINTAIN')

                episode.append((state, action, reward, next_state))

            if episode:
                episodes.append(episode)

        print(f"准备了 {len(episodes)} 个训练回合")
        return episodes

    def train(self, epochs: int = 100):
        """训练模型"""
        print("加载数据...")
        df = self.load_data()

        if df.empty:
            print("没有找到训练数据!")
            print(f"请先运行: python3 {sys.argv[0]} collect")
            return

        print(f"总计 {len(df)} 个样本")

        # 特征归一化
        print("构建状态特征...")
        self.state_builder.normalize_features(df)

        # 准备训练回合
        episodes = self.prepare_episodes(df)

        if not episodes:
            print("没有有效的训练回合!")
            return

        # 训练
        print(f"开始训练 {epochs} 轮...")

        for epoch in range(epochs):
            total_reward = 0

            for episode in episodes:
                for i, (state, action, reward, next_state) in enumerate(episode):
                    done = (i == len(episode) - 1)
                    self.agent.update(state, action, reward, next_state, done)
                    total_reward += reward

            avg_reward = total_reward / len(episodes)

            if (epoch + 1) % 10 == 0:
                print(f"Epoch {epoch + 1}/{epochs}, 平均奖励: {avg_reward:.4f}")

        # 保存模型
        model_path = self.data_dir / "q_model.npz"
        self.agent.save(str(model_path))

        # 保存特征统计
        stats_path = self.data_dir / "feature_stats.json"
        with open(stats_path, 'w') as f:
            # Convert numpy values to native Python types
            stats_serializable = {
                k: {kk: float(vv) for kk, vv in v.items()}
                for k, v in self.state_builder.feature_stats.items()
            }
            json.dump(stats_serializable, f, indent=2)
        print(f"特征统计已保存到: {stats_path}")


class DataAnalyzer:
    """数据分析器"""

    def __init__(self, data_dir: Path = DATA_DIR):
        self.data_dir = data_dir

    def analyze(self):
        """分析采集的数据"""
        all_data = []

        for csv_file in self.data_dir.glob("samples_*.csv"):
            df = pd.read_csv(csv_file)
            all_data.append(df)

        if not all_data:
            print("没有找到数据文件!")
            return

        df = pd.concat(all_data, ignore_index=True)

        print("=" * 60)
        print("LotMonitor 数据分析报告")
        print("=" * 60)

        print(f"\n总样本数: {len(df)}")
        print(f"唯一连接数: {df.groupby(['saddr', 'daddr', 'sport', 'dport']).ngroups}")

        print("\n--- RTT 统计 (微秒) ---")
        for col in ['min_rtt', 'curr_rtt', 'srtt', 'queue_delay']:
            if col in df.columns:
                values = df[col][df[col] > 0]
                if len(values) > 0:
                    print(f"{col:15s}: min={values.min():8.0f}, "
                          f"avg={values.mean():8.0f}, "
                          f"max={values.max():8.0f}")

        print("\n--- 丢包统计 ---")
        if 'loss_rate_ppm' in df.columns:
            loss_rate = df['loss_rate_ppm'].mean() / 10000
            print(f"平均丢包率: {loss_rate:.4f}%")

        if 'loss_count' in df.columns:
            print(f"总丢包事件: {df['loss_count'].max()}")

        print("\n--- 吞吐量统计 (kbps) ---")
        if 'throughput_kbps' in df.columns:
            tp = df['throughput_kbps'][df['throughput_kbps'] > 0]
            if len(tp) > 0:
                print(f"最小: {tp.min():.0f} kbps")
                print(f"平均: {tp.mean():.0f} kbps")
                print(f"最大: {tp.max():.0f} kbps")

        print("\n--- 事件分布 ---")
        if 'event' in df.columns:
            event_names = ['NONE', 'ACK', 'LOSS', 'TIMEOUT', 'RTT_SAMPLE']
            for i, name in enumerate(event_names):
                count = len(df[df['event'] == i])
                if count > 0:
                    print(f"{name}: {count} ({count/len(df)*100:.1f}%)")

        print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(description='LotMonitor MDP 数据采集与训练')
    parser.add_argument('command', choices=['collect', 'train', 'analyze', 'status'],
                        help='执行的命令')
    parser.add_argument('--duration', '-d', type=int, default=60,
                        help='采集持续时间 (秒)')
    parser.add_argument('--epochs', '-e', type=int, default=100,
                        help='训练轮数')

    args = parser.parse_args()

    if args.command == 'collect':
        collector = SampleCollector()
        collector.collect_continuous(duration_sec=args.duration)

    elif args.command == 'train':
        trainer = MDPTrainer()
        trainer.train(epochs=args.epochs)

    elif args.command == 'analyze':
        analyzer = DataAnalyzer()
        analyzer.analyze()

    elif args.command == 'status':
        if os.path.exists(PROC_STATS):
            print("模块状态: 已加载")
            with open(PROC_STATS, 'r') as f:
                print(f.read())
        else:
            print("模块状态: 未加载")
            print("请运行: sudo insmod lotmonitor.ko")


if __name__ == '__main__':
    main()

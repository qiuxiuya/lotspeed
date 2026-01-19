#!/usr/bin/env python3
"""
LotMonitor 数据可视化脚本

生成 RTT、吞吐量、丢包率等图表

用法: python3 visualize.py [数据文件]
"""

import os
import sys
import argparse
from pathlib import Path
import pandas as pd
import numpy as np

try:
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("警告: matplotlib 未安装，无法生成图表")
    print("安装: pip install matplotlib")

DATA_DIR = Path("./mdp_data")
OUTPUT_DIR = Path("./mdp_data/plots")


def load_all_data() -> pd.DataFrame:
    """加载所有数据文件"""
    all_data = []

    for csv_file in DATA_DIR.glob("samples_*.csv"):
        df = pd.read_csv(csv_file)
        all_data.append(df)
        print(f"加载: {csv_file.name} ({len(df)} 样本)")

    if not all_data:
        return pd.DataFrame()

    combined = pd.concat(all_data, ignore_index=True)
    combined = combined.sort_values('timestamp_us')

    # 转换时间戳为相对时间 (秒)
    combined['time_sec'] = (combined['timestamp_us'] - combined['timestamp_us'].min()) / 1e6

    return combined


def plot_rtt(df: pd.DataFrame, output_dir: Path):
    """绘制 RTT 图表"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 当前 RTT
    ax = axes[0, 0]
    valid = df[df['curr_rtt'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['curr_rtt'] / 1000, 'b-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('RTT (毫秒)')
        ax.set_title('当前 RTT')
        ax.grid(True, alpha=0.3)

    # 平滑 RTT vs 最小 RTT
    ax = axes[0, 1]
    valid = df[(df['srtt'] > 0) & (df['min_rtt'] > 0)]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['srtt'] / 1000, 'b-', label='SRTT', alpha=0.7)
        ax.plot(valid['time_sec'], valid['min_rtt'] / 1000, 'g-', label='Min RTT', alpha=0.7)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('RTT (毫秒)')
        ax.set_title('平滑 RTT vs 最小 RTT')
        ax.legend()
        ax.grid(True, alpha=0.3)

    # 队列延迟
    ax = axes[1, 0]
    valid = df[df['queue_delay'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['queue_delay'] / 1000, 'r-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('延迟 (毫秒)')
        ax.set_title('队列延迟 (curr_rtt - min_rtt)')
        ax.grid(True, alpha=0.3)

    # RTT 方差
    ax = axes[1, 1]
    valid = df[df['rtt_var'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['rtt_var'] / 1000, 'm-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('方差 (毫秒)')
        ax.set_title('RTT 方差')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "rtt.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"已保存: {output_file}")


def plot_throughput(df: pd.DataFrame, output_dir: Path):
    """绘制吞吐量图表"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 吞吐量
    ax = axes[0, 0]
    valid = df[df['throughput_kbps'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['throughput_kbps'] / 1000, 'g-', alpha=0.7)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('吞吐量 (Mbps)')
        ax.set_title('吞吐量')
        ax.grid(True, alpha=0.3)

    # 字节发送/确认
    ax = axes[0, 1]
    valid = df[(df['bytes_sent'] > 0) | (df['bytes_acked'] > 0)]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['bytes_sent'] / 1024, 'b-', label='发送', alpha=0.7)
        ax.plot(valid['time_sec'], valid['bytes_acked'] / 1024, 'g-', label='确认', alpha=0.7)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('数据量 (KB)')
        ax.set_title('发送/确认数据量')
        ax.legend()
        ax.grid(True, alpha=0.3)

    # 在途数据
    ax = axes[1, 0]
    valid = df[df['inflight'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['inflight'] / 1024, 'orange', alpha=0.7)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('在途数据 (KB)')
        ax.set_title('在途数据量 (Inflight)')
        ax.grid(True, alpha=0.3)

    # 接收窗口
    ax = axes[1, 1]
    valid = df[df['rwnd'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['rwnd'] / 1024, 'purple', alpha=0.7)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('窗口 (KB)')
        ax.set_title('对方接收窗口 (rwnd)')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "throughput.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"已保存: {output_file}")


def plot_loss(df: pd.DataFrame, output_dir: Path):
    """绘制丢包相关图表"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # 丢包率
    ax = axes[0, 0]
    valid = df.copy()
    valid['loss_pct'] = valid['loss_rate_ppm'] / 10000
    ax.plot(valid['time_sec'], valid['loss_pct'], 'r-', alpha=0.7)
    ax.set_xlabel('时间 (秒)')
    ax.set_ylabel('丢包率 (%)')
    ax.set_title('丢包率')
    ax.grid(True, alpha=0.3)

    # 累计丢包
    ax = axes[0, 1]
    ax.plot(df['time_sec'], df['loss_count'], 'r-', alpha=0.7)
    ax.set_xlabel('时间 (秒)')
    ax.set_ylabel('丢包数')
    ax.set_title('累计丢包事件')
    ax.grid(True, alpha=0.3)

    # 重复 ACK
    ax = axes[1, 0]
    ax.plot(df['time_sec'], df['dup_ack'], 'orange', alpha=0.7, linewidth=0.5)
    ax.set_xlabel('时间 (秒)')
    ax.set_ylabel('重复 ACK 数')
    ax.set_title('重复 ACK 计数')
    ax.grid(True, alpha=0.3)

    # 事件分布
    ax = axes[1, 1]
    event_names = ['NONE', 'ACK', 'LOSS', 'TIMEOUT', 'RTT']
    event_counts = [len(df[df['event'] == i]) for i in range(5)]
    colors = ['gray', 'green', 'red', 'orange', 'blue']
    ax.bar(event_names, event_counts, color=colors, alpha=0.7)
    ax.set_xlabel('事件类型')
    ax.set_ylabel('次数')
    ax.set_title('事件分布')
    ax.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    output_file = output_dir / "loss.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"已保存: {output_file}")


def plot_timing(df: pd.DataFrame, output_dir: Path):
    """绘制时序相关图表"""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    # ACK 间隔
    ax = axes[0]
    valid = df[df['ack_interval'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['ack_interval'] / 1000, 'b-', alpha=0.5, linewidth=0.5)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('间隔 (毫秒)')
        ax.set_title('ACK 间隔')
        ax.grid(True, alpha=0.3)

    # 发送间隔
    ax = axes[1]
    valid = df[df['send_interval'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['send_interval'] / 1000, 'g-', alpha=0.5, linewidth=0.5)
        ax.set_xlabel('时间 (秒)')
        ax.set_ylabel('间隔 (毫秒)')
        ax.set_title('发送间隔')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "timing.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"已保存: {output_file}")


def plot_summary(df: pd.DataFrame, output_dir: Path):
    """绘制综合概览图"""
    fig, axes = plt.subplots(3, 1, figsize=(14, 12), sharex=True)

    # RTT
    ax = axes[0]
    valid = df[df['curr_rtt'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['curr_rtt'] / 1000, 'b-', alpha=0.7, label='当前 RTT')
        ax.fill_between(valid['time_sec'], 0, valid['queue_delay'] / 1000,
                        alpha=0.3, color='red', label='队列延迟')
        ax.set_ylabel('RTT (毫秒)')
        ax.set_title('RTT 与队列延迟')
        ax.legend(loc='upper right')
        ax.grid(True, alpha=0.3)

    # 吞吐量
    ax = axes[1]
    valid = df[df['throughput_kbps'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['throughput_kbps'] / 1000, 'g-', alpha=0.7)
        ax.set_ylabel('吞吐量 (Mbps)')
        ax.set_title('吞吐量')
        ax.grid(True, alpha=0.3)

    # 丢包
    ax = axes[2]
    valid = df.copy()
    valid['loss_pct'] = valid['loss_rate_ppm'] / 10000
    ax.plot(valid['time_sec'], valid['loss_pct'], 'r-', alpha=0.7)
    ax.set_xlabel('时间 (秒)')
    ax.set_ylabel('丢包率 (%)')
    ax.set_title('丢包率')
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "summary.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"已保存: {output_file}")


def main():
    parser = argparse.ArgumentParser(description='LotMonitor 数据可视化')
    parser.add_argument('file', nargs='?', help='指定数据文件 (可选)')
    args = parser.parse_args()

    if not HAS_MATPLOTLIB:
        print("错误: 需要 matplotlib 库")
        print("安装: pip install matplotlib")
        sys.exit(1)

    print("========================================")
    print("LotMonitor 数据可视化")
    print("========================================")
    print()

    # 加载数据
    if args.file:
        df = pd.read_csv(args.file)
        df['time_sec'] = (df['timestamp_us'] - df['timestamp_us'].min()) / 1e6
        print(f"加载: {args.file} ({len(df)} 样本)")
    else:
        df = load_all_data()

    if df.empty:
        print("错误: 没有找到数据")
        print("请先运行: ./collect.sh")
        sys.exit(1)

    print(f"\n总样本数: {len(df)}")
    print(f"时间跨度: {df['time_sec'].max():.1f} 秒")

    # 创建输出目录
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"\n输出目录: {OUTPUT_DIR}")
    print()

    # 生成图表
    print("生成图表...")
    plot_rtt(df, OUTPUT_DIR)
    plot_throughput(df, OUTPUT_DIR)
    plot_loss(df, OUTPUT_DIR)
    plot_timing(df, OUTPUT_DIR)
    plot_summary(df, OUTPUT_DIR)

    print()
    print("可视化完成!")
    print(f"图表保存在: {OUTPUT_DIR}/")


if __name__ == '__main__':
    main()

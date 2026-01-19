#!/usr/bin/env python3
"""
LotMonitor Data Collector

从内核模块采集 TCP 连接数据用于 MDP 训练。

Usage:
    python3 collector.py collect --duration 60
    python3 collector.py analyze
    python3 collector.py monitor
"""

import os
import sys
import time
import argparse
import csv
import json
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional, Tuple
import numpy as np


# =============================================================================
# 数据类型定义
# =============================================================================

@dataclass
class Sample:
    """MDP 训练样本"""
    timestamp_us: int
    saddr: str
    daddr: str
    sport: int
    dport: int
    min_rtt: int        # 微秒
    curr_rtt: int       # 微秒
    srtt: int           # 微秒
    rtt_var: int        # 微秒
    queue_delay: int    # 微秒
    loss_count: int
    dup_ack: int
    loss_rate_ppm: int  # 百万分比
    bytes_sent: int
    bytes_acked: int
    pkts_sent: int
    pkts_acked: int
    throughput_kbps: int
    ack_interval: int   # 微秒
    send_interval: int  # 微秒
    inflight: int
    rwnd: int
    event: int


@dataclass
class ConnectionState:
    """连接状态 (用于 MDP)"""
    # 标识
    conn_key: str

    # 归一化后的状态特征
    rtt_ratio: float = 1.0       # curr_rtt / min_rtt
    rtt_gradient: float = 0.0    # RTT 变化率
    loss_rate: float = 0.0       # 丢包率 (0-1)
    throughput_ratio: float = 0.0 # 吞吐量比率
    utilization: float = 0.0     # 窗口利用率

    # 原始值 (用于调试)
    min_rtt_us: int = 0
    curr_rtt_us: int = 0
    throughput_kbps: int = 0


@dataclass
class Stats:
    """统计信息"""
    active_conns: int = 0
    rx_packets: int = 0
    tx_packets: int = 0
    total_samples: int = 0
    dropped_samples: int = 0
    sample_interval_ms: int = 100
    buffer_size: int = 4096
    buffer_used: int = 0
    control_enabled: bool = False
    control_cmds: int = 0
    rwnd_modifications: int = 0


# =============================================================================
# 数据采集器
# =============================================================================

class DataCollector:
    """从内核模块采集数据"""

    PROC_BASE = "/proc/lotmonitor"

    def __init__(self, data_dir: str = "mdp_data"):
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(exist_ok=True)

        # 检查模块是否加载
        if not os.path.exists(self.PROC_BASE):
            raise RuntimeError(
                f"LotMonitor 模块未加载。请先运行:\n"
                f"  sudo insmod lotmonitor.ko"
            )

    def read_stats(self) -> Stats:
        """读取全局统计"""
        stats = Stats()

        try:
            with open(f"{self.PROC_BASE}/stats", "r") as f:
                for line in f:
                    line = line.strip()
                    if ":" in line:
                        key, value = line.split(":", 1)
                        key = key.strip().lower().replace(" ", "_")
                        value = value.strip()

                        if key == "active_connections":
                            stats.active_conns = int(value)
                        elif key == "rx_packets":
                            stats.rx_packets = int(value)
                        elif key == "tx_packets":
                            stats.tx_packets = int(value)
                        elif key == "total_samples":
                            stats.total_samples = int(value)
                        elif key == "dropped_samples":
                            stats.dropped_samples = int(value)
                        elif key == "sample_interval":
                            stats.sample_interval_ms = int(value.replace("ms", "").strip())
                        elif key == "buffer_size":
                            stats.buffer_size = int(value)
                        elif key == "buffer_used":
                            stats.buffer_used = int(value)
                        elif key == "control_enabled":
                            stats.control_enabled = value.lower() == "yes"
                        elif key == "control_commands":
                            stats.control_cmds = int(value)
                        elif key == "rwnd_modifications":
                            stats.rwnd_modifications = int(value)
        except Exception as e:
            print(f"Warning: Failed to read stats: {e}")

        return stats

    def read_samples(self) -> List[Sample]:
        """读取样本数据"""
        samples = []

        try:
            with open(f"{self.PROC_BASE}/samples", "r") as f:
                reader = csv.reader(f)
                header = None

                for row in reader:
                    if not row or row[0].startswith("#"):
                        continue

                    if header is None:
                        header = row
                        continue

                    try:
                        sample = Sample(
                            timestamp_us=int(row[0]),
                            saddr=row[1],
                            daddr=row[2],
                            sport=int(row[3]),
                            dport=int(row[4]),
                            min_rtt=int(row[5]),
                            curr_rtt=int(row[6]),
                            srtt=int(row[7]),
                            rtt_var=int(row[8]),
                            queue_delay=int(row[9]),
                            loss_count=int(row[10]),
                            dup_ack=int(row[11]),
                            loss_rate_ppm=int(row[12]),
                            bytes_sent=int(row[13]),
                            bytes_acked=int(row[14]),
                            pkts_sent=int(row[15]),
                            pkts_acked=int(row[16]),
                            throughput_kbps=int(row[17]),
                            ack_interval=int(row[18]),
                            send_interval=int(row[19]),
                            inflight=int(row[20]),
                            rwnd=int(row[21]),
                            event=int(row[22]),
                        )
                        samples.append(sample)
                    except (ValueError, IndexError) as e:
                        continue
        except Exception as e:
            print(f"Warning: Failed to read samples: {e}")

        return samples

    def read_connections(self) -> List[Dict]:
        """读取连接列表"""
        connections = []

        try:
            with open(f"{self.PROC_BASE}/conns", "r") as f:
                for line in f:
                    if line.startswith("#"):
                        continue

                    parts = line.strip().split(",")
                    if len(parts) >= 10:
                        connections.append({
                            "saddr": parts[0],
                            "daddr": parts[1],
                            "sport": int(parts[2]),
                            "dport": int(parts[3]),
                            "min_rtt": int(parts[4]),
                            "curr_rtt": int(parts[5]),
                            "srtt": int(parts[6]),
                            "loss": int(parts[7]),
                            "pkts": int(parts[8]),
                            "bytes": int(parts[9]),
                        })
        except Exception as e:
            print(f"Warning: Failed to read connections: {e}")

        return connections

    def sample_to_state(self, sample: Sample) -> ConnectionState:
        """将样本转换为 MDP 状态"""
        conn_key = f"{sample.saddr}:{sample.sport}->{sample.daddr}:{sample.dport}"

        # RTT ratio
        rtt_ratio = sample.curr_rtt / sample.min_rtt if sample.min_rtt > 0 else 1.0
        rtt_ratio = min(rtt_ratio, 10.0)  # 限制最大值

        # 丢包率
        loss_rate = sample.loss_rate_ppm / 1_000_000.0

        # 吞吐量比率 (假设最大 1Gbps = 1000000 kbps)
        throughput_ratio = sample.throughput_kbps / 1_000_000.0

        # 窗口利用率
        utilization = sample.inflight / sample.rwnd if sample.rwnd > 0 else 0.0
        utilization = min(utilization, 1.0)

        return ConnectionState(
            conn_key=conn_key,
            rtt_ratio=rtt_ratio,
            loss_rate=loss_rate,
            throughput_ratio=throughput_ratio,
            utilization=utilization,
            min_rtt_us=sample.min_rtt,
            curr_rtt_us=sample.curr_rtt,
            throughput_kbps=sample.throughput_kbps,
        )

    def collect(self, duration: int = 60, interval: float = 0.5) -> str:
        """采集数据一段时间"""
        all_samples = []
        start_time = time.time()

        print(f"开始采集数据 ({duration} 秒)...")
        print(f"数据将保存到: {self.data_dir}")

        while time.time() - start_time < duration:
            samples = self.read_samples()

            # 过滤有效样本
            valid_samples = [s for s in samples if s.curr_rtt > 0 or s.throughput_kbps > 0]
            all_samples.extend(valid_samples)

            elapsed = time.time() - start_time
            stats = self.read_stats()

            print(f"\r[{elapsed:.1f}s] "
                  f"连接: {stats.active_conns}, "
                  f"样本: {len(all_samples)}, "
                  f"缓冲: {stats.buffer_used}/{stats.buffer_size}",
                  end="", flush=True)

            time.sleep(interval)

        print()

        # 保存数据
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = self.data_dir / f"samples_{timestamp}.csv"

        with open(filename, "w", newline="") as f:
            if all_samples:
                writer = csv.writer(f)
                # 写入头部
                writer.writerow([
                    "timestamp_us", "saddr", "daddr", "sport", "dport",
                    "min_rtt", "curr_rtt", "srtt", "rtt_var", "queue_delay",
                    "loss_count", "dup_ack", "loss_rate_ppm",
                    "bytes_sent", "bytes_acked", "pkts_sent", "pkts_acked",
                    "throughput_kbps", "ack_interval", "send_interval",
                    "inflight", "rwnd", "event"
                ])
                # 写入数据
                for sample in all_samples:
                    writer.writerow([
                        sample.timestamp_us, sample.saddr, sample.daddr,
                        sample.sport, sample.dport, sample.min_rtt,
                        sample.curr_rtt, sample.srtt, sample.rtt_var,
                        sample.queue_delay, sample.loss_count, sample.dup_ack,
                        sample.loss_rate_ppm, sample.bytes_sent, sample.bytes_acked,
                        sample.pkts_sent, sample.pkts_acked, sample.throughput_kbps,
                        sample.ack_interval, sample.send_interval,
                        sample.inflight, sample.rwnd, sample.event
                    ])

        print(f"已保存 {len(all_samples)} 个样本到: {filename}")
        return str(filename)

    def analyze(self, filepath: Optional[str] = None):
        """分析采集的数据"""
        # 查找最新的数据文件
        if filepath is None:
            files = sorted(self.data_dir.glob("samples_*.csv"))
            if not files:
                print("没有找到数据文件")
                return
            filepath = str(files[-1])

        print(f"分析文件: {filepath}")
        print("=" * 60)

        # 读取数据
        samples = []
        with open(filepath, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                samples.append(row)

        if not samples:
            print("文件为空")
            return

        # 转换为数值
        curr_rtts = [int(s["curr_rtt"]) for s in samples if int(s["curr_rtt"]) > 0]
        min_rtts = [int(s["min_rtt"]) for s in samples if int(s["min_rtt"]) > 0]
        throughputs = [int(s["throughput_kbps"]) for s in samples]
        loss_rates = [int(s["loss_rate_ppm"]) / 1e6 for s in samples]

        # 统计
        print(f"总样本数: {len(samples)}")
        print(f"有效 RTT 样本: {len(curr_rtts)}")
        print()

        if curr_rtts:
            print("RTT 统计 (微秒):")
            print(f"  最小值: {np.min(curr_rtts):.0f}")
            print(f"  最大值: {np.max(curr_rtts):.0f}")
            print(f"  平均值: {np.mean(curr_rtts):.0f}")
            print(f"  中位数: {np.median(curr_rtts):.0f}")
            print(f"  标准差: {np.std(curr_rtts):.0f}")
            print()

        if min_rtts:
            print("Base RTT (min_rtt) 统计 (微秒):")
            print(f"  最小值: {np.min(min_rtts):.0f}")
            print(f"  最大值: {np.max(min_rtts):.0f}")
            print(f"  平均值: {np.mean(min_rtts):.0f}")
            print()

        valid_tps = [t for t in throughputs if t > 0]
        if valid_tps:
            print("吞吐量统计 (kbps):")
            print(f"  最小值: {np.min(valid_tps):.0f}")
            print(f"  最大值: {np.max(valid_tps):.0f}")
            print(f"  平均值: {np.mean(valid_tps):.0f}")
            print()

        valid_losses = [l for l in loss_rates if l > 0]
        if valid_losses:
            print("丢包率统计:")
            print(f"  最小值: {np.min(valid_losses)*100:.4f}%")
            print(f"  最大值: {np.max(valid_losses)*100:.4f}%")
            print(f"  平均值: {np.mean(valid_losses)*100:.4f}%")
            print()

        # 连接分布
        connections = set()
        for s in samples:
            conn = f"{s['saddr']}:{s['sport']}->{s['daddr']}:{s['dport']}"
            connections.add(conn)

        print(f"唯一连接数: {len(connections)}")

        # 数据质量评估
        print()
        print("数据质量评估:")
        empty_rtt = sum(1 for s in samples if int(s["curr_rtt"]) == 0)
        empty_tp = sum(1 for s in samples if int(s["throughput_kbps"]) == 0)
        print(f"  空 RTT 样本: {empty_rtt} ({empty_rtt/len(samples)*100:.1f}%)")
        print(f"  空吞吐量样本: {empty_tp} ({empty_tp/len(samples)*100:.1f}%)")

        quality = 100 - (empty_rtt + empty_tp) / (2 * len(samples)) * 100
        print(f"  数据质量评分: {quality:.1f}%")

    def monitor(self, interval: float = 1.0):
        """实时监控模式"""
        print("实时监控模式 (按 Ctrl+C 退出)")
        print("=" * 70)

        prev_stats = None

        try:
            while True:
                stats = self.read_stats()
                conns = self.read_connections()

                # 清屏
                print("\033[2J\033[H", end="")

                print(f"LotMonitor 实时监控 - {datetime.now().strftime('%H:%M:%S')}")
                print("=" * 70)
                print(f"活跃连接: {stats.active_conns}")
                print(f"RX/TX 包: {stats.rx_packets} / {stats.tx_packets}")
                print(f"样本: {stats.total_samples} (丢弃: {stats.dropped_samples})")
                print(f"控制: {'启用' if stats.control_enabled else '禁用'} "
                      f"(命令: {stats.control_cmds}, rwnd修改: {stats.rwnd_modifications})")
                print("-" * 70)

                # 显示活跃连接
                if conns:
                    print(f"{'地址':40} {'RTT(ms)':>10} {'丢包':>8} {'吞吐量':>12}")
                    print("-" * 70)

                    for conn in conns[:10]:  # 只显示前10个
                        addr = f"{conn['saddr']}:{conn['sport']}->{conn['daddr']}:{conn['dport']}"
                        if len(addr) > 38:
                            addr = addr[:35] + "..."

                        rtt_ms = conn['curr_rtt'] / 1000 if conn['curr_rtt'] > 0 else 0

                        print(f"{addr:40} {rtt_ms:>10.2f} {conn['loss']:>8} "
                              f"{conn['bytes']/1024:.1f} KB")

                prev_stats = stats
                time.sleep(interval)

        except KeyboardInterrupt:
            print("\n监控已停止")


# =============================================================================
# 主程序
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="LotMonitor Data Collector - MDP 训练数据采集工具"
    )

    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # collect 命令
    collect_parser = subparsers.add_parser("collect", help="采集数据")
    collect_parser.add_argument("--duration", "-d", type=int, default=60,
                               help="采集时长 (秒)")
    collect_parser.add_argument("--interval", "-i", type=float, default=0.5,
                               help="采集间隔 (秒)")

    # analyze 命令
    analyze_parser = subparsers.add_parser("analyze", help="分析数据")
    analyze_parser.add_argument("--file", "-f", type=str,
                               help="要分析的文件路径")

    # monitor 命令
    monitor_parser = subparsers.add_parser("monitor", help="实时监控")
    monitor_parser.add_argument("--interval", "-i", type=float, default=1.0,
                               help="刷新间隔 (秒)")

    # stats 命令
    subparsers.add_parser("stats", help="显示统计信息")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return

    try:
        collector = DataCollector()

        if args.command == "collect":
            collector.collect(duration=args.duration, interval=args.interval)
        elif args.command == "analyze":
            collector.analyze(filepath=args.file)
        elif args.command == "monitor":
            collector.monitor(interval=args.interval)
        elif args.command == "stats":
            stats = collector.read_stats()
            print("LotMonitor 统计信息:")
            print(f"  活跃连接: {stats.active_conns}")
            print(f"  RX 包: {stats.rx_packets}")
            print(f"  TX 包: {stats.tx_packets}")
            print(f"  总样本: {stats.total_samples}")
            print(f"  丢弃样本: {stats.dropped_samples}")
            print(f"  采样间隔: {stats.sample_interval_ms} ms")
            print(f"  缓冲区使用: {stats.buffer_used}/{stats.buffer_size}")
            print(f"  控制启用: {stats.control_enabled}")
            print(f"  控制命令: {stats.control_cmds}")
            print(f"  rwnd 修改: {stats.rwnd_modifications}")

    except Exception as e:
        print(f"错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
LotMonitor Data Visualization

Generate RTT, throughput, loss rate charts for MDP training data analysis.

Usage: python3 visualize.py [data_file]
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
    print("Warning: matplotlib not installed")
    print("Install: pip install matplotlib")

DATA_DIR = Path("./mdp_data")
OUTPUT_DIR = Path("./mdp_data/plots")


def load_all_data() -> pd.DataFrame:
    """Load all data files"""
    all_data = []

    for csv_file in DATA_DIR.glob("samples_*.csv"):
        df = pd.read_csv(csv_file)
        all_data.append(df)
        print(f"Loaded: {csv_file.name} ({len(df)} samples)")

    # Also check nested directory
    nested_dir = DATA_DIR / "mdp_data"
    if nested_dir.exists():
        for csv_file in nested_dir.glob("samples_*.csv"):
            df = pd.read_csv(csv_file)
            all_data.append(df)
            print(f"Loaded: {csv_file.name} ({len(df)} samples)")

    if not all_data:
        return pd.DataFrame()

    combined = pd.concat(all_data, ignore_index=True)
    combined = combined.sort_values('timestamp_us')

    # Convert timestamp to relative time (seconds)
    combined['time_sec'] = (combined['timestamp_us'] - combined['timestamp_us'].min()) / 1e6

    return combined


def filter_valid_samples(df: pd.DataFrame) -> pd.DataFrame:
    """Filter out empty/invalid samples"""
    # Keep samples with valid RTT or significant data
    valid = df[(df['curr_rtt'] > 0) | (df['bytes_sent'] > 0) | (df['bytes_acked'] > 0)]
    print(f"Valid samples: {len(valid)} / {len(df)} ({len(valid)/len(df)*100:.1f}%)")
    return valid


def plot_rtt(df: pd.DataFrame, output_dir: Path):
    """Plot RTT charts"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # Current RTT
    ax = axes[0, 0]
    valid = df[df['curr_rtt'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['curr_rtt'] / 1000, 'b-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('RTT (ms)')
        ax.set_title('Current RTT')
        ax.grid(True, alpha=0.3)

    # Smoothed RTT vs Min RTT
    ax = axes[0, 1]
    valid = df[(df['srtt'] > 0) & (df['min_rtt'] > 0)]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['srtt'] / 1000, 'b-', label='SRTT', alpha=0.7)
        ax.plot(valid['time_sec'], valid['min_rtt'] / 1000, 'g-', label='Min RTT', alpha=0.7)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('RTT (ms)')
        ax.set_title('Smoothed RTT vs Min RTT')
        ax.legend()
        ax.grid(True, alpha=0.3)

    # Queue Delay
    ax = axes[1, 0]
    valid = df[df['queue_delay'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['queue_delay'] / 1000, 'r-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Delay (ms)')
        ax.set_title('Queue Delay (curr_rtt - min_rtt)')
        ax.grid(True, alpha=0.3)

    # RTT Variance
    ax = axes[1, 1]
    valid = df[df['rtt_var'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['rtt_var'] / 1000, 'm-', alpha=0.7, linewidth=0.5)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Variance (ms)')
        ax.set_title('RTT Variance')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "rtt.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"Saved: {output_file}")


def plot_throughput(df: pd.DataFrame, output_dir: Path):
    """Plot throughput charts"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # Throughput
    ax = axes[0, 0]
    valid = df[df['throughput_kbps'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['throughput_kbps'] / 1000, 'g-', alpha=0.7)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Throughput (Mbps)')
        ax.set_title('Throughput')
        ax.grid(True, alpha=0.3)

    # Bytes Sent/Acked
    ax = axes[0, 1]
    valid = df[(df['bytes_sent'] > 0) | (df['bytes_acked'] > 0)]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['bytes_sent'] / 1024, 'b-', label='Sent', alpha=0.7)
        ax.plot(valid['time_sec'], valid['bytes_acked'] / 1024, 'g-', label='Acked', alpha=0.7)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Data (KB)')
        ax.set_title('Bytes Sent/Acked')
        ax.legend()
        ax.grid(True, alpha=0.3)

    # Inflight Data
    ax = axes[1, 0]
    valid = df[df['inflight'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['inflight'] / 1024, 'orange', alpha=0.7)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Inflight (KB)')
        ax.set_title('Inflight Data')
        ax.grid(True, alpha=0.3)

    # Receive Window
    ax = axes[1, 1]
    valid = df[df['rwnd'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['rwnd'] / 1024, 'purple', alpha=0.7)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Window (KB)')
        ax.set_title('Peer Receive Window (rwnd)')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "throughput.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"Saved: {output_file}")


def plot_loss(df: pd.DataFrame, output_dir: Path):
    """Plot loss-related charts"""
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    # Loss Rate
    ax = axes[0, 0]
    valid = df.copy()
    valid['loss_pct'] = valid['loss_rate_ppm'] / 10000
    ax.plot(valid['time_sec'], valid['loss_pct'], 'r-', alpha=0.7)
    ax.set_xlabel('Time (sec)')
    ax.set_ylabel('Loss Rate (%)')
    ax.set_title('Loss Rate')
    ax.grid(True, alpha=0.3)

    # Cumulative Loss
    ax = axes[0, 1]
    ax.plot(df['time_sec'], df['loss_count'], 'r-', alpha=0.7)
    ax.set_xlabel('Time (sec)')
    ax.set_ylabel('Loss Count')
    ax.set_title('Cumulative Loss Events')
    ax.grid(True, alpha=0.3)

    # Duplicate ACKs
    ax = axes[1, 0]
    ax.plot(df['time_sec'], df['dup_ack'], 'orange', alpha=0.7, linewidth=0.5)
    ax.set_xlabel('Time (sec)')
    ax.set_ylabel('Dup ACK Count')
    ax.set_title('Duplicate ACK Count')
    ax.grid(True, alpha=0.3)

    # Event Distribution
    ax = axes[1, 1]
    event_names = ['NONE', 'ACK', 'LOSS', 'TIMEOUT', 'RTT']
    event_counts = [len(df[df['event'] == i]) for i in range(5)]
    colors = ['gray', 'green', 'red', 'orange', 'blue']
    ax.bar(event_names, event_counts, color=colors, alpha=0.7)
    ax.set_xlabel('Event Type')
    ax.set_ylabel('Count')
    ax.set_title('Event Distribution')
    ax.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()
    output_file = output_dir / "loss.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"Saved: {output_file}")


def plot_timing(df: pd.DataFrame, output_dir: Path):
    """Plot timing-related charts"""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    # ACK Interval
    ax = axes[0]
    valid = df[df['ack_interval'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['ack_interval'] / 1000, 'b-', alpha=0.5, linewidth=0.5)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Interval (ms)')
        ax.set_title('ACK Interval')
        ax.grid(True, alpha=0.3)

    # Send Interval
    ax = axes[1]
    valid = df[df['send_interval'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['send_interval'] / 1000, 'g-', alpha=0.5, linewidth=0.5)
        ax.set_xlabel('Time (sec)')
        ax.set_ylabel('Interval (ms)')
        ax.set_title('Send Interval')
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "timing.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"Saved: {output_file}")


def plot_summary(df: pd.DataFrame, output_dir: Path):
    """Plot summary overview"""
    fig, axes = plt.subplots(3, 1, figsize=(14, 12), sharex=True)

    # RTT
    ax = axes[0]
    valid = df[df['curr_rtt'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['curr_rtt'] / 1000, 'b-', alpha=0.7, label='Current RTT')
        ax.fill_between(valid['time_sec'], 0, valid['queue_delay'] / 1000,
                        alpha=0.3, color='red', label='Queue Delay')
        ax.set_ylabel('RTT (ms)')
        ax.set_title('RTT and Queue Delay')
        ax.legend(loc='upper right')
        ax.grid(True, alpha=0.3)

    # Throughput
    ax = axes[1]
    valid = df[df['throughput_kbps'] > 0]
    if len(valid) > 0:
        ax.plot(valid['time_sec'], valid['throughput_kbps'] / 1000, 'g-', alpha=0.7)
        ax.set_ylabel('Throughput (Mbps)')
        ax.set_title('Throughput')
        ax.grid(True, alpha=0.3)

    # Loss Rate
    ax = axes[2]
    valid = df.copy()
    valid['loss_pct'] = valid['loss_rate_ppm'] / 10000
    ax.plot(valid['time_sec'], valid['loss_pct'], 'r-', alpha=0.7)
    ax.set_xlabel('Time (sec)')
    ax.set_ylabel('Loss Rate (%)')
    ax.set_title('Loss Rate')
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    output_file = output_dir / "summary.png"
    plt.savefig(output_file, dpi=150)
    plt.close()
    print(f"Saved: {output_file}")


def print_data_quality_report(df: pd.DataFrame):
    """Print data quality analysis report"""
    print("\n" + "=" * 60)
    print("DATA QUALITY REPORT")
    print("=" * 60)

    print(f"\nTotal samples: {len(df)}")
    print(f"Unique connections: {len(df.groupby(['saddr', 'daddr', 'sport', 'dport']))}")

    print("\n--- Non-zero Data Ratio ---")
    for col in ['min_rtt', 'curr_rtt', 'srtt', 'throughput_kbps', 'bytes_sent', 'bytes_acked', 'loss_count', 'dup_ack']:
        if col in df.columns:
            non_zero = (df[col] > 0).sum()
            pct = non_zero / len(df) * 100
            print(f"{col:20s}: {non_zero:5d} / {len(df)} ({pct:5.1f}%)")

    print("\n--- Valid Data (RTT > 0) ---")
    valid = df[df['curr_rtt'] > 0]
    print(f"Valid samples: {len(valid)}")
    if len(valid) > 0:
        print(f"  RTT range: {valid['curr_rtt'].min()/1000:.1f} - {valid['curr_rtt'].max()/1000:.1f} ms")
        print(f"  Avg RTT: {valid['curr_rtt'].mean()/1000:.1f} ms")
        if 'throughput_kbps' in valid.columns:
            tp = valid['throughput_kbps'][valid['throughput_kbps'] > 0]
            if len(tp) > 0:
                print(f"  Throughput: {tp.mean():.0f} kbps avg, {tp.max():.0f} kbps max")

    print("\n--- Issues ---")
    empty_samples = len(df[df['curr_rtt'] == 0])
    print(f"Empty samples (RTT=0): {empty_samples} ({empty_samples/len(df)*100:.1f}%)")

    if empty_samples / len(df) > 0.5:
        print("\nWARNING: >50% empty samples detected!")
        print("Possible causes:")
        print("  1. Connections created but no data exchanged yet")
        print("  2. Short-lived connections (SYN only)")
        print("  3. Sampling interval too short")
        print("\nRecommendation: Reload kernel module with updated code")

    print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(description='LotMonitor Data Visualization')
    parser.add_argument('file', nargs='?', help='Specific data file (optional)')
    parser.add_argument('--no-filter', action='store_true', help='Do not filter empty samples')
    args = parser.parse_args()

    if not HAS_MATPLOTLIB:
        print("Error: matplotlib required")
        print("Install: pip install matplotlib")
        sys.exit(1)

    print("=" * 60)
    print("LotMonitor Data Visualization")
    print("=" * 60)
    print()

    # Load data
    if args.file:
        df = pd.read_csv(args.file)
        df['time_sec'] = (df['timestamp_us'] - df['timestamp_us'].min()) / 1e6
        print(f"Loaded: {args.file} ({len(df)} samples)")
    else:
        df = load_all_data()

    if df.empty:
        print("Error: No data found")
        print("Please run: ./collect.sh")
        sys.exit(1)

    # Print data quality report
    print_data_quality_report(df)

    # Filter valid samples if requested
    if not args.no_filter:
        df_filtered = filter_valid_samples(df)
        if len(df_filtered) < 10:
            print("\nWarning: Too few valid samples, using all data")
            df_filtered = df
    else:
        df_filtered = df

    print(f"\nTime span: {df_filtered['time_sec'].max():.1f} seconds")

    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"\nOutput directory: {OUTPUT_DIR}")
    print()

    # Generate charts
    print("Generating charts...")
    plot_rtt(df_filtered, OUTPUT_DIR)
    plot_throughput(df_filtered, OUTPUT_DIR)
    plot_loss(df_filtered, OUTPUT_DIR)
    plot_timing(df_filtered, OUTPUT_DIR)
    plot_summary(df_filtered, OUTPUT_DIR)

    print()
    print("Visualization complete!")
    print(f"Charts saved in: {OUTPUT_DIR}/")


if __name__ == '__main__':
    main()

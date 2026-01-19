# LotMonitor

基于 Linux Netfilter 的 TCP 连接监控模块，用于 MDP (马尔可夫决策过程) 拥塞控制训练数据采集。

## 快速开始

```bash
# 1. 设置 Python 环境
./setup.sh

# 2. 编译内核模块 (在 Linux 上)
make

# 3. 加载模块
sudo insmod lotmonitor.ko

# 4. 采集数据
./collect.sh 60

# 5. 分析数据
./analyze.sh

# 6. 训练模型
./train.sh 100

# 7. 可视化
./visualize.sh
```

## 文件结构

```
lotspeed/
├── lotmonitor.c        # 内核监控模块
├── mdp_collector.py    # 数据采集/训练主程序
├── visualize.py        # 数据可视化
├── Makefile            # 构建文件
│
├── setup.sh            # 环境设置
├── collect.sh          # 数据采集脚本
├── analyze.sh          # 数据分析脚本
├── train.sh            # 模型训练脚本
├── visualize.sh        # 可视化脚本
├── status.sh           # 状态查看脚本
│
├── requirements.txt    # Python 依赖
├── CLAUDE.md           # 详细文档
│
└── mdp_data/           # 数据目录 (运行后生成)
    ├── samples_*.csv   # 采集的样本
    ├── q_model.npz     # 训练的模型
    └── plots/          # 可视化图表
```

## MDP 状态向量

| 特征 | 说明 |
|------|------|
| min_rtt | 最小 RTT (微秒) |
| curr_rtt | 当前 RTT |
| srtt | 平滑 RTT |
| queue_delay | 队列延迟 |
| loss_rate | 丢包率 |
| throughput | 吞吐量 (kbps) |
| inflight | 在途数据量 |
| rwnd | 接收窗口 |

## 详细文档

查看 [CLAUDE.md](CLAUDE.md) 获取完整文档。

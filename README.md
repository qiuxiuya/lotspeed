### lotspeed merge_bl (⚠️实验性分支，谨慎使用)


* 前置条件 `kernel 6.18.2-bbrv3 or later`


<div align=center>
    <img src="https://github.com/uk0/lotspeed/blob/merge_bl/logo.png" width="400" height="400" />
</div>



### supported kernel

* kernel_version:
    - "6.18.2-bbrv3-patch" # LTS



### lotspeed helper

> 速度起不来执行： /usr/local/bin/lotspeed-autotune restart

```

root@dev-kernel:~# lotspeed help
╔════════════════════════════════════════════════════════════════════╗
║                 LotSpeed v2.2 + NeoQ v3.1 Commands                 ║
╟────────────────────────────────────────────────────────────────────╢
║ Basic Commands                                                     ║
║ lotspeed                                          Interactive menu ║
║ lotspeed start                                  Enable LotSpeed CC ║
║ lotspeed stop                                  Disable LotSpeed CC ║
║ lotspeed restart                                  Restart LotSpeed ║
║ lotspeed status                                    Show all status ║
╟────────────────────────────────────────────────────────────────────╢
║ NeoQ Qdisc                                                         ║
║ lotspeed neoq-start [iface]                      Enable NeoQ qdisc ║
║ lotspeed neoq-stop [iface]                      Disable NeoQ qdisc ║
║ lotspeed neoq-stats                           Show NeoQ statistics ║
╟────────────────────────────────────────────────────────────────────╢
║ Parameter Management                                               ║
║ lotspeed params                                Show all parameters ║
║ lotspeed set <k> <v>                          Set single parameter ║
║ lotspeed preset <name>                         Apply preset config ║
║ lotspeed save                                  Save current config ║
║ lotspeed load                                    Load saved config ║
║ lotspeed edit                                     Edit config file ║
╟────────────────────────────────────────────────────────────────────╢
║ Other                                                              ║
║ lotspeed log                                      Show kernel logs ║
║ lotspeed monitor                               Live log monitoring ║
║ lotspeed autotune                         Auto-tune network params ║
║ lotspeed uninstall                               Remove everything ║
╟────────────────────────────────────────────────────────────────────╢
║ Presets: conservative, balanced, aggressive,                       ║
║          highdelay, datacenter                                     ║
╚════════════════════════════════════════════════════════════════════╝


root@dev-kernel:~# lotspeed autotune help
LotSpeed Auto-Tune Daemon v2.1

Commands:
  (none)    Analyze network and suggest preset
  status    Show current status and metrics
  daemon    Start background daemon
  stop      Stop background daemon
  restart   Restart daemon
  aggressive    Apply anti_loss preset immediately
  ultra         Apply ultra_aggressive preset

Presets (use with '<name>'):
  normal        Balanced settings (default)
  anti_loss     Aggressive loss recovery, fast retransmit
  ultra_aggressive  Maximum throughput, large queues
  loss_recovery Optimized for active loss conditions
  datacenter    Ultra-low latency, ECN-focused
  satellite     Very high delay (300+ ms)
  highdelay     High delay WAN (100-300ms)
  lossy         Moderate packet loss (1-5%)
  lossy_severe  Severe packet loss (>5%)
  jittery       High RTT variance (mobile/WiFi)
  congested     High ECN marks

Environment:
  DEBUG=1   Enable debug output

Files:
  Log:    /var/log/lotspeed-autotune.log
  PID:    /var/run/lotspeed-autotune.pid
  State:  /tmp/lotspeed-autotune.state

```



### branch explanation

* `merge_bl`: lotspeed merge_bl 基于学习历史记录的模式进行加速，并且洲际场景抖动不会降速避让,并且整合了BBRv3的优点。


* auto install


```bash
# 1. install lotspeed module and helper script
curl -fsSL https://raw.githubusercontent.com/uk0/lotspeed/refs/heads/merge_bl/install.sh | sudo bash
#   or
wget -qO- https://raw.githubusercontent.com/uk0/lotspeed/refs/heads/merge_bl/install.sh | sudo bash

```




* manual compile and load

```bash

# 下载代码/编译

git clone https://github.com/uk0/lotspeed.git 

cd lotspeed && make

# 加载模块
sudo insmod lotspeed.ko

# 设置为当前拥塞控制算法
sudo sysctl -w net.ipv4.tcp_congestion_control=lotspeed
sudo sysctl -w net.ipv4.tcp_no_metrics_save=1

# 查看是否生效
sysctl net.ipv4.tcp_congestion_control

# 查看日志
dmesg -w

# 查看链接
ss -nOi | grep lotspeed


# 查看诊断信息
ss -ti
  #bbr_bw_lo: 当前带宽
  #bbr_bw_hi: 最大带宽
  #bbr_min_rtt: 最小 RTT
  #bbr_pacing_gain: pacing 增益
  #bbr_cwnd_gain: rho 系数 (高延迟指标)

```



> 这是一个混合拥塞控制算法，整合了 BBR v3 + FAST TCP + Hybla 三种算法的优点。

---
核心架构

| 模块       | 来源     | 功能                                   |
|------------|----------|----------------------------------------|
| 带宽估计   | BBR v3   | delivered/interval 方式测量带宽        |
| 延迟控制   | FAST TCP | alpha 目标队列长度                     |
| 状态机     | BBR v3   | STARTUP → DRAIN → PROBE_BW → PROBE_RTT |
| 高延迟补偿 | Hybla    | RTT² 补偿，让高延迟链路获得公平吞吐    |

  ---
主要功能

1. BBR v3 状态机
   STARTUP (快速启动) → DRAIN (排空队列) → PROBE_BW (稳态探测) → PROBE_RTT (探测最小RTT)
   ↓
   4个子阶段: CRUISE/REFILL/PROBE_UP/PROBE_DOWN

2. FAST TCP 延迟控制
- 目标队列长度 alpha (默认 20 包)
- 平滑系数 gamma (默认 50%)
- 公式: cwnd = (1-γ)×cwnd + γ×(base_rtt/rtt×cwnd + α)

3. Hybla 高延迟优化
- 当 RTT > 150ms 自动激活
- rho = RTT / RTT_ref 补偿系数
- cwnd 和 pacing 按 rho² 放大

4. ECN 支持 (BBR v3 风格)
- ecn_alpha EWMA 跟踪 ECN 标记率
- 根据 ECN 信号调整 inflight_lo
- STARTUP 阶段 ECN 过高时提前退出

5. 勇敢模式 (抗抖动)
- RTT 突增时冻结窗口/速率
- 防止瞬时抖动导致吞吐下滑
- 冻结期保持 85% 窗口下限

6. 历史缓存
- 按目标 IP 缓存 BW/RTT 信息
- 重连时快速恢复到最佳状态
- TTL 20 分钟，最多 8192 条目

7. 快速路径优化
- app-limited 且无拥塞信号时跳过模型更新
- 减少 CPU 开销

8. ACK 聚合补偿
- 检测 ACK 聚合/延迟 ACK
- 增加 extra_acked 余量防止 underflow

  ---
sysctl 可调参数 (/proc/sys/net/ipv4/lotspeed/)

| 类别     | 参数           | 默认值 | 说明               |
  |----------|----------------|--------|--------------------|
| 基础     | min_cwnd       | 4      | 最小拥塞窗口       |
|          | max_cwnd       | 15000  | 最大拥塞窗口       |
|          | beta           | 717    | 丢包缩减 (~70%)    |
| FAST     | fast_alpha     | 20     | 目标队列长度       |
|          | fast_gamma     | 50     | 平滑系数 (%)       |
| 高延迟   | hd_enable      | 1      | 启用高延迟优化     |
|          | hd_thresh_us   | 150000 | 高延迟阈值 (150ms) |
|          | hd_cwnd_gain   | 150    | 高延迟 cwnd 增益   |
| 勇敢     | brave_enable   | 1      | 启用抗抖动         |
|          | brave_hold_ms  | 300    | 冻结时间           |
| ECN      | ecn_enable     | 1      | 启用 ECN           |
|          | ecn_alpha_gain | 16     | EWMA 增益 (1/16)   |
|          | ecn_thresh     | 50     | ECN 阈值 (%)       |
| 快速路径 | fast_path      | 1      | 启用快速路径       |
| 历史     | hist_enable    | 1      | 启用历史缓存       |
|          | hist_ttl_sec   | 1200   | 缓存 TTL (20分钟)  |

  ---
适用场景

- 高延迟链路 (跨国、卫星) - Hybla 补偿
- 低延迟数据中心 - ECN + FAST 延迟控制
- 不稳定网络 - 勇敢模式抗抖动
- 短连接密集 - 历史缓存加速
- 混合流量 - BBR v3 状态机公平性

---


### test youtube


<div align=center>
    <img src="https://github.com/uk0/lotspeed/blob/merge_bl/zeta-tcp.png" width="1024" height="768" />
</div>


### test iperf3 loss

```bash
# disable lro
ethtool -K eth0 lro off
# 丢包16%
sudo tc qdisc add dev ens3 root netem loss 16%
sudo tc qdisc add dev eth0 root netem loss 16%

#取消丢包
sudo tc qdisc del dev ens3 root netem 
sudo tc qdisc del dev eth0 root netem 

# test command
iperf3 -4 -s -p 35201
iperf3 -c green1 -p 35201 -R -t 30
```


### speedtest 测试结果

* 用之前

![b058ec2ebdb2a095d396cea05dccf499.png](img/b058ec2ebdb2a095d396cea05dccf499.png)

* 用之后

![f7525becdae16659ddfd54d99efe0f66.png](img/f7525becdae16659ddfd54d99efe0f66.png)


PAC (Proactive ACK Control) for TCP Incast Congestion
==========================================

* https://github.com/uk0/TCP-Incast/tree/zeta-tcp 



### Qdisc `neoq`


[QDISC_DOC](QDISC_DOC.md)



-----------------------------------


## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=uk0/lotspeed&type=timeline&logscale&legend=top-left)](https://www.star-history.com/#uk0/lotspeed&type=timeline&logscale&legend=top-left)
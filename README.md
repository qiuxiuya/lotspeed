### lotspeed zeta-tcp


### supported kernel

* kernel_version:
  - "6.18.2" # LTS
  - "6.12.8"
  - "6.11.9"
  - "5.15.99"

### branch explanation

* `zeta-tcp`: lotspeed zeta-tcp 版本([Appex Networking zeta-tcp](https://appexnetworks.com/wp-content/uploads/2024/02/ZetaTCP-Whitepaper-V2.0.pdf))


* auto install


```bash
bash <(curl -sSL https://raw.githubusercontent.com/qiuxiuya/lotspeed/zeta-tcp/install.sh)
#with Xanmod intstall
#bash <(curl -sSL https://raw.githubusercontent.com/qiuxiuya/magicTCP/refs/heads/main/lotspeed.sh)
```


* manual compile and load

```bash

# 下载代码/编译

git clone https://github.com/qiuxiuya/lotspeed.git 

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

```

* Configuration directory

```/sys/module/lotspeed/parameters```

### 配置文件说明

| 参数名称 | 类型 | 默认值 | 源码中的含义与说明 | 取值范围 / 备注 |
| :--- | :--- | :--- | :--- | :--- |
| **`lotserver_rate`** | `unsigned long` | `125000000` | **全局物理带宽上限**。代码注释标注为 **1Gbps = 125MB/s**。任何单连接的目标速率最终不会超过此值。 | 单位：Bytes/sec。实际使用时应设置为物理带宽的 **90%~95%**。 |
| **`lotserver_start_rate`** | `unsigned long` | `125000000` | **软启动速率上限**。新连接初始的目标速率。 | 单位：Bytes/sec。建议设为物理带宽的 50%+。若历史记录速率更高则会覆盖此值。 |
| **`lotserver_gain`** | `unsigned int` | `20` | **拥塞窗口增益系数**。实际增益倍数为 **值/10**。用于计算目标拥塞窗口时放大 BDP 结果。 | 默认 20 即 **2.0 倍**。取值范围通过 `max_t(u32, .., 10)` 隐式限制不低于 1.0x。 |
| **`lotserver_min_cwnd`** | `unsigned int` | `16` | **最小拥塞窗口**。`snd_cwnd` 的下限保护值。 | 单位：packets。回调函数强制修正：`if (lotserver_min_cwnd < 4) lotserver_min_cwnd = 4`。 |
| **`lotserver_max_cwnd`** | `unsigned int` | `15000` | **最大拥塞窗口**。`snd_cwnd` 的绝对物理上限。 | 单位：packets。回调函数强制修正：`if (lotserver_max_cwnd > 100000) lotserver_max_cwnd = 100000`。 |
| **`lotserver_beta`** | `unsigned int` | `717` | **拥塞退让因子**。发生拥塞丢包时，新慢启动门限计算公式：`(cwnd * lotserver_beta) / 1024`。 | 实际保留比例约为 **70%** (717/1024)。回调限制范围：`512 ~ 1024`。 |
| **`lotserver_adaptive`** | `bool` | `true` | **动态自适应开关**。在代码中虽定义为参数，但在当前 v5.6 逻辑中主要用于状态机微调增益的开关判断。 | 取值为 `1` (开启) 或 `0` (关闭)。 |
| **`lotserver_turbo`** | `bool` | `false` | **激进模式开关**。开启后会设置 `snd_ssthresh = TCP_INFINITE_SSTHRESH`，允许慢启动无限制指数增长。 | 取值为 `1` (开启) 或 `0` (关闭)。注意：开启时会忽略部分安全检测。 |
| **`lotserver_verbose`** | `bool` | `false` | **详细日志开关**。控制是否打印状态切换的 `pr_info` 内核日志。 | 取值为 `1` (打印日志) 或 `0` (静默)。 |
| **`lotserver_safe_mode`** | `bool` | `true` | **安全模式开关**。启用后会激活 **丢包率熔断** (15%) 和 **BDP 3倍上限保护**，并在丢包时执行更严格的窗口削减。 | 取值为 `1` (开启) 或 `0` (关闭)。追求极致速度可尝试关闭。 |

###  补充说明
- **`lotserver_start_rate`** 是 v5.6 新增特性，旨在解决“小水管”客户端的启动拥堵问题。若 Zeta 学习引擎命中高带宽历史记录，初始速率会自动抬升。
- **BDP Cap 机制**：当 `safe_mode` 开启时，目标窗口会被强制限制为 `(BDP_packets * 3)`，这是防止内存膨胀（Bufferbloat）的关键保护。
- **修改配置**  ```lotspeed set 参数名称 值``` 设定或直接修改```/sys/module/lotspeed/parameters```对应文件的中值
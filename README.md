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

``/sys/module/lotspeed/parameters``

### 参数说明

参数文件目录：[`/sys/module/lotspeed/parameters`](README.md)

> 速率相关参数单位都是 **Bytes/s**。<br>
> 例如：`125000000` ≈ `125 MB/s` ≈ `1000 Mbps`。

| 参数                   | 默认值      | 用户能理解的作用                                                       | 建议 / 注意                                                                                                       |
| :--------------------- | :---------- | :--------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------------- |
| `lotserver_rate`       | `125000000` | 整个算法的**单连接最高目标速率**，不会往上冲破这个上限。               | 一般填你机器真实带宽上限附近。1Gbps 大约就是`125000000`(125MB/s)。                                                |
| `lotserver_start_rate` | `125000000` | **新连接刚开始时的起跑速度**。后面会根据链路情况自己往上爬或往下收。   | 当前源码默认值和`lotserver_rate` 一样。也就是说，源码默认并不是“低速起步”。如果你想更温和地启动，要手动调低它。 |
| `lotserver_gain`       | `20`        | 控制窗口放大的积极程度，数值越大，跑得越猛。                           | 实际按`值 ÷ 10` 理解，`20` 就是约 `2.0x`。太大更容易抖动。                                                       |
| `lotserver_min_cwnd`   | `16`        | 最小拥塞窗口，保证窗口不会缩得太小。                                   | 单位是包。最小会被强制修正到不低于`4`。                                                                           |
| `lotserver_max_cwnd`   | `15000`     | 最大拥塞窗口，防止窗口无限变大。                                       | 单位是包。最大会被强制限制到不高于`100000`。                                                                      |
| `lotserver_beta`       | `717`       | 遇到明显拥塞后，窗口要保留多少。                                       | 计算方式约等于“保留`70%` 左右”。范围会被限制在 `512 ~ 1024`。越小抢的越凶，建议大于620否则会导致CPU飙高。       |
| `lotserver_turbo`      | `false`     | 激进模式。开了以后，启动和扩张会更猛。                                 | 适合追求速度，不适合求稳。和`lotserver_safe_mode=0` 一起用时最激进。                                              |
| `lotserver_safe_mode`  | `true`      | 安全保护开关。开着时，会更积极处理高延迟、高丢包，也会限制过大的窗口。 | 建议默认开。关掉后更容易冲速度，但也更容易抖、丢包、延迟变高。                                                    |
| `lotserver_verbose`    | `false`     | 是否把状态切换、历史命中这些信息打印到内核日志。                       | --                                                                                                                |

### 补充说明

- [`lotserver_start_rate`](lotspeed.c:88) 是初始目标速率；[`lotserver_rate`](lotspeed.c:86) 是最终上限。
- 当前逻辑会在链路健康时逐步上调目标速率，遇到明显丢包或延迟变差时再回收，不是固定死速率。
- [`lotserver_safe_mode`](lotspeed.c:97) 打开时，代码里还有两个保护：超过 15% 的丢包率会更强地收缩，窗口也会被限制在大约 BDP 的 3 倍以内。
- 参数可直接写到 [`/sys/module/lotspeed/parameters`](README.md) 下面对应文件里，也可以用 `echo 值 > 参数文件` 的方式修改。

### 推荐参数

<table>
  <thead>
    <tr>
      <th>带宽</th>
      <th>模式</th>
      <th>可直接复制命令</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td rowspan="2">500Mbps</td>
      <td>稳定</td>
      <td><pre><code>lotspeed set lotserver_rate 62500000
lotspeed set lotserver_start_rate 50000000
lotspeed set lotserver_gain 22
lotspeed set lotserver_min_cwnd 16
lotspeed set lotserver_max_cwnd 18000
lotspeed set lotserver_beta 717
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td>激进</td>
      <td><pre><code>lotspeed set lotserver_rate 62500000
lotspeed set lotserver_start_rate 62500000
lotspeed set lotserver_gain 26
lotspeed set lotserver_min_cwnd 20
lotspeed set lotserver_max_cwnd 25000
lotspeed set lotserver_beta 640
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td rowspan="2">1Gbps</td>
      <td>稳定</td>
      <td><pre><code>lotspeed set lotserver_rate 125000000
lotspeed set lotserver_start_rate 100000000
lotspeed set lotserver_gain 24
lotspeed set lotserver_min_cwnd 20
lotspeed set lotserver_max_cwnd 26000
lotspeed set lotserver_beta 717
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td>激进</td>
      <td><pre><code>lotspeed set lotserver_rate 125000000
lotspeed set lotserver_start_rate 125000000
lotspeed set lotserver_gain 28
lotspeed set lotserver_min_cwnd 24
lotspeed set lotserver_max_cwnd 36000
lotspeed set lotserver_beta 640
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td rowspan="2">2Gbps</td>
      <td>稳定</td>
      <td><pre><code>lotspeed set lotserver_rate 250000000
lotspeed set lotserver_start_rate 200000000
lotspeed set lotserver_gain 26
lotspeed set lotserver_min_cwnd 24
lotspeed set lotserver_max_cwnd 42000
lotspeed set lotserver_beta 700
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td>激进</td>
      <td><pre><code>lotspeed set lotserver_rate 250000000
lotspeed set lotserver_start_rate 250000000
lotspeed set lotserver_gain 30
lotspeed set lotserver_min_cwnd 32
lotspeed set lotserver_max_cwnd 60000
lotspeed set lotserver_beta 640
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td rowspan="2">5Gbps</td>
      <td>稳定</td>
      <td><pre><code>lotspeed set lotserver_rate 625000000
lotspeed set lotserver_start_rate 500000000
lotspeed set lotserver_gain 28
lotspeed set lotserver_min_cwnd 32
lotspeed set lotserver_max_cwnd 70000
lotspeed set lotserver_beta 704
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
    <tr>
      <td>激进</td>
      <td><pre><code>lotspeed set lotserver_rate 625000000
lotspeed set lotserver_start_rate 625000000
lotspeed set lotserver_gain 30
lotspeed set lotserver_min_cwnd 48
lotspeed set lotserver_max_cwnd 90000
lotspeed set lotserver_beta 640
lotspeed set lotserver_turbo 1
lotspeed set lotserver_safe_mode 1</code></pre></td>
    </tr>
  </tbody>
</table>



#!/bin/bash
#
# LotSpeed Auto-Tune Daemon v2.0
# 基于实际网络状态自动调整 LotSpeed 参数
#
# 数据来源:
#   1. ss -ti          - TCP 连接详情 (RTT, cwnd, retrans, pacing_rate)
#   2. /proc/net/snmp  - 全局 TCP 统计 (重传, 丢包)
#   3. /proc/net/neoq  - NeoQ 队列统计 (如果启用)
#   4. netstat -s      - 协议统计
#
# 使用方法:
#   ./lotspeed-autotune.sh          # 单次检测
#   ./lotspeed-autotune.sh daemon   # 后台守护进程
#   ./lotspeed-autotune.sh status   # 查看状态
#   ./lotspeed-autotune.sh stop     # 停止守护进程
#

set -e

# ============================================================================
# 配置
# ============================================================================

SYSCTL_PATH="/proc/sys/net/ipv4/lotspeed"
LOG_FILE="/var/log/lotspeed-autotune.log"
PID_FILE="/var/run/lotspeed-autotune.pid"
STATE_FILE="/tmp/lotspeed-autotune.state"
HISTORY_FILE="/tmp/lotspeed-autotune.history"

# 采样间隔 (秒)
SAMPLE_INTERVAL=5

# 调整冷却时间 (秒)
ADJUST_COOLDOWN=30

# 历史样本数量
HISTORY_SIZE=12

# 上次调整时间
LAST_ADJUST_TIME=0

# 当前模式
CURRENT_MODE="unknown"

# 历史数据
declare -a RTT_HISTORY=()
declare -a LOSS_HISTORY=()
declare -a RETRANS_HISTORY=()

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================================
# 日志函数
# ============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 写入日志文件
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # 终端输出
    case "$level" in
        INFO)   echo -e "${GREEN}[INFO]${NC} $msg" ;;
        WARN)   echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        ERROR)  echo -e "${RED}[ERROR]${NC} $msg" ;;
        DEBUG)  [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $msg" ;;
        ADJUST) echo -e "${BLUE}[ADJUST]${NC} $msg" ;;
        METRIC) echo -e "${MAGENTA}[METRIC]${NC} $msg" ;;
    esac
}

# ============================================================================
# 参数操作
# ============================================================================

# 检查 sysctl 路径
check_sysctl() {
    [[ -d "$SYSCTL_PATH" ]]
}

# 获取参数
get_param() {
    local param="$1"
    local path="$SYSCTL_PATH/$param"
    if [[ -f "$path" ]]; then
        cat "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 设置参数
set_param() {
    local param="$1"
    local value="$2"
    local path="$SYSCTL_PATH/$param"

    if [[ -f "$path" ]]; then
        local old_value=$(cat "$path" 2>/dev/null)
        if [[ "$old_value" != "$value" ]]; then
            echo "$value" > "$path" 2>/dev/null && {
                log DEBUG "Set $param: $old_value -> $value"
                return 0
            }
        fi
        return 0
    fi
    return 1
}

# ============================================================================
# 数据采集 - 核心改进
# ============================================================================

# 全局变量存储采集结果
declare -A METRICS

# 从 ss -ti 获取 TCP 连接统计 (POSIX 兼容)
collect_ss_stats() {
    local ss_output
    ss_output=$(ss -tin 2>/dev/null) || return

    # 初始化
    local rtt_sum=0 rtt_count=0 rtt_min=999999 rtt_max=0
    local cwnd_sum=0 cwnd_count=0
    local retrans_total=0
    local pacing_sum=0 pacing_count=0
    local conn_count=0
    local lotspeed_count=0

    # 逐行解析 (POSIX 兼容方式)
    while IFS= read -r line; do
        # 跳过空行和标题
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^State ]] && continue

        # 检查是否是 lotspeed 连接
        if echo "$line" | grep -q "lotspeed"; then
            ((lotspeed_count++))
        fi

        # 提取 RTT (格式: rtt:123.456/45.678)
        if echo "$line" | grep -q "rtt:"; then
            local rtt_str=$(echo "$line" | sed -n 's/.*rtt:\([0-9.]*\).*/\1/p')
            if [[ -n "$rtt_str" ]]; then
                # 取整数部分
                local rtt_int=${rtt_str%%.*}
                [[ -z "$rtt_int" || "$rtt_int" == "0" ]] && rtt_int=1

                rtt_sum=$((rtt_sum + rtt_int))
                ((rtt_count++))
                [[ $rtt_int -lt $rtt_min ]] && rtt_min=$rtt_int
                [[ $rtt_int -gt $rtt_max ]] && rtt_max=$rtt_int
            fi
        fi

        # 提取 cwnd
        if echo "$line" | grep -q "cwnd:"; then
            local cwnd_str=$(echo "$line" | sed -n 's/.*cwnd:\([0-9]*\).*/\1/p')
            if [[ -n "$cwnd_str" && "$cwnd_str" -gt 0 ]]; then
                cwnd_sum=$((cwnd_sum + cwnd_str))
                ((cwnd_count++))
            fi
        fi

        # 提取重传 (格式: retrans:0/5)
        if echo "$line" | grep -q "retrans:"; then
            local retrans_str=$(echo "$line" | sed -n 's/.*retrans:[0-9]*\/\([0-9]*\).*/\1/p')
            [[ -n "$retrans_str" ]] && retrans_total=$((retrans_total + retrans_str))
        fi

        # 提取 pacing_rate (格式: pacing_rate 1234Mbps)
        if echo "$line" | grep -q "pacing_rate"; then
            local pacing_str=$(echo "$line" | sed -n 's/.*pacing_rate \([0-9.]*\).*/\1/p')
            if [[ -n "$pacing_str" ]]; then
                local pacing_int=${pacing_str%%.*}
                [[ -n "$pacing_int" && "$pacing_int" -gt 0 ]] && {
                    pacing_sum=$((pacing_sum + pacing_int))
                    ((pacing_count++))
                }
            fi
        fi

        ((conn_count++))
    done <<< "$ss_output"

    # 计算统计值
    METRICS[conn_count]=$conn_count
    METRICS[lotspeed_count]=$lotspeed_count

    if [[ $rtt_count -gt 0 ]]; then
        METRICS[rtt_avg]=$((rtt_sum / rtt_count))
        METRICS[rtt_min]=$rtt_min
        METRICS[rtt_max]=$rtt_max
        METRICS[rtt_jitter]=$((rtt_max - rtt_min))
    else
        METRICS[rtt_avg]=0
        METRICS[rtt_min]=0
        METRICS[rtt_max]=0
        METRICS[rtt_jitter]=0
    fi

    if [[ $cwnd_count -gt 0 ]]; then
        METRICS[cwnd_avg]=$((cwnd_sum / cwnd_count))
    else
        METRICS[cwnd_avg]=0
    fi

    METRICS[retrans_total]=$retrans_total

    if [[ $pacing_count -gt 0 ]]; then
        METRICS[pacing_avg]=$((pacing_sum / pacing_count))
    else
        METRICS[pacing_avg]=0
    fi
}

# 从 /proc/net/snmp 获取全局 TCP 统计
collect_snmp_stats() {
    if [[ ! -f /proc/net/snmp ]]; then
        METRICS[tcp_retrans_segs]=0
        METRICS[tcp_in_segs]=0
        METRICS[tcp_out_segs]=0
        return
    fi

    # 获取 TCP 行
    local tcp_keys=$(grep "^Tcp:" /proc/net/snmp | head -1)
    local tcp_vals=$(grep "^Tcp:" /proc/net/snmp | tail -1)

    # 解析字段位置
    local retrans_idx=0 in_idx=0 out_idx=0
    local idx=1
    for key in $tcp_keys; do
        case "$key" in
            RetransSegs) retrans_idx=$idx ;;
            InSegs) in_idx=$idx ;;
            OutSegs) out_idx=$idx ;;
        esac
        ((idx++))
    done

    # 提取值
    METRICS[tcp_retrans_segs]=$(echo "$tcp_vals" | awk "{print \$$retrans_idx}")
    METRICS[tcp_in_segs]=$(echo "$tcp_vals" | awk "{print \$$in_idx}")
    METRICS[tcp_out_segs]=$(echo "$tcp_vals" | awk "{print \$$out_idx}")
}

# 从 /proc/net/netstat 获取扩展 TCP 统计
collect_netstat_stats() {
    if [[ ! -f /proc/net/netstat ]]; then
        METRICS[tcp_loss_events]=0
        METRICS[tcp_fast_retrans]=0
        METRICS[tcp_timeouts]=0
        METRICS[tcp_ecn_marks]=0
        return
    fi

    local tcpext_keys=$(grep "^TcpExt:" /proc/net/netstat | head -1)
    local tcpext_vals=$(grep "^TcpExt:" /proc/net/netstat | tail -1)

    # 查找字段位置
    local loss_idx=0 fast_idx=0 timeout_idx=0 ecn_idx=0
    local idx=1
    for key in $tcpext_keys; do
        case "$key" in
            TCPLossEvents|TCPLoss) loss_idx=$idx ;;
            TCPFastRetrans) fast_idx=$idx ;;
            TCPTimeouts) timeout_idx=$idx ;;
            TCPECNFallback|TCPECERecv) ecn_idx=$idx ;;
        esac
        ((idx++))
    done

    METRICS[tcp_loss_events]=$(echo "$tcpext_vals" | awk "{print \$$loss_idx}" 2>/dev/null || echo "0")
    METRICS[tcp_fast_retrans]=$(echo "$tcpext_vals" | awk "{print \$$fast_idx}" 2>/dev/null || echo "0")
    METRICS[tcp_timeouts]=$(echo "$tcpext_vals" | awk "{print \$$timeout_idx}" 2>/dev/null || echo "0")
    METRICS[tcp_ecn_marks]=$(echo "$tcpext_vals" | awk "{print \$$ecn_idx}" 2>/dev/null || echo "0")

    # 清理空值
    [[ -z "${METRICS[tcp_loss_events]}" ]] && METRICS[tcp_loss_events]=0
    [[ -z "${METRICS[tcp_fast_retrans]}" ]] && METRICS[tcp_fast_retrans]=0
    [[ -z "${METRICS[tcp_timeouts]}" ]] && METRICS[tcp_timeouts]=0
    [[ -z "${METRICS[tcp_ecn_marks]}" ]] && METRICS[tcp_ecn_marks]=0
}

# 从 NeoQ 获取队列统计
collect_neoq_stats() {
    METRICS[neoq_packets]=0
    METRICS[neoq_dropped]=0
    METRICS[neoq_ecn_marked]=0
    METRICS[neoq_avg_delay]=0

    if [[ ! -f /proc/net/neoq ]]; then
        return
    fi

    local neoq_output=$(cat /proc/net/neoq 2>/dev/null)

    # 解析各层统计并累加
    local total_packets=0 total_dropped=0 total_ecn=0

    while IFS= read -r line; do
        # 匹配数据行 (Express, High, Normal, Bulk)
        if echo "$line" | grep -qE "^\s*(Express|High|Normal|Bulk)"; then
            local packets=$(echo "$line" | awk '{print $2}')
            local dropped=$(echo "$line" | awk '{print $4}')
            local ecn=$(echo "$line" | awk '{print $5}')

            [[ -n "$packets" && "$packets" =~ ^[0-9]+$ ]] && total_packets=$((total_packets + packets))
            [[ -n "$dropped" && "$dropped" =~ ^[0-9]+$ ]] && total_dropped=$((total_dropped + dropped))
            [[ -n "$ecn" && "$ecn" =~ ^[0-9]+$ ]] && total_ecn=$((total_ecn + ecn))
        fi

        # 提取平均延迟
        if echo "$line" | grep -q "Average:"; then
            local avg_delay=$(echo "$line" | sed -n 's/.*Average:\s*\([0-9]*\).*/\1/p')
            [[ -n "$avg_delay" ]] && METRICS[neoq_avg_delay]=$avg_delay
        fi
    done <<< "$neoq_output"

    METRICS[neoq_packets]=$total_packets
    METRICS[neoq_dropped]=$total_dropped
    METRICS[neoq_ecn_marked]=$total_ecn
}

# 计算派生指标
calculate_derived_metrics() {
    # 丢包率 (基于 NeoQ 或 SNMP)
    local drop_rate=0
    if [[ ${METRICS[neoq_packets]} -gt 1000 ]]; then
        drop_rate=$((METRICS[neoq_dropped] * 1000 / METRICS[neoq_packets]))
    elif [[ ${METRICS[tcp_out_segs]} -gt 1000 ]]; then
        drop_rate=$((METRICS[tcp_retrans_segs] * 1000 / METRICS[tcp_out_segs]))
    fi
    METRICS[drop_rate_permille]=$drop_rate  # 千分比

    # ECN 标记率
    local ecn_rate=0
    if [[ ${METRICS[neoq_packets]} -gt 1000 ]]; then
        ecn_rate=$((METRICS[neoq_ecn_marked] * 1000 / METRICS[neoq_packets]))
    fi
    METRICS[ecn_rate_permille]=$ecn_rate

    # RTT 变异系数 (jitter / avg * 100)
    if [[ ${METRICS[rtt_avg]} -gt 0 ]]; then
        METRICS[rtt_cv]=$((METRICS[rtt_jitter] * 100 / METRICS[rtt_avg]))
    else
        METRICS[rtt_cv]=0
    fi

    log DEBUG "Derived: drop_rate=${drop_rate}‰ ecn_rate=${ecn_rate}‰ rtt_cv=${METRICS[rtt_cv]}%"
}

# 综合采集
collect_all_metrics() {
    log DEBUG "Collecting metrics..."

    collect_ss_stats
    collect_snmp_stats
    collect_netstat_stats
    collect_neoq_stats
    calculate_derived_metrics

    log DEBUG "RTT: avg=${METRICS[rtt_avg]}ms min=${METRICS[rtt_min]}ms max=${METRICS[rtt_max]}ms jitter=${METRICS[rtt_jitter]}ms"
    log DEBUG "Connections: total=${METRICS[conn_count]} lotspeed=${METRICS[lotspeed_count]} cwnd_avg=${METRICS[cwnd_avg]}"
    log DEBUG "Retrans: total=${METRICS[retrans_total]} loss_events=${METRICS[tcp_loss_events]}"
}

# ============================================================================
# 历史数据管理
# ============================================================================

update_history() {
    # 添加新样本
    RTT_HISTORY+=("${METRICS[rtt_avg]}")
    LOSS_HISTORY+=("${METRICS[drop_rate_permille]}")
    RETRANS_HISTORY+=("${METRICS[retrans_total]}")

    # 保持固定大小
    while [[ ${#RTT_HISTORY[@]} -gt $HISTORY_SIZE ]]; do
        RTT_HISTORY=("${RTT_HISTORY[@]:1}")
    done
    while [[ ${#LOSS_HISTORY[@]} -gt $HISTORY_SIZE ]]; do
        LOSS_HISTORY=("${LOSS_HISTORY[@]:1}")
    done
    while [[ ${#RETRANS_HISTORY[@]} -gt $HISTORY_SIZE ]]; do
        RETRANS_HISTORY=("${RETRANS_HISTORY[@]:1}")
    done
}

# 计算历史平均
get_history_avg() {
    local -n arr=$1
    local sum=0 count=0
    for val in "${arr[@]}"; do
        sum=$((sum + val))
        ((count++))
    done
    [[ $count -gt 0 ]] && echo $((sum / count)) || echo 0
}

# 计算历史趋势 (正=上升, 负=下降)
get_history_trend() {
    local -n arr=$1
    local len=${#arr[@]}
    [[ $len -lt 3 ]] && echo 0 && return

    local first_half=0 second_half=0
    local mid=$((len / 2))

    for ((i=0; i<mid; i++)); do
        first_half=$((first_half + arr[i]))
    done
    for ((i=mid; i<len; i++)); do
        second_half=$((second_half + arr[i]))
    done

    first_half=$((first_half / mid))
    second_half=$((second_half / (len - mid)))

    echo $((second_half - first_half))
}

# ============================================================================
# 网络类型检测 - 核心改进
# ============================================================================

detect_network_type() {
    local rtt=${METRICS[rtt_avg]}
    local jitter=${METRICS[rtt_jitter]}
    local rtt_cv=${METRICS[rtt_cv]}
    local drop_rate=${METRICS[drop_rate_permille]}
    local ecn_rate=${METRICS[ecn_rate_permille]}
    local retrans=${METRICS[retrans_total]}

    # 使用历史数据平滑判断
    local rtt_trend=$(get_history_trend RTT_HISTORY)
    local loss_trend=$(get_history_trend LOSS_HISTORY)

    local network_type="normal"
    local confidence=50
    local reason=""

    # 1. 数据中心网络: RTT < 5ms, 抖动 < 2ms, 无丢包
    if [[ $rtt -lt 5 && $jitter -lt 2 && $drop_rate -eq 0 ]]; then
        network_type="datacenter"
        confidence=95
        reason="RTT=${rtt}ms<5ms, jitter=${jitter}ms<2ms, no loss"

    # 2. 低延迟局域网: RTT < 20ms, 低抖动
    elif [[ $rtt -lt 20 && $rtt_cv -lt 30 && $drop_rate -lt 5 ]]; then
        network_type="lan"
        confidence=85
        reason="RTT=${rtt}ms<20ms, cv=${rtt_cv}%<30%"

    # 3. 超高延迟: RTT > 300ms (卫星)
    elif [[ $rtt -gt 300 ]]; then
        network_type="satellite"
        confidence=90
        reason="RTT=${rtt}ms>300ms (satellite-like)"

    # 4. 高延迟网络: RTT > 100ms
    elif [[ $rtt -gt 100 ]]; then
        network_type="highdelay"
        confidence=80
        reason="RTT=${rtt}ms>100ms"

    # 5. 严重丢包: > 5%
    elif [[ $drop_rate -gt 50 ]]; then
        network_type="lossy_severe"
        confidence=90
        reason="drop_rate=${drop_rate}‰>5%"

    # 6. 中度丢包: 1-5%
    elif [[ $drop_rate -gt 10 ]]; then
        network_type="lossy"
        confidence=75
        reason="drop_rate=${drop_rate}‰ (1-5%)"

    # 7. 高抖动: 变异系数 > 100% 或绝对抖动 > 50ms
    elif [[ $rtt_cv -gt 100 || $jitter -gt 50 ]]; then
        network_type="jittery"
        confidence=80
        reason="jitter=${jitter}ms, cv=${rtt_cv}%"

    # 8. 拥塞 (ECN 标记高)
    elif [[ $ecn_rate -gt 100 ]]; then
        network_type="congested"
        confidence=75
        reason="ecn_rate=${ecn_rate}‰>10%"

    # 9. 轻度拥塞
    elif [[ $ecn_rate -gt 30 || $drop_rate -gt 5 ]]; then
        network_type="mild_congestion"
        confidence=60
        reason="ecn=${ecn_rate}‰ drop=${drop_rate}‰"

    # 10. 正常网络
    else
        network_type="normal"
        confidence=70
        reason="RTT=${rtt}ms, jitter=${jitter}ms, drop=${drop_rate}‰"
    fi

    # 趋势调整置信度
    if [[ $rtt_trend -gt 20 ]]; then
        log DEBUG "RTT trending up (+${rtt_trend}ms), network may be degrading"
        confidence=$((confidence - 10))
    elif [[ $rtt_trend -lt -20 ]]; then
        log DEBUG "RTT trending down (${rtt_trend}ms), network improving"
        confidence=$((confidence + 5))
    fi

    METRICS[network_type]=$network_type
    METRICS[confidence]=$confidence
    METRICS[detection_reason]="$reason"

    log DEBUG "Network type: $network_type (confidence: $confidence%) - $reason"
    echo "$network_type"
}

# ============================================================================
# 参数预设 - 完整版 (对应 lotspeed.c 所有参数)
# ============================================================================

apply_preset() {
    local preset="$1"
    log ADJUST "Applying preset: $preset"

    case "$preset" in
        datacenter)
            # 数据中心: 超低延迟，最大吞吐
            set_param "min_cwnd" 64
            set_param "max_cwnd" 30000
            set_param "beta" 819           # 80% (快速恢复)
            set_param "fast_alpha" 5       # 很小的队列目标
            set_param "fast_gamma" 30      # 快速响应

            set_param "hd_enable" 0        # 不需要高延迟优化
            set_param "brave_enable" 0     # 不需要抗抖动
            set_param "turbo_startup" 1
            set_param "startup_gain" 350   # 激进启动

            set_param "ecn_enable" 1
            set_param "ecn_factor" 90
            set_param "ecn_thresh" 20      # 低阈值，敏感响应
            set_param "ecn_alpha_gain" 32  # 快速 EWMA

            set_param "fast_path" 1
            set_param "pacing_margin" 1
            set_param "probe_rtt_cwnd_pct" 70
            set_param "inflight_headroom" 10
            ;;

        lan)
            # 局域网: 低延迟，高吞吐
            set_param "min_cwnd" 64
            set_param "max_cwnd" 20000
            set_param "beta" 768           # 75%
            set_param "fast_alpha" 10
            set_param "fast_gamma" 40

            set_param "hd_enable" 0
            set_param "brave_enable" 0
            set_param "turbo_startup" 1
            set_param "startup_gain" 300

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 30
            set_param "ecn_alpha_gain" 24

            set_param "fast_path" 1
            set_param "pacing_margin" 2
            ;;

        satellite)
            # 卫星链路: 超高延迟 (300-800ms)
            set_param "min_cwnd" 256
            set_param "max_cwnd" 50000     # 需要大窗口
            set_param "beta" 870           # 85% (保守恢复)
            set_param "fast_alpha" 100     # 允许较大队列
            set_param "fast_gamma" 80      # 慢速平滑

            set_param "hd_enable" 1
            set_param "hd_thresh_us" 200000
            set_param "hd_ref_us" 30000
            set_param "hd_cwnd_gain" 250   # 2.5x cwnd
            set_param "hd_pacing_gain" 200 # 2x pacing
            set_param "hd_min_cwnd" 64
            set_param "hd_startup_boost" 100
            set_param "hd_boost" 50
            set_param "hd_rho_max" 600     # 最大 6x

            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 40   # 允许 40% RTT 波动
            set_param "brave_hold_ms" 1000
            set_param "brave_floor_pct" 90

            set_param "turbo_startup" 1
            set_param "startup_gain" 400
            set_param "startup_min_rounds" 5

            set_param "ecn_enable" 0       # 卫星链路 ECN 不可靠
            set_param "fast_path" 0
            set_param "probe_rtt_cwnd_pct" 80
            set_param "probe_rtt_duration" 300

            set_param "bw_probe_base_us" 5000000   # 5秒探测间隔
            set_param "bw_probe_rand_us" 2000000
            ;;

        highdelay)
            # 高延迟广域网 (100-300ms)
            set_param "min_cwnd" 128
            set_param "max_cwnd" 25000
            set_param "beta" 819           # 80%
            set_param "fast_alpha" 50
            set_param "fast_gamma" 60

            set_param "hd_enable" 1
            set_param "hd_thresh_us" 80000
            set_param "hd_ref_us" 40000
            set_param "hd_cwnd_gain" 180
            set_param "hd_pacing_gain" 150
            set_param "hd_min_cwnd" 32
            set_param "hd_startup_boost" 60
            set_param "hd_boost" 30
            set_param "hd_rho_max" 450

            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 30
            set_param "brave_hold_ms" 500
            set_param "brave_floor_pct" 85

            set_param "turbo_startup" 1
            set_param "startup_gain" 350

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 40
            set_param "ecn_max_rtt_us" 10000

            set_param "fast_path" 1
            set_param "probe_rtt_cwnd_pct" 60
            ;;

        lossy_severe)
            # 严重丢包环境 (>5%)
            set_param "min_cwnd" 16
            set_param "max_cwnd" 5000
            set_param "beta" 512           # 50% (极保守)
            set_param "fast_alpha" 15
            set_param "fast_gamma" 30

            set_param "hd_enable" 0
            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 20
            set_param "brave_hold_ms" 100
            set_param "brave_floor_pct" 70

            set_param "turbo_startup" 0    # 禁用快速启动
            set_param "startup_gain" 200

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 10
            set_param "ecn_factor" 70

            set_param "fast_recovery" 1
            set_param "recovery_boost" 10
            set_param "loss_thresh" 1
            set_param "full_loss_cnt" 3
            set_param "inflight_headroom" 25
            ;;

        lossy)
            # 中度丢包环境 (1-5%)
            set_param "min_cwnd" 32
            set_param "max_cwnd" 8000
            set_param "beta" 614           # 60%
            set_param "fast_alpha" 25
            set_param "fast_gamma" 40

            set_param "hd_enable" 0
            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 25
            set_param "brave_hold_ms" 200
            set_param "brave_floor_pct" 80

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 15
            set_param "ecn_factor" 75

            set_param "fast_recovery" 1
            set_param "recovery_boost" 15
            set_param "loss_thresh" 2
            set_param "inflight_headroom" 20
            ;;

        jittery)
            # 高抖动网络 (移动网络/WiFi)
            set_param "min_cwnd" 48
            set_param "max_cwnd" 12000
            set_param "beta" 716
            set_param "fast_alpha" 30
            set_param "fast_gamma" 70      # 慢速平滑

            set_param "hd_enable" 0
            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 50   # 允许大波动
            set_param "brave_hold_ms" 600
            set_param "brave_floor_pct" 85

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 35

            set_param "fast_path" 0        # 禁用快速路径，需要持续监控
            set_param "ack_agg_enable" 1
            set_param "extra_acked_max_us" 200000
            ;;

        congested)
            # 拥塞网络 (ECN 高)
            set_param "min_cwnd" 32
            set_param "max_cwnd" 10000
            set_param "beta" 665           # 65%
            set_param "fast_alpha" 15
            set_param "fast_gamma" 50

            set_param "brave_enable" 0

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 10
            set_param "ecn_factor" 80
            set_param "ecn_alpha_gain" 8   # 快速响应 ECN
            set_param "full_ecn_cnt" 1

            set_param "pacing_margin" 5
            set_param "inflight_headroom" 20
            ;;

        mild_congestion)
            # 轻度拥塞
            set_param "min_cwnd" 48
            set_param "max_cwnd" 12000
            set_param "beta" 716
            set_param "fast_alpha" 18
            set_param "fast_gamma" 50

            set_param "ecn_enable" 1
            set_param "ecn_thresh" 25
            set_param "ecn_alpha_gain" 12

            set_param "pacing_margin" 3
            ;;

        normal|*)
            # 默认/平衡模式
            set_param "min_cwnd" 64
            set_param "max_cwnd" 15000
            set_param "beta" 717
            set_param "fast_alpha" 20
            set_param "fast_gamma" 50

            set_param "hd_enable" 1
            set_param "hd_thresh_us" 150000
            set_param "hd_ref_us" 50000
            set_param "hd_cwnd_gain" 150
            set_param "hd_pacing_gain" 130
            set_param "hd_min_cwnd" 10
            set_param "hd_startup_boost" 50
            set_param "hd_boost" 25
            set_param "hd_rho_max" 400

            set_param "brave_enable" 1
            set_param "brave_rtt_pct" 25
            set_param "brave_hold_ms" 300
            set_param "brave_floor_pct" 85

            set_param "hist_enable" 1
            set_param "hist_ttl_sec" 1200

            set_param "ecn_enable" 1
            set_param "ecn_factor" 85
            set_param "ecn_thresh" 50
            set_param "ecn_alpha_gain" 16
            set_param "ecn_max_rtt_us" 5000

            set_param "turbo_startup" 1
            set_param "startup_gain" 300
            set_param "startup_min_rounds" 3

            set_param "ack_agg_enable" 1
            set_param "extra_acked_max_us" 100000

            set_param "fast_recovery" 1
            set_param "recovery_boost" 20

            set_param "pacing_margin" 2
            set_param "probe_rtt_cwnd_pct" 50
            set_param "probe_rtt_duration" 150
            set_param "fast_path" 1

            set_param "loss_thresh" 2
            set_param "full_loss_cnt" 6
            set_param "inflight_headroom" 15
            ;;
    esac
}

# ============================================================================
# 实时微调
# ============================================================================

fine_tune() {
    local network_type="$1"

    # 1. ECN 标记率高 -> 降低阈值
    if [[ ${METRICS[ecn_rate_permille]} -gt 50 ]]; then
        local cur=$(get_param "ecn_thresh")
        if [[ $cur -gt 15 ]]; then
            local new=$((cur - 5))
            set_param "ecn_thresh" $new
            log ADJUST "ECN rate high (${METRICS[ecn_rate_permille]}‰), ecn_thresh: $cur -> $new"
        fi
    fi

    # 2. 抖动突然增大 -> 增加 brave_hold_ms
    if [[ ${METRICS[rtt_jitter]} -gt 30 ]]; then
        local cur=$(get_param "brave_hold_ms")
        local target=$((METRICS[rtt_jitter] * 10))
        target=$((target > 800 ? 800 : target))
        if [[ $target -gt $cur ]]; then
            set_param "brave_hold_ms" $target
            set_param "brave_enable" 1
            log ADJUST "High jitter (${METRICS[rtt_jitter]}ms), brave_hold_ms: $cur -> $target"
        fi
    fi

    # 3. RTT 持续上升 -> 降低 fast_alpha
    local rtt_trend=$(get_history_trend RTT_HISTORY)
    if [[ $rtt_trend -gt 30 ]]; then
        local cur=$(get_param "fast_alpha")
        if [[ $cur -gt 10 ]]; then
            local new=$((cur - 5))
            set_param "fast_alpha" $new
            log ADJUST "RTT trending up (+${rtt_trend}), fast_alpha: $cur -> $new"
        fi
    fi

    # 4. 丢包率上升 -> 降低 max_cwnd
    local loss_trend=$(get_history_trend LOSS_HISTORY)
    if [[ $loss_trend -gt 10 ]]; then
        local cur=$(get_param "max_cwnd")
        if [[ $cur -gt 5000 ]]; then
            local new=$((cur * 9 / 10))
            set_param "max_cwnd" $new
            log ADJUST "Loss trending up (+${loss_trend}), max_cwnd: $cur -> $new"
        fi
    fi

    # 5. 网络稳定且 cwnd 使用率低 -> 可以提高 max_cwnd
    if [[ ${METRICS[rtt_cv]} -lt 20 && ${METRICS[drop_rate_permille]} -eq 0 ]]; then
        local cur_max=$(get_param "max_cwnd")
        local avg_cwnd=${METRICS[cwnd_avg]}
        if [[ $avg_cwnd -gt 0 && $((avg_cwnd * 2)) -gt $cur_max && $cur_max -lt 20000 ]]; then
            local new=$((cur_max + 1000))
            [[ $new -gt 25000 ]] && new=25000
            set_param "max_cwnd" $new
            log ADJUST "Network stable, avg_cwnd=$avg_cwnd, max_cwnd: $cur_max -> $new"
        fi
    fi
}

# ============================================================================
# 主调整逻辑
# ============================================================================

do_adjust() {
    local now=$(date +%s)
    local elapsed=$((now - LAST_ADJUST_TIME))

    # 冷却检查
    if [[ $elapsed -lt $ADJUST_COOLDOWN ]]; then
        log DEBUG "In cooldown ($elapsed < $ADJUST_COOLDOWN seconds)"
        return 0
    fi

    # 更新历史
    update_history

    # 检测网络类型
    local network_type=$(detect_network_type)

    # 模式变化 -> 应用预设
    if [[ "$network_type" != "$CURRENT_MODE" ]]; then
        log INFO "Network type changed: $CURRENT_MODE -> $network_type (confidence: ${METRICS[confidence]}%)"

        # 只有置信度 > 60% 才切换
        if [[ ${METRICS[confidence]} -ge 60 ]]; then
            apply_preset "$network_type"
            CURRENT_MODE="$network_type"
            LAST_ADJUST_TIME=$now

            # 保存状态
            cat > "$STATE_FILE" << EOF
mode=$CURRENT_MODE
last_adjust=$LAST_ADJUST_TIME
rtt_avg=${METRICS[rtt_avg]}
rtt_jitter=${METRICS[rtt_jitter]}
drop_rate=${METRICS[drop_rate_permille]}
ecn_rate=${METRICS[ecn_rate_permille]}
confidence=${METRICS[confidence]}
reason=${METRICS[detection_reason]}
EOF
        else
            log DEBUG "Low confidence (${METRICS[confidence]}%), keeping current mode"
        fi
    else
        # 同模式下微调
        fine_tune "$network_type"
    fi
}

# ============================================================================
# 状态显示
# ============================================================================

show_status() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              LotSpeed Auto-Tune Status v2.0                        ║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"

    # 守护进程状态
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${CYAN}║${NC} Daemon: ${GREEN}Running${NC} (PID: $pid)"
        else
            echo -e "${CYAN}║${NC} Daemon: ${RED}Stopped${NC} (stale PID)"
        fi
    else
        echo -e "${CYAN}║${NC} Daemon: ${YELLOW}Not running${NC}"
    fi

    # LotSpeed 模块状态
    if check_sysctl; then
        echo -e "${CYAN}║${NC} Module: ${GREEN}Loaded${NC}"
    else
        echo -e "${CYAN}║${NC} Module: ${RED}Not loaded${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
        return
    fi

    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"

    # 采集指标
    collect_all_metrics

    echo -e "${CYAN}║${NC} ${YELLOW}Network Metrics:${NC}"
    printf "${CYAN}║${NC}   %-14s %s\n" "Connections:" "${METRICS[conn_count]} total, ${METRICS[lotspeed_count]} lotspeed"
    printf "${CYAN}║${NC}   %-14s avg=%dms min=%dms max=%dms jitter=%dms\n" "RTT:" \
        "${METRICS[rtt_avg]}" "${METRICS[rtt_min]}" "${METRICS[rtt_max]}" "${METRICS[rtt_jitter]}"
    printf "${CYAN}║${NC}   %-14s %d (cv=%d%%)\n" "Avg cwnd:" "${METRICS[cwnd_avg]}" "${METRICS[rtt_cv]}"
    printf "${CYAN}║${NC}   %-14s %d\n" "Retrans:" "${METRICS[retrans_total]}"
    printf "${CYAN}║${NC}   %-14s %d‰ (%.1f%%)\n" "Drop rate:" "${METRICS[drop_rate_permille]}" \
        "$(echo "scale=1; ${METRICS[drop_rate_permille]} / 10" | bc 2>/dev/null || echo "?")"
    printf "${CYAN}║${NC}   %-14s %d‰\n" "ECN rate:" "${METRICS[ecn_rate_permille]}"

    if [[ ${METRICS[neoq_packets]} -gt 0 ]]; then
        echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${YELLOW}NeoQ Stats:${NC}"
        printf "${CYAN}║${NC}   Packets: %d  Dropped: %d  ECN: %d  Delay: %dus\n" \
            "${METRICS[neoq_packets]}" "${METRICS[neoq_dropped]}" \
            "${METRICS[neoq_ecn_marked]}" "${METRICS[neoq_avg_delay]}"
    fi

    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"

    # 检测网络类型
    local network_type=$(detect_network_type)
    echo -e "${CYAN}║${NC} ${YELLOW}Detection:${NC}"
    printf "${CYAN}║${NC}   Type:       ${GREEN}%s${NC}\n" "$network_type"
    printf "${CYAN}║${NC}   Confidence: %d%%\n" "${METRICS[confidence]}"
    printf "${CYAN}║${NC}   Reason:     %s\n" "${METRICS[detection_reason]}"

    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC} ${YELLOW}Current Parameters:${NC}"
    printf "${CYAN}║${NC}   min_cwnd=%-6d max_cwnd=%-6d beta=%-4d\n" \
        "$(get_param min_cwnd)" "$(get_param max_cwnd)" "$(get_param beta)"
    printf "${CYAN}║${NC}   fast_alpha=%-4d fast_gamma=%-4d\n" \
        "$(get_param fast_alpha)" "$(get_param fast_gamma)"
    printf "${CYAN}║${NC}   hd_enable=%-4d  hd_cwnd_gain=%-4d hd_pacing_gain=%-4d\n" \
        "$(get_param hd_enable)" "$(get_param hd_cwnd_gain)" "$(get_param hd_pacing_gain)"
    printf "${CYAN}║${NC}   brave_enable=%-2d brave_hold_ms=%-4d\n" \
        "$(get_param brave_enable)" "$(get_param brave_hold_ms)"
    printf "${CYAN}║${NC}   ecn_enable=%-4d ecn_thresh=%-4d ecn_factor=%-4d\n" \
        "$(get_param ecn_enable)" "$(get_param ecn_thresh)" "$(get_param ecn_factor)"

    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
}

# ============================================================================
# 守护进程控制
# ============================================================================

start_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log ERROR "Daemon already running (PID: $pid)"
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    if ! check_sysctl; then
        log ERROR "LotSpeed module not loaded"
        exit 1
    fi

    log INFO "Starting LotSpeed Auto-Tune daemon v2.0..."

    nohup "$0" run >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"

    log INFO "Daemon started (PID: $pid)"
    echo -e "${GREEN}Daemon started (PID: $pid)${NC}"
    echo "Log: $LOG_FILE"
}

stop_daemon() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo -e "${YELLOW}Daemon not running${NC}"
        return 0
    fi

    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        log INFO "Stopping daemon (PID: $pid)..."
        kill "$pid"
        rm -f "$PID_FILE"
        echo -e "${GREEN}Daemon stopped${NC}"
    else
        rm -f "$PID_FILE"
        echo -e "${YELLOW}Daemon was not running (cleaned stale PID)${NC}"
    fi
}

run_loop() {
    log INFO "Auto-tune daemon started"

    if ! check_sysctl; then
        log ERROR "LotSpeed module not loaded"
        exit 1
    fi

    # 初始检测
    collect_all_metrics
    CURRENT_MODE=$(detect_network_type)
    apply_preset "$CURRENT_MODE"
    LAST_ADJUST_TIME=$(date +%s)
    log INFO "Initial mode: $CURRENT_MODE (confidence: ${METRICS[confidence]}%)"

    # 主循环
    while true; do
        collect_all_metrics
        do_adjust
        sleep $SAMPLE_INTERVAL
    done
}

# ============================================================================
# 单次运行
# ============================================================================

run_once() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              LotSpeed Auto-Tune - Analysis                         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo

    if ! check_sysctl; then
        echo -e "${YELLOW}[WARN] LotSpeed module not loaded - running in analysis mode${NC}"
        echo
    fi

    echo -e "${YELLOW}Step 1: Collecting metrics...${NC}"
    collect_all_metrics
    echo -e "${GREEN}Done${NC}"
    echo

    echo -e "${YELLOW}Step 2: Current metrics:${NC}"
    printf "  %-20s %d total, %d using lotspeed\n" "Connections:" "${METRICS[conn_count]}" "${METRICS[lotspeed_count]}"
    printf "  %-20s avg=%dms min=%dms max=%dms jitter=%dms\n" "RTT:" \
        "${METRICS[rtt_avg]}" "${METRICS[rtt_min]}" "${METRICS[rtt_max]}" "${METRICS[rtt_jitter]}"
    printf "  %-20s %d (variation: %d%%)\n" "Average cwnd:" "${METRICS[cwnd_avg]}" "${METRICS[rtt_cv]}"
    printf "  %-20s %d\n" "Total retrans:" "${METRICS[retrans_total]}"
    printf "  %-20s %d‰ (%.2f%%)\n" "Drop rate:" "${METRICS[drop_rate_permille]}" \
        "$(echo "scale=2; ${METRICS[drop_rate_permille]} / 10" | bc 2>/dev/null || echo "?")"
    printf "  %-20s %d‰\n" "ECN mark rate:" "${METRICS[ecn_rate_permille]}"
    echo

    echo -e "${YELLOW}Step 3: Detecting network type...${NC}"
    local network_type=$(detect_network_type)
    echo -e "  Type:       ${GREEN}$network_type${NC}"
    echo -e "  Confidence: ${METRICS[confidence]}%"
    echo -e "  Reason:     ${METRICS[detection_reason]}"
    echo

    echo -e "${YELLOW}Step 4: Recommended preset:${NC}"
    echo -e "  ${GREEN}$network_type${NC}"
    echo
    echo "  Key parameters for this preset:"
    case "$network_type" in
        datacenter)
            echo "    - Aggressive settings for ultra-low latency"
            echo "    - max_cwnd=30000, beta=819 (80%)"
            echo "    - hd_enable=0, brave_enable=0"
            echo "    - ecn_thresh=20 (sensitive)"
            ;;
        satellite)
            echo "    - Optimized for very high latency (300+ ms)"
            echo "    - max_cwnd=50000, min_cwnd=256"
            echo "    - hd_cwnd_gain=250 (2.5x compensation)"
            echo "    - brave_hold_ms=1000"
            ;;
        highdelay)
            echo "    - Optimized for 100-300ms RTT"
            echo "    - max_cwnd=25000, hd_enable=1"
            echo "    - hd_cwnd_gain=180, hd_pacing_gain=150"
            ;;
        lossy*)
            echo "    - Conservative for packet loss"
            echo "    - Lower max_cwnd, higher recovery"
            echo "    - beta=512-614 (50-60%)"
            ;;
        jittery)
            echo "    - Brave mode for RTT variance"
            echo "    - brave_hold_ms=600, brave_rtt_pct=50"
            ;;
        congested)
            echo "    - ECN-responsive"
            echo "    - ecn_thresh=10, ecn_alpha_gain=8"
            ;;
        *)
            echo "    - Balanced settings"
            ;;
    esac
    echo

    if check_sysctl; then
        echo -e "${YELLOW}Apply this preset? [y/N]${NC} "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            apply_preset "$network_type"
            echo -e "${GREEN}Preset applied!${NC}"
        else
            echo "Skipped."
        fi
    fi
}

# ============================================================================
# 主入口
# ============================================================================

case "${1:-}" in
    daemon|start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    status)
        show_status
        ;;
    run)
        run_loop
        ;;
    once|test|"")
        run_once
        ;;
    -h|--help|help)
        echo "LotSpeed Auto-Tune Daemon v2.0"
        echo
        echo "Usage: $0 [command]"
        echo
        echo "Commands:"
        echo "  (none)    Analyze network and suggest preset"
        echo "  status    Show current status and metrics"
        echo "  daemon    Start background daemon"
        echo "  stop      Stop background daemon"
        echo "  restart   Restart daemon"
        echo
        echo "Environment:"
        echo "  DEBUG=1   Enable debug output"
        echo
        echo "Files:"
        echo "  Log:    $LOG_FILE"
        echo "  PID:    $PID_FILE"
        echo "  State:  $STATE_FILE"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run '$0 --help' for usage"
        exit 1
        ;;
esac

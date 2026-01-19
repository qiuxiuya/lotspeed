// SPDX-License-Identifier: GPL-2.0
/*
 * MDP-based TCP Congestion Control using eBPF struct_ops
 *
 * 这是一个使用 eBPF 实现 MDP 策略的 TCP 拥塞控制示例
 *
 * 要求: Linux 5.6+ (struct_ops 支持)
 * 编译: clang -O2 -target bpf -c ebpf_cc_demo.c -o ebpf_cc_demo.o
 * 加载: bpftool struct_ops register ebpf_cc_demo.o
 * 使用: sysctl -w net.ipv4.tcp_congestion_control=mdp_cc
 */

#include <linux/bpf.h>
#include <linux/types.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

/* TCP 相关结构定义 (简化版) */
struct tcp_sock {
    __u32 snd_cwnd;
    __u32 snd_ssthresh;
    __u32 srtt_us;
    __u32 mdev_us;
    __u32 min_rtt_us;
    __u32 packets_out;
    __u32 lost_out;
    __u32 sacked_out;
    __u64 bytes_acked;
    __u64 bytes_sent;
    /* ... 更多字段 ... */
};

struct sock {
    /* ... */
};

/* MDP 状态特征 (离散化) */
struct mdp_state {
    __u8 rtt_level;      /* 0-7: RTT 膨胀级别 */
    __u8 loss_level;     /* 0-3: 丢包级别 */
    __u8 util_level;     /* 0-3: 带宽利用率级别 */
    __u8 trend;          /* 0-2: RTT 趋势 (下降/稳定/上升) */
};

/* 动作: cwnd 调整因子 (定点数, *1000) */
#define ACTION_DECREASE_LARGE  500   /* 0.5x */
#define ACTION_DECREASE_MEDIUM 750   /* 0.75x */
#define ACTION_DECREASE_SMALL  900   /* 0.9x */
#define ACTION_MAINTAIN        1000  /* 1.0x */
#define ACTION_INCREASE_SMALL  1050  /* 1.05x */
#define ACTION_INCREASE_MEDIUM 1100  /* 1.1x */
#define ACTION_INCREASE_LARGE  1250  /* 1.25x */

/* Q 表: state -> action
 * 由用户空间训练后写入
 * Key: (rtt_level << 5) | (loss_level << 3) | (util_level << 1) | trend
 * Value: action index (0-6)
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 256);  /* 8 * 4 * 4 * 2 = 256 states */
    __type(key, __u32);
    __type(value, __u32);
} q_table SEC(".maps");

/* 连接状态缓存 */
struct conn_state {
    __u32 prev_rtt;
    __u32 prev_cwnd;
    __u32 prev_loss;
    __u64 last_update;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u64);  /* socket pointer as key */
    __type(value, struct conn_state);
} conn_cache SEC(".maps");

/* 统计信息 (用于调试和监控) */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 8);
    __type(key, __u32);
    __type(value, __u64);
} stats SEC(".maps");

#define STAT_DECISIONS     0
#define STAT_INCREASE      1
#define STAT_DECREASE      2
#define STAT_MAINTAIN      3

/* 辅助函数 */
static __always_inline void update_stat(__u32 idx)
{
    __u64 *val = bpf_map_lookup_elem(&stats, &idx);
    if (val)
        (*val)++;
}

/* 离散化 RTT 级别 (0-7) */
static __always_inline __u8 discretize_rtt(__u32 curr_rtt, __u32 min_rtt)
{
    if (min_rtt == 0)
        return 4;  /* 中等 */

    __u32 ratio = (curr_rtt * 100) / min_rtt;

    if (ratio < 105) return 0;       /* < 1.05x: 无拥塞 */
    if (ratio < 115) return 1;       /* 1.05-1.15x: 轻微 */
    if (ratio < 130) return 2;       /* 1.15-1.30x */
    if (ratio < 150) return 3;       /* 1.30-1.50x */
    if (ratio < 200) return 4;       /* 1.50-2.00x */
    if (ratio < 300) return 5;       /* 2.00-3.00x */
    if (ratio < 500) return 6;       /* 3.00-5.00x */
    return 7;                        /* > 5.00x: 严重拥塞 */
}

/* 离散化丢包级别 (0-3) */
static __always_inline __u8 discretize_loss(__u32 lost, __u32 sent)
{
    if (sent == 0)
        return 0;

    __u32 rate_ppm = (lost * 1000000) / sent;

    if (rate_ppm < 1000)   return 0;  /* < 0.1% */
    if (rate_ppm < 10000)  return 1;  /* 0.1-1% */
    if (rate_ppm < 50000)  return 2;  /* 1-5% */
    return 3;                         /* > 5% */
}

/* 离散化利用率 (0-3) */
static __always_inline __u8 discretize_util(__u32 inflight, __u32 cwnd)
{
    if (cwnd == 0)
        return 2;

    __u32 util = (inflight * 100) / cwnd;

    if (util < 50)  return 0;  /* 低利用率 */
    if (util < 80)  return 1;  /* 中等 */
    if (util < 95)  return 2;  /* 高 */
    return 3;                  /* 满载 */
}

/* 计算 RTT 趋势 (0=下降, 1=稳定, 2=上升) */
static __always_inline __u8 calc_trend(__u32 curr_rtt, __u32 prev_rtt)
{
    if (prev_rtt == 0)
        return 1;

    __s32 diff = (__s32)curr_rtt - (__s32)prev_rtt;
    __s32 threshold = (__s32)(prev_rtt / 10);  /* 10% 变化阈值 */

    if (diff < -threshold) return 0;  /* 下降 */
    if (diff > threshold)  return 2;  /* 上升 */
    return 1;                         /* 稳定 */
}

/* 获取动作 */
static __always_inline __u32 get_action(struct mdp_state *state)
{
    __u32 key = (state->rtt_level << 5) |
                (state->loss_level << 3) |
                (state->util_level << 1) |
                state->trend;

    __u32 *action = bpf_map_lookup_elem(&q_table, &key);
    if (!action)
        return ACTION_MAINTAIN;

    /* 动作映射 */
    switch (*action) {
    case 0: return ACTION_DECREASE_LARGE;
    case 1: return ACTION_DECREASE_MEDIUM;
    case 2: return ACTION_DECREASE_SMALL;
    case 3: return ACTION_MAINTAIN;
    case 4: return ACTION_INCREASE_SMALL;
    case 5: return ACTION_INCREASE_MEDIUM;
    case 6: return ACTION_INCREASE_LARGE;
    default: return ACTION_MAINTAIN;
    }
}

/*
 * =============================================================================
 * TCP Congestion Control Callbacks (struct_ops)
 * =============================================================================
 */

SEC("struct_ops/mdp_cc_init")
void BPF_PROG(mdp_cc_init, struct sock *sk)
{
    /* 初始化连接状态 */
    struct conn_state state = {0};
    __u64 key = (__u64)sk;

    bpf_map_update_elem(&conn_cache, &key, &state, BPF_ANY);
}

SEC("struct_ops/mdp_cc_release")
void BPF_PROG(mdp_cc_release, struct sock *sk)
{
    /* 清理连接状态 */
    __u64 key = (__u64)sk;
    bpf_map_delete_elem(&conn_cache, &key);
}

SEC("struct_ops/mdp_cc_cong_control")
void BPF_PROG(mdp_cc_cong_control, struct sock *sk, const struct rate_sample *rs)
{
    struct tcp_sock *tp = (struct tcp_sock *)sk;
    __u64 key = (__u64)sk;

    /* 获取连接缓存 */
    struct conn_state *cached = bpf_map_lookup_elem(&conn_cache, &key);
    if (!cached)
        return;

    /* 读取当前状态 */
    __u32 curr_rtt = tp->srtt_us >> 3;  /* srtt 是 8 倍放大的 */
    __u32 min_rtt = tp->min_rtt_us;
    __u32 cwnd = tp->snd_cwnd;
    __u32 inflight = tp->packets_out;
    __u32 lost = tp->lost_out;
    __u64 sent = tp->bytes_sent;

    /* 构建 MDP 状态 */
    struct mdp_state state;
    state.rtt_level = discretize_rtt(curr_rtt, min_rtt);
    state.loss_level = discretize_loss(lost, (__u32)(sent / 1500));  /* 假设 MSS=1500 */
    state.util_level = discretize_util(inflight, cwnd);
    state.trend = calc_trend(curr_rtt, cached->prev_rtt);

    /* 查询策略 */
    __u32 action = get_action(&state);

    /* 应用动作 */
    __u32 new_cwnd = (cwnd * action) / 1000;

    /* 边界检查 */
    if (new_cwnd < 2)
        new_cwnd = 2;
    if (new_cwnd > 65535)
        new_cwnd = 65535;

    /* 更新 cwnd */
    tp->snd_cwnd = new_cwnd;

    /* 更新统计 */
    update_stat(STAT_DECISIONS);
    if (action > ACTION_MAINTAIN)
        update_stat(STAT_INCREASE);
    else if (action < ACTION_MAINTAIN)
        update_stat(STAT_DECREASE);
    else
        update_stat(STAT_MAINTAIN);

    /* 缓存当前状态 */
    cached->prev_rtt = curr_rtt;
    cached->prev_cwnd = cwnd;
    cached->prev_loss = lost;
    cached->last_update = bpf_ktime_get_ns();
}

SEC("struct_ops/mdp_cc_ssthresh")
__u32 BPF_PROG(mdp_cc_ssthresh, struct sock *sk)
{
    struct tcp_sock *tp = (struct tcp_sock *)sk;

    /* 丢包时: ssthresh = max(cwnd * 0.7, 2) */
    __u32 ssthresh = (tp->snd_cwnd * 7) / 10;
    if (ssthresh < 2)
        ssthresh = 2;

    return ssthresh;
}

SEC("struct_ops/mdp_cc_undo_cwnd")
__u32 BPF_PROG(mdp_cc_undo_cwnd, struct sock *sk)
{
    struct tcp_sock *tp = (struct tcp_sock *)sk;

    /* 误判恢复: 恢复到之前的 cwnd */
    __u64 key = (__u64)sk;
    struct conn_state *cached = bpf_map_lookup_elem(&conn_cache, &key);

    if (cached && cached->prev_cwnd > tp->snd_cwnd)
        return cached->prev_cwnd;

    return tp->snd_cwnd;
}

/* 注册为 TCP 拥塞控制算法 */
SEC(".struct_ops")
struct tcp_congestion_ops mdp_cc = {
    .init           = (void *)mdp_cc_init,
    .release        = (void *)mdp_cc_release,
    .cong_control   = (void *)mdp_cc_cong_control,
    .ssthresh       = (void *)mdp_cc_ssthresh,
    .undo_cwnd      = (void *)mdp_cc_undo_cwnd,
    .name           = "mdp_cc",
};

char _license[] SEC("license") = "GPL";

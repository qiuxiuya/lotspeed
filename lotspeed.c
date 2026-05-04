/*
 * lotspeed_zeta_v5_6.c
 * "公路超跑" Zeta-TCP (FAST Edition)
 * FAST (Jin et al., INFOCOM 2004) delay-based congestion control
 * Loss response aligned with RFC3517 fast recovery; generic behavior friendly to RFC3135 PEP paths.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/version.h>
#include <linux/moduleparam.h>
#include <linux/jiffies.h>
#include <linux/time.h>
#include <linux/string.h>
#include <linux/math64.h>
#include <linux/jhash.h>
#include <net/tcp.h>
#include <linux/tcp.h>
#include <linux/hashtable.h>
#if IS_ENABLED(CONFIG_IPV6)
#include <net/ipv6.h>
#endif
#include <linux/rculist.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define SAFETY_CHECK(ptr, ret) do { \
    if (unlikely(!(ptr))) { \
        return ret; \
    } \
} while (0)

#define SAFE_DIV64(n, d) ((d) ? div64_u64((n), (d)) : 0)

// 检测 cong_control API 版本
// - 4.13 之前: void (*)(struct sock *, u32, int, const struct rate_sample *)
// - 4.13 到 6.10: void (*)(struct sock *, const struct rate_sample *)
// - 6.11+: void (*)(struct sock *, u32, int, const struct rate_sample *)
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 13, 0)
#define LOTSPEED_OLD_CONG_CONTROL_API
#endif

#ifdef LOTSPEED_NEW_CONG_CONTROL_API
// 6.11+ 使用带 ack/flag 参数的新 API (由 Makefile 定义)
#define LOTSPEED_611_CONG_CONTROL_API
#endif

#define LOTSPEED_BETA_SCALE 1024
#define LOTSPEED_PROBE_RTT_INTERVAL_MS 10000
#define LOTSPEED_PROBE_RTT_DURATION_MS 500
#define LOTSPEED_MAX_U32 ((u32)~0U)
#define FAST_GAMMA_SCALE 100

// --- 模块参数（仅保留 FAST 所需） ---
static unsigned long lotserver_rate = 125000000;      // 全局速率上限 (bytes/sec)
static unsigned int lotserver_min_cwnd = 16;          // 最小拥塞窗口 (packets)
static unsigned int lotserver_max_cwnd = 15000;       // 最大拥塞窗口 (packets)
static unsigned int lotserver_beta = 616;             // 丢包时缩放 (cwnd * beta / 1024)
static bool lotserver_turbo = false;                  // 关闭缩减（仅供实验）
static bool lotserver_safe_mode = true;               // true 时遵守 beta 缩减
static unsigned int lotserver_fast_alpha = 20;        // 目标队列长度（包）
static unsigned int lotserver_fast_gamma = 50;        // 平滑系数（百分比）
static unsigned int lotserver_fast_ss_exit = 25;      // RTT 膨胀阈值（百分比）触发退出 SS
// 高延迟补偿/激进模式
static bool lotserver_hd_enable = true;
static unsigned int lotserver_hd_thresh_us = 180000;  // 超过此 RTT 视为高延迟（默认 180ms）
static unsigned int lotserver_hd_ref_us = 80000;      // 参考 RTT，用于 Hybla 式倍率（默认 80ms）
static unsigned int lotserver_hd_gamma_boost = 20;    // 高延迟时额外 gamma 提升（百分比）
static unsigned int lotserver_hd_alpha_boost = 10;    // 高延迟时额外队列目标（包）
// 轻量历史缓存
static bool lotserver_hist_enable = true;
static unsigned int lotserver_hist_ttl_sec = 1200;    // TTL: 20 分钟
static unsigned int lotserver_hist_min_samples = 6;   // 需要至少 6 个样本
static unsigned int lotserver_hist_max_entries = 8192;// 最大条目数
// 勇敢模型：抗抖动、维持高发包
static bool lotserver_brave_enable = true;
static unsigned int lotserver_brave_rtt_pct = 25;     // RTT 突增容忍度（百分比）
static unsigned int lotserver_brave_hold_ms = 400;    // 突增后冻结窗口/速率时间
static unsigned int lotserver_brave_floor_pct = 85;   // 冻结时窗口不低于此比例
static unsigned int lotserver_brave_push_pct = 8;     // 正常时目标窗口额外提升

// 参数校验
static int param_set_min_cwnd(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret && lotserver_min_cwnd < 2)
        lotserver_min_cwnd = 2;
    return ret;
}

static int param_set_max_cwnd(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret && lotserver_max_cwnd < lotserver_min_cwnd)
        lotserver_max_cwnd = lotserver_min_cwnd;
    return ret;
}

static int param_set_beta(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret) {
        if (lotserver_beta > LOTSPEED_BETA_SCALE)
            lotserver_beta = LOTSPEED_BETA_SCALE;
        if (lotserver_beta < 128)
            lotserver_beta = 128; // 不要过于激进
    }
    return ret;
}

static int param_set_alpha(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret) {
        unsigned int *p = (unsigned int *)kp->arg;
        if (*p < 1) *p = 1;
        if (*p > 10000) *p = 10000;
    }
    return ret;
}

static int param_set_percent_100(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret) {
        unsigned int *p = (unsigned int *)kp->arg;
        if (*p < 1) *p = 1;
        if (*p > 100) *p = 100;
    }
    return ret;
}

static int param_set_usec(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret) {
        unsigned int *p = (unsigned int *)kp->arg;
        if (*p < 1000) *p = 1000;
        if (*p > 2000000) *p = 2000000; // 2s 上限，防止极端数值
    }
    return ret;
}

static int param_set_msec(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);
    if (!ret) {
        unsigned int *p = (unsigned int *)kp->arg;
        if (*p < 1) *p = 1;
        if (*p > 600000) *p = 600000; // 10 分钟上限
    }
    return ret;
}

static const struct kernel_param_ops param_ops_rate = { .set = param_set_ulong, .get = param_get_ulong, };
static const struct kernel_param_ops param_ops_min_cwnd = { .set = param_set_min_cwnd, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_max_cwnd = { .set = param_set_max_cwnd, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_beta = { .set = param_set_beta, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_alpha = { .set = param_set_alpha, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_percent_100 = { .set = param_set_percent_100, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_usec = { .set = param_set_usec, .get = param_get_uint, };
static const struct kernel_param_ops param_ops_msec = { .set = param_set_msec, .get = param_get_uint, };

module_param_cb(lotserver_rate, &param_ops_rate, &lotserver_rate, 0644);
module_param_cb(lotserver_min_cwnd, &param_ops_min_cwnd, &lotserver_min_cwnd, 0644);
module_param_cb(lotserver_max_cwnd, &param_ops_max_cwnd, &lotserver_max_cwnd, 0644);
module_param_cb(lotserver_beta, &param_ops_beta, &lotserver_beta, 0644);
module_param(lotserver_turbo, bool, 0644);
module_param(lotserver_safe_mode, bool, 0644);
module_param_cb(lotserver_fast_alpha, &param_ops_alpha, &lotserver_fast_alpha, 0644);
module_param_cb(lotserver_fast_gamma, &param_ops_percent_100, &lotserver_fast_gamma, 0644);
module_param_cb(lotserver_fast_ss_exit, &param_ops_percent_100, &lotserver_fast_ss_exit, 0644);
module_param(lotserver_hd_enable, bool, 0644);
module_param_cb(lotserver_hd_thresh_us, &param_ops_usec, &lotserver_hd_thresh_us, 0644);
module_param_cb(lotserver_hd_ref_us, &param_ops_usec, &lotserver_hd_ref_us, 0644);
module_param_cb(lotserver_hd_gamma_boost, &param_ops_percent_100, &lotserver_hd_gamma_boost, 0644);
module_param_cb(lotserver_hd_alpha_boost, &param_ops_alpha, &lotserver_hd_alpha_boost, 0644);
module_param(lotserver_hist_enable, bool, 0644);
module_param_cb(lotserver_hist_ttl_sec, &param_ops_rate, &lotserver_hist_ttl_sec, 0644);
module_param_cb(lotserver_hist_min_samples, &param_ops_min_cwnd, &lotserver_hist_min_samples, 0644);
module_param_cb(lotserver_hist_max_entries, &param_ops_max_cwnd, &lotserver_hist_max_entries, 0644);
module_param(lotserver_brave_enable, bool, 0644);
module_param_cb(lotserver_brave_rtt_pct, &param_ops_percent_100, &lotserver_brave_rtt_pct, 0644);
module_param_cb(lotserver_brave_hold_ms, &param_ops_msec, &lotserver_brave_hold_ms, 0644);
module_param_cb(lotserver_brave_floor_pct, &param_ops_percent_100, &lotserver_brave_floor_pct, 0644);
module_param_cb(lotserver_brave_push_pct, &param_ops_percent_100, &lotserver_brave_push_pct, 0644);

// --- 状态机 ---
enum lotspeed_state {
    FAST_STARTUP = 0,
    FAST_CA,
    PROBE_RTT,
};

struct lotspeed {
    u64 pacing_rate;      // 上次计算的 pacing 速率
    u32 rtt_min;          // 基准 RTT（usec）
    u32 last_state_ts;    // 状态切换时间戳（jiffies32）
    u32 probe_rtt_ts;     // 上次探测 RTT（jiffies32）
    u32 brave_hold_cwnd;  // 勇敢模式冻结时的窗口基线
    u32 brave_freeze_until; // 勇敢模式冻结截至时间（jiffies32）
    enum lotspeed_state state;
    bool ss_mode;
};

struct ls_hist_key {
    u8 family;
    union {
        __be32 v4;
#if IS_ENABLED(CONFIG_IPV6)
        struct in6_addr v6;
#endif
    } addr;
};

// 历史样本
struct ls_hist_entry {
    struct hlist_node node;
    struct rcu_head rcu;
    struct ls_hist_key key;
    u64 bw_bytes_sec;
    u32 rtt_min_us;
    u32 rtt_median_us;
    u32 loss_ewma;
    u32 sample_cnt;
    u64 last_update_jif;
};

#define LS_HIST_BITS 12
static DEFINE_HASHTABLE(ls_hist_table, LS_HIST_BITS);
static DEFINE_SPINLOCK(ls_hist_lock);
static struct kmem_cache *ls_hist_cache;
static atomic_t ls_hist_count = ATOMIC_INIT(0);

static bool ls_get_dst_key(const struct sock *sk, struct ls_hist_key *key)
{
    memset(key, 0, sizeof(*key));

    if (!sk)
        return false;

    switch (sk->sk_family) {
    case AF_INET:
        if (!sk->sk_daddr)
            return false;
        key->family = AF_INET;
        key->addr.v4 = sk->sk_daddr;
        return true;
#if IS_ENABLED(CONFIG_IPV6)
    case AF_INET6:
        if (ipv6_addr_any(&sk->sk_v6_daddr))
            return false;
        key->family = AF_INET6;
        key->addr.v6 = sk->sk_v6_daddr;
        return true;
#endif
    default:
        return false;
    }
}

static u32 ls_hist_hash_key(const struct ls_hist_key *key)
{
    switch (key->family) {
    case AF_INET:
        return jhash_1word((__force u32)key->addr.v4, AF_INET);
#if IS_ENABLED(CONFIG_IPV6)
    case AF_INET6:
        return jhash(key->addr.v6.s6_addr, sizeof(key->addr.v6.s6_addr), AF_INET6);
#endif
    default:
        return 0;
    }
}

static bool ls_hist_key_equal(const struct ls_hist_key *a, const struct ls_hist_key *b)
{
    if (a->family != b->family)
        return false;

    switch (a->family) {
    case AF_INET:
        return a->addr.v4 == b->addr.v4;
#if IS_ENABLED(CONFIG_IPV6)
    case AF_INET6:
        return ipv6_addr_equal(&a->addr.v6, &b->addr.v6);
#endif
    default:
        return false;
    }
}

static void enter_state(struct sock *sk, enum lotspeed_state new_state)
{
    struct lotspeed *ca = inet_csk_ca(sk);
    SAFETY_CHECK(ca, );
    if (ca->state != new_state) {
        ca->state = new_state;
        ca->last_state_ts = tcp_jiffies32;
    }
}

static void lotspeed_update_rtt(struct sock *sk, u32 rtt_us)
{
    struct lotspeed *ca = inet_csk_ca(sk);
    SAFETY_CHECK(ca, );
    if (!rtt_us)
        return;
    if (!ca->rtt_min || rtt_us < ca->rtt_min)
        ca->rtt_min = rtt_us;
}

// --- 初始化与释放 ---
static void lotspeed_init(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct lotspeed *ca = inet_csk_ca(sk);
    struct ls_hist_entry *hist = NULL;
    struct ls_hist_key dst_key;
    u32 hist_hash = 0;

    memset(ca, 0, sizeof(*ca));
    ca->state = FAST_STARTUP;
    ca->ss_mode = true;
    ca->last_state_ts = tcp_jiffies32;
    ca->probe_rtt_ts = tcp_jiffies32;
    tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 13, 0)
    cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
#endif

    // 历史初始化：如果命中历史，预填充基准 RTT 与起始 cwnd
    if (lotserver_hist_enable && ls_get_dst_key(sk, &dst_key)) {
        hist_hash = ls_hist_hash_key(&dst_key);
        rcu_read_lock();
        hash_for_each_possible_rcu(ls_hist_table, hist, node, hist_hash) {
            if (ls_hist_key_equal(&hist->key, &dst_key)) {
                u64 age_ms = jiffies_to_msecs(get_jiffies_64() - hist->last_update_jif);
                if (age_ms < (u64)lotserver_hist_ttl_sec * 1000 &&
                    hist->sample_cnt >= lotserver_hist_min_samples &&
                    hist->rtt_min_us > 0) {
                    u32 init_cwnd;
                    ca->rtt_min = hist->rtt_min_us;
                    // 计算初始 cwnd，避免在 clamp_t 内使用复杂三元表达式
                    if (hist->rtt_min_us && tp->mss_cache) {
                        u64 bw_cwnd = div64_u64(hist->bw_bytes_sec * hist->rtt_min_us,
                                                (u64)tp->mss_cache * 1000000ULL);
                        init_cwnd = (u32)min_t(u64, bw_cwnd, UINT_MAX);
                    } else {
                        init_cwnd = lotserver_min_cwnd;
                    }
                    tp->snd_cwnd = clamp_t(u32, init_cwnd, lotserver_min_cwnd, lotserver_max_cwnd);
                    ca->ss_mode = false;
                    ca->state = FAST_CA;
                }
                break;
            }
        }
        rcu_read_unlock();
    }
}

static void lotspeed_release(struct sock *sk)
{
    struct lotspeed *ca = inet_csk_ca(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    struct ls_hist_key dst_key;
    u32 hist_hash;

    if (!lotserver_hist_enable || !ca || !ls_get_dst_key(sk, &dst_key))
        return;

    hist_hash = ls_hist_hash_key(&dst_key);

    if (tp->srtt_us == 0 || tp->mss_cache == 0)
        return;

    if (ca->rtt_min == 0)
        ca->rtt_min = tp->srtt_us >> 3;

    // 汇总样本
    {
        struct ls_hist_entry *entry = NULL, *oldest = NULL;
        u64 oldest_jif = ULLONG_MAX;
        int bkt;
        u64 bw_bytes_sec = 0;
        u32 loss = 0;

        if (tp->snd_cwnd > 0 && ca->rtt_min > 0) {
            u64 bytes_in_flight = (u64)tp->snd_cwnd * tp->mss_cache;
            bw_bytes_sec = SAFE_DIV64(bytes_in_flight * USEC_PER_SEC, ca->rtt_min);
        }

        spin_lock_bh(&ls_hist_lock);
        hash_for_each_possible(ls_hist_table, entry, node, hist_hash) {
            if (ls_hist_key_equal(&entry->key, &dst_key)) {
                // 更新现有
                entry->bw_bytes_sec = entry->bw_bytes_sec ? (entry->bw_bytes_sec * 7 + bw_bytes_sec * 3) / 10 : bw_bytes_sec;
                entry->rtt_min_us = entry->rtt_min_us && ca->rtt_min ? min(entry->rtt_min_us, ca->rtt_min) : ca->rtt_min;
                entry->rtt_median_us = entry->rtt_median_us ? (entry->rtt_median_us * 7 + (tp->srtt_us >> 3)) / 8 : (tp->srtt_us >> 3);
                entry->loss_ewma = loss;
                entry->sample_cnt++;
                entry->last_update_jif = get_jiffies_64();
                goto out_unlock;
            }
        }

        // 容量控制
        if (atomic_read(&ls_hist_count) >= lotserver_hist_max_entries) {
            struct ls_hist_entry *tmp;
            hash_for_each(ls_hist_table, bkt, tmp, node) {
                if (tmp->last_update_jif < oldest_jif) {
                    oldest_jif = tmp->last_update_jif;
                    oldest = tmp;
                }
            }
            if (oldest) {
                hash_del(&oldest->node);
                kmem_cache_free(ls_hist_cache, oldest);
                atomic_dec(&ls_hist_count);
            }
        }

        entry = kmem_cache_alloc(ls_hist_cache, GFP_ATOMIC);
        if (entry) {
            entry->key = dst_key;
            entry->bw_bytes_sec = bw_bytes_sec;
            entry->rtt_min_us = ca->rtt_min;
            entry->rtt_median_us = tp->srtt_us >> 3;
            entry->loss_ewma = loss;
            entry->sample_cnt = 1;
            entry->last_update_jif = get_jiffies_64();
            hash_add(ls_hist_table, &entry->node, hist_hash);
            atomic_inc(&ls_hist_count);
        }
out_unlock:
        spin_unlock_bh(&ls_hist_lock);
    }
}

// --- 核心 FAST 控制 ---
static void lotspeed_adapt_and_control(struct sock *sk, const struct rate_sample *rs, int flag)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct lotspeed *ca = inet_csk_ca(sk);
    u32 rtt_us = tp->srtt_us >> 3;
    u32 base_rtt;
    u32 cwnd = tp->snd_cwnd;
    u32 mss = tp->mss_cache ? : 1460;
    u64 gamma;
    u32 pipe;
    bool high_delay_path;
    bool hist_hint = false;
    u32 hist_alpha = 0;
    bool brave_active = false;
    u32 now_jif = tcp_jiffies32;

    SAFETY_CHECK(tp && ca, );
    (void)flag;

    // 历史 RTT 预热
    if (lotserver_hist_enable && ca->rtt_min == 0) {
        struct ls_hist_entry *hist;
        struct ls_hist_key dst_key;

        if (ls_get_dst_key(sk, &dst_key)) {
            u32 hist_hash = ls_hist_hash_key(&dst_key);

            rcu_read_lock();
            hash_for_each_possible_rcu(ls_hist_table, hist, node, hist_hash) {
                if (ls_hist_key_equal(&hist->key, &dst_key)) {
                    u64 age_ms = jiffies_to_msecs(get_jiffies_64() - hist->last_update_jif);
                    if (age_ms < (u64)lotserver_hist_ttl_sec * 1000 &&
                        hist->sample_cnt >= lotserver_hist_min_samples &&
                        hist->rtt_min_us > 0) {
                        ca->rtt_min = hist->rtt_min_us;
                        hist_alpha = hist->loss_ewma < 3 ? lotserver_fast_alpha + 5 : lotserver_fast_alpha;
                        hist_hint = true;
                    }
                    break;
                }
            }
            rcu_read_unlock();
        }
    }

    lotspeed_update_rtt(sk, rtt_us);
    if (!rtt_us)
        rtt_us = ca->rtt_min ? ca->rtt_min : 1000;
    base_rtt = ca->rtt_min ? ca->rtt_min : rtt_us;
    high_delay_path = lotserver_hd_enable && base_rtt >= lotserver_hd_thresh_us;
    brave_active = lotserver_brave_enable && time_before((unsigned long)now_jif, (unsigned long)ca->brave_freeze_until);

    // 定期进入 PROBE_RTT 刷新基准 RTT
    if (ca->state != PROBE_RTT &&
        time_after32(tcp_jiffies32, ca->probe_rtt_ts + msecs_to_jiffies(LOTSPEED_PROBE_RTT_INTERVAL_MS))) {
        enter_state(sk, PROBE_RTT);
    }

    if (ca->state == PROBE_RTT) {
        tp->snd_cwnd = lotserver_min_cwnd;
        if (time_after32(tcp_jiffies32, ca->last_state_ts + msecs_to_jiffies(LOTSPEED_PROBE_RTT_DURATION_MS))) {
            ca->probe_rtt_ts = tcp_jiffies32;
            enter_state(sk, ca->ss_mode ? FAST_STARTUP : FAST_CA);
        }
        goto out_pacing;
    }

    // 勇敢模式：检测突发 RTT 抖动，冻结窗口/速率，防止瞬时下滑
    if (lotserver_brave_enable && base_rtt > 0) {
        u32 rtt_thresh = base_rtt + (base_rtt * lotserver_brave_rtt_pct) / 100;
        if (rtt_us > rtt_thresh && tp->snd_cwnd > lotserver_min_cwnd) {
            ca->brave_hold_cwnd = tp->snd_cwnd;
            ca->brave_freeze_until = now_jif + msecs_to_jiffies(lotserver_brave_hold_ms);
            brave_active = true;
        }
    }

    if (ca->ss_mode) {
        if (rs && rs->acked_sacked > 0) {
            if (tp->snd_cwnd < LOTSPEED_MAX_U32 - rs->acked_sacked)
                cwnd = tp->snd_cwnd + rs->acked_sacked;
        } else if (tp->snd_cwnd < LOTSPEED_MAX_U32 - 1) {
            cwnd = tp->snd_cwnd + 1;
        }

        if (base_rtt && rtt_us > base_rtt + (base_rtt * lotserver_fast_ss_exit) / 100) {
            ca->ss_mode = false;
            enter_state(sk, FAST_CA);
        }

        tp->snd_cwnd = clamp(cwnd, lotserver_min_cwnd, lotserver_max_cwnd);
        goto out_pacing;
    }

    // FAST 拥塞避免：cwnd = (1-gamma)*cwnd + gamma*(base_rtt/cur_rtt*cwnd + alpha)
    gamma = min_t(u64, lotserver_fast_gamma, FAST_GAMMA_SCALE);
    if (base_rtt > 0 && rtt_us > 0) {
        u64 cwnd_target = ((u64)tp->snd_cwnd * base_rtt) / rtt_us;
        cwnd_target += hist_hint ? hist_alpha : lotserver_fast_alpha;

        if (high_delay_path) {
            // Hybla 风格 RTT 补偿：按 RTT 比例放大，避免高 RTT 吞吐吃亏
            u64 ref = lotserver_hd_ref_us ? lotserver_hd_ref_us : base_rtt;
            u64 rho = ref ? SAFE_DIV64((u64)base_rtt * 100, ref) : 100;
            if (rho < 100) rho = 100;   // 不低于 1x
            if (rho > 400) rho = 400;   // 上限 4x 避免失控
            cwnd_target = min_t(u64, SAFE_DIV64(cwnd_target * rho, 100) + lotserver_hd_alpha_boost, (u64)LOTSPEED_MAX_U32);

            gamma = min_t(u64, gamma + lotserver_hd_gamma_boost, FAST_GAMMA_SCALE);
        }

        cwnd = (u32)SAFE_DIV64((u64)tp->snd_cwnd * (FAST_GAMMA_SCALE - gamma) +
                               cwnd_target * gamma, FAST_GAMMA_SCALE);

        // 正常路径额外 push（勇敢模型），仅在非抖动时
        if (lotserver_brave_enable && !brave_active &&
            rtt_us <= base_rtt + (base_rtt * lotserver_fast_ss_exit) / 100) {
            u64 pushed = (u64)cwnd * (100 + lotserver_brave_push_pct) / 100;
            if (pushed > LOTSPEED_MAX_U32) pushed = LOTSPEED_MAX_U32;
            cwnd = (u32)pushed;
        }
    }

    cwnd = clamp_t(u32, cwnd, lotserver_min_cwnd, lotserver_max_cwnd);
    pipe = tcp_packets_in_flight(tp);
    if (pipe > 0 && cwnd < pipe + 1)
        cwnd = pipe + 1; // RFC3517 风格：确保cwnd不小于在途数据量，避免停顿

    if (brave_active && ca->brave_hold_cwnd) {
        u32 floor = (ca->brave_hold_cwnd * lotserver_brave_floor_pct) / 100;
        if (floor < lotserver_min_cwnd) floor = lotserver_min_cwnd;
        if (cwnd < floor) cwnd = floor;
    }

    tp->snd_cwnd = cwnd;

out_pacing:
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 13, 0)
    if (mss > 0 && rtt_us > 0) {
        u64 rate = (u64)tp->snd_cwnd * mss;
        rate = SAFE_DIV64(rate * USEC_PER_SEC, rtt_us);
        if (high_delay_path) {
            // 高延迟路径给予轻微 pacing 提升，改善管道填充速度
            rate = rate * (100 + lotserver_hd_gamma_boost / 2) / 100;
        }
        if (brave_active && ca->pacing_rate > 0 && rate < ca->pacing_rate)
            rate = ca->pacing_rate; // 冻结期间保持原速
        if (rate > lotserver_rate)
            rate = lotserver_rate;
        ca->pacing_rate = rate;
        sk->sk_pacing_rate = rate;
    }
#endif
}

#ifdef LOTSPEED_OLD_CONG_CONTROL_API
// Linux < 4.13: 旧 API 带 ack/flag 参数
static void lotspeed_cong_control(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs)
{
    lotspeed_adapt_and_control(sk, rs, flag);
}
#elif defined(LOTSPEED_611_CONG_CONTROL_API)
// Linux 6.11+: 新 API 又带回 ack/flag 参数
static void lotspeed_cong_control(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs)
{
    lotspeed_adapt_and_control(sk, rs, flag);
}
#else
// Linux 4.13 - 6.10: 简化 API 无 ack/flag 参数
static void lotspeed_cong_control(struct sock *sk, const struct rate_sample *rs)
{
    lotspeed_adapt_and_control(sk, rs, 0);
}
#endif

// --- SSTHRESH ---
static u32 lotspeed_ssthresh(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct lotspeed *ca = inet_csk_ca(sk);
    u32 new_ssthresh;

    if (lotserver_turbo && !lotserver_safe_mode)
        return TCP_INFINITE_SSTHRESH;

    if (ca)
        ca->ss_mode = false;

    // RFC3517: reduce cwnd to ssthresh on loss; FAST uses beta缩减
    new_ssthresh = (tp->snd_cwnd * lotserver_beta) / LOTSPEED_BETA_SCALE;
    return max_t(u32, new_ssthresh, lotserver_min_cwnd);
}

static void lotspeed_set_state_hook(struct sock *sk, u8 new_state)
{
    struct lotspeed *ca = inet_csk_ca(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    u32 pipe;

    if (!ca)
        return;

    switch (new_state) {
    case TCP_CA_Loss:
        ca->ss_mode = false;
        enter_state(sk, FAST_CA);
        pipe = tcp_packets_in_flight(tp);
        if (!lotserver_turbo || lotserver_safe_mode) {
            tp->snd_cwnd = max_t(u32, tp->snd_ssthresh, pipe + 1);
        }
        break;
    case TCP_CA_Recovery:
    case TCP_CA_Open:
        ca->ss_mode = false;
        enter_state(sk, FAST_CA);
        break;
    default:
        break;
    }
}

static u32 lotspeed_undo_cwnd(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct lotspeed *ca = inet_csk_ca(sk);
    u32 restored = max(tp->snd_cwnd, tp->prior_cwnd);
    if (ca)
        ca->ss_mode = false;
    return min(restored, tp->snd_cwnd_clamp);
}

static void lotspeed_cwnd_event(struct sock *sk, enum tcp_ca_event event)
{
    struct lotspeed *ca = inet_csk_ca(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    if (!ca)
        return;

    switch (event) {
    case CA_EVENT_LOSS:
        ca->ss_mode = false;
        enter_state(sk, FAST_CA);
        if (!lotserver_turbo || lotserver_safe_mode) {
            u32 pipe = tcp_packets_in_flight(tp);
            tp->snd_cwnd = max_t(u32, tp->snd_ssthresh, pipe + 1);
        }
        break;
    case CA_EVENT_TX_START:
    case CA_EVENT_CWND_RESTART:
        ca->ss_mode = true;
        enter_state(sk, FAST_STARTUP);
        break;
    default:
        break;
    }
}

// --- 模块注册 ---
static struct tcp_congestion_ops lotspeed_ops __read_mostly = {
    .name         = "lotspeed",
    .owner        = THIS_MODULE,
    .init         = lotspeed_init,
    .release      = lotspeed_release,
    .cong_control = lotspeed_cong_control,
    .ssthresh     = lotspeed_ssthresh,
    .set_state    = lotspeed_set_state_hook,
    .undo_cwnd    = lotspeed_undo_cwnd,
    .cwnd_event   = lotspeed_cwnd_event,
    .flags        = TCP_CONG_NON_RESTRICTED,
};

static int __init lotspeed_module_init(void)
{
    BUILD_BUG_ON(sizeof(struct lotspeed) > ICSK_CA_PRIV_SIZE);

    if (lotserver_hist_enable) {
        ls_hist_cache = kmem_cache_create("lotspeed_hist",
                                          sizeof(struct ls_hist_entry),
                                          0, SLAB_HWCACHE_ALIGN, NULL);
        if (!ls_hist_cache)
            return -ENOMEM;
        hash_init(ls_hist_table);
    }

    if (tcp_register_congestion_control(&lotspeed_ops))
        return -EINVAL;

    pr_info("lotspeed v5.6 (FAST) loaded. alpha=%u gamma=%u ss_exit=%u\n",
            lotserver_fast_alpha, lotserver_fast_gamma, lotserver_fast_ss_exit);
    pr_info("Struct size: %u bytes (limit: %u)\n",
            (unsigned int)sizeof(struct lotspeed),
            (unsigned int)ICSK_CA_PRIV_SIZE);
    return 0;
}

static void __exit lotspeed_module_exit(void)
{
    struct ls_hist_entry *entry;
    struct hlist_node *tmp;
    int bkt;

    tcp_unregister_congestion_control(&lotspeed_ops);
    if (ls_hist_cache) {
        spin_lock_bh(&ls_hist_lock);
        hash_for_each_safe(ls_hist_table, bkt, tmp, entry, node) {
            hash_del(&entry->node);
            kmem_cache_free(ls_hist_cache, entry);
        }
        spin_unlock_bh(&ls_hist_lock);
        kmem_cache_destroy(ls_hist_cache);
        ls_hist_cache = NULL;
    }

    pr_info("lotspeed v5.6 (FAST) unloaded.\n");
}

module_init(lotspeed_module_init);
module_exit(lotspeed_module_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("uk0");
MODULE_VERSION("5.6");
MODULE_AUTHOR("NeoJ <super@qwq.chat>");
MODULE_DESCRIPTION("LotSpeed Zeta - FAST delay-based congestion control");
MODULE_ALIAS("tcp_lotspeed");

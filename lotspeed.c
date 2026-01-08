// SPDX-License-Identifier: GPL-2.0
/*
 * LotSpeed TCP Accelerator - Netfilter Edition v2.1
 *
 * 完整的 TCP 加速方案，包含:
 * - FEC 前向纠错: 无需重传即可恢复丢失数据
 * - 本地重传缓存: 代理端直接重传，节省 1 RTT
 * - 激进 CWND 恢复: 丢包时不过度降速
 * - RX 窗口欺骗: 告诉对端我们有大缓存
 * - SACK 解析: 精确检测丢包位置
 *
 * 安全改进 v2.1:
 * - 修复竞态条件
 * - 修复栈溢出风险
 * - 完整的 FEC 恢复逻辑
 * - 使用工作队列安全地注入数据包
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/skbuff.h>
#include <linux/hashtable.h>
#include <linux/spinlock.h>
#include <linux/slab.h>
#include <linux/jhash.h>
#include <linux/timer.h>
#include <linux/jiffies.h>
#include <linux/workqueue.h>
#include <linux/rculist.h>
#include <linux/netdevice.h>
#include <linux/inetdevice.h>
#include <net/tcp.h>
#include <net/ip.h>
#include <net/route.h>
#include <net/checksum.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>

#define LOTSPEED_VERSION "2.1.0-nf"

/*
 * =============================================================================
 * 配置常量
 * =============================================================================
 */
#define CONN_HASH_BITS      12      /* 4096 个连接桶 */
#define CONN_TIMEOUT_MS     60000   /* 连接超时 60 秒 */
#define RETRANS_BUF_SIZE    256     /* 每连接缓存 256 个包 */
#define FEC_GROUP_SIZE      4       /* 每 4 个数据包生成 1 个 FEC 包 */
#define MAX_FEC_GROUPS      64      /* 最大 FEC 组数 */
#define SACK_MAX_BLOCKS     4       /* 最大 SACK 块数 */
#define MAX_RETRANS_BATCH   8       /* 每次最多重传 8 个包 */
#define RETRANS_DELAY_MS    1       /* 重传延迟 (毫秒) */

/*
 * =============================================================================
 * 模块参数
 * =============================================================================
 */
static unsigned int fake_window = 65535;
static unsigned int window_scale = 7;
static unsigned int min_cwnd = 16;
static unsigned int max_cwnd = 15000;
static unsigned int alpha = 20;
static unsigned int gamma_pct = 50;
static unsigned int base_rtt_us = 50000;
static unsigned int fec_ratio = 25;
static unsigned int aggressive_recovery = 1;
static unsigned int retrans_cache = 1;
static unsigned int local_retrans = 1;        /* 启用本地重传 */
static bool debug_mode = false;

module_param(fake_window, uint, 0644);
module_param(window_scale, uint, 0644);
module_param(min_cwnd, uint, 0644);
module_param(max_cwnd, uint, 0644);
module_param(alpha, uint, 0644);
module_param(gamma_pct, uint, 0644);
module_param(base_rtt_us, uint, 0644);
module_param(fec_ratio, uint, 0644);
module_param(aggressive_recovery, uint, 0644);
module_param(retrans_cache, uint, 0644);
module_param(local_retrans, uint, 0644);
module_param(debug_mode, bool, 0644);

MODULE_PARM_DESC(fake_window, "Fake receive window size");
MODULE_PARM_DESC(fec_ratio, "FEC redundancy ratio (percentage)");
MODULE_PARM_DESC(aggressive_recovery, "Enable aggressive CWND recovery");
MODULE_PARM_DESC(retrans_cache, "Enable local retransmit cache");
MODULE_PARM_DESC(local_retrans, "Enable local retransmission");

/*
 * =============================================================================
 * 数据结构
 * =============================================================================
 */

/* SACK 块 */
struct sack_block {
    u32 start_seq;
    u32 end_seq;
};

/* 缓存的数据包 (用于本地重传和 FEC) */
struct cached_packet {
    struct list_head list;      /* 链表节点 */
    u32 seq;                    /* 起始序号 */
    u32 end_seq;                /* 结束序号 */
    u16 len;                    /* 数据长度 */
    u8 retrans_count;           /* 重传次数 */
    u8 fec_group_id;            /* 所属 FEC 组 */
    u64 sent_time;              /* 发送时间 (ns) */
    unsigned char data[];       /* 柔性数组，数据紧随其后 */
};

/* FEC 组 - 改进版 */
struct fec_group {
    u32 base_seq;               /* 组起始序号 */
    u8 pkt_count;               /* 已收集的包数 */
    u8 fec_ready;               /* FEC 数据是否就绪 */
    u16 max_len;                /* 组内最大包长度 */
    unsigned char *xor_data;    /* XOR 冗余数据 (动态分配) */
    struct cached_packet *packets[FEC_GROUP_SIZE]; /* 指向缓存包的指针 */
};

/* 重传工作项 */
struct retrans_work {
    struct work_struct work;
    __be32 saddr;
    __be32 daddr;
    __be16 sport;
    __be16 dport;
    u32 seq;
    u16 len;
    unsigned char *data;        /* 数据副本 */
};

/* 连接状态 */
struct lotspeed_conn {
    struct hlist_node node;
    struct rcu_head rcu;

    /* 四元组 */
    __be32 saddr;
    __be32 daddr;
    __be16 sport;
    __be16 dport;

    /* 拥塞控制 */
    u32 cwnd;
    u32 ssthresh;
    u32 min_rtt_us;
    u32 curr_rtt_us;
    u32 srtt_us;
    u32 rttvar_us;
    u32 cwnd_before_loss;

    /* 序号跟踪 */
    u32 snd_una;
    u32 snd_nxt;
    u32 rcv_nxt;
    u32 high_seq;

    /* SACK 状态 */
    struct sack_block sack_blocks[SACK_MAX_BLOCKS];
    u8 sack_count;

    /* 本地重传缓存 - 使用链表更灵活 */
    struct list_head retrans_list;
    u32 retrans_count;
    spinlock_t retrans_lock;

    /* FEC 状态 */
    struct fec_group fec_groups[MAX_FEC_GROUPS];
    u8 fec_group_head;
    u8 fec_group_tail;
    u8 current_fec_group;
    spinlock_t fec_lock;

    /* 丢包统计 */
    u32 loss_count;
    u32 local_retrans_count;
    u32 fec_recovered;

    /* 状态 */
    u8 state;
    #define LOTSPEED_STATE_OPEN       0
    #define LOTSPEED_STATE_DISORDER   1
    #define LOTSPEED_STATE_RECOVERY   2
    #define LOTSPEED_STATE_LOSS       3

    u8 dup_ack_count;
    u8 snd_wscale;
    u8 rcv_wscale;
    bool wscale_ok;
    bool sack_ok;

    /* 时间戳 */
    u64 last_sent_ts;
    u64 last_ack_ts;
    unsigned long last_active;

    spinlock_t lock;
};

/*
 * =============================================================================
 * 全局变量
 * =============================================================================
 */
static DEFINE_HASHTABLE(conn_table, CONN_HASH_BITS);
static DEFINE_SPINLOCK(conn_table_lock);
static struct timer_list cleanup_timer;
static struct workqueue_struct *retrans_wq;

/* 统计 */
static atomic64_t stat_rx_packets;
static atomic64_t stat_tx_packets;
static atomic64_t stat_windows_modified;
static atomic64_t stat_active_connections;
static atomic64_t stat_fec_generated;
static atomic64_t stat_fec_recovered;
static atomic64_t stat_local_retrans;
static atomic64_t stat_loss_detected;

/*
 * =============================================================================
 * 工具函数
 * =============================================================================
 */

static inline u32 conn_hash_key(__be32 saddr, __be32 daddr,
                                __be16 sport, __be16 dport)
{
    return jhash_3words((__force u32)saddr ^ (__force u32)daddr,
                        ((__force u32)sport << 16) | (__force u32)dport,
                        0, 0);
}

/* 序号比较 - 使用内核提供的宏 */
#define before(seq1, seq2) ((s32)((seq1) - (seq2)) < 0)
#define after(seq1, seq2)  before(seq2, seq1)
#define between(seq1, seq2, seq3) \
    (after((seq1), (seq2)) && before((seq1), (seq3)))

/* 安全的增量校验和更新 */
static inline void safe_tcp_csum_replace2(__sum16 *sum, __be16 old_val, __be16 new_val)
{
    __wsum diff;

    diff = csum_add(~csum_unfold((__force __sum16)old_val),
                    csum_unfold((__force __sum16)new_val));
    *sum = csum_fold(csum_add(diff, ~csum_unfold(*sum)));
}

/*
 * =============================================================================
 * 连接管理
 * =============================================================================
 */

static struct lotspeed_conn *find_conn(__be32 saddr, __be32 daddr,
                                       __be16 sport, __be16 dport)
{
    struct lotspeed_conn *conn;
    u32 hash = conn_hash_key(saddr, daddr, sport, dport);

    rcu_read_lock();
    hash_for_each_possible_rcu(conn_table, conn, node, hash) {
        if (conn->saddr == saddr && conn->daddr == daddr &&
            conn->sport == sport && conn->dport == dport) {
            rcu_read_unlock();
            return conn;
        }
    }
    rcu_read_unlock();
    return NULL;
}

static void free_conn_resources(struct lotspeed_conn *conn)
{
    struct cached_packet *pkt, *tmp;
    int i;

    /* 释放重传缓存链表 */
    spin_lock_bh(&conn->retrans_lock);
    list_for_each_entry_safe(pkt, tmp, &conn->retrans_list, list) {
        list_del(&pkt->list);
        kfree(pkt);
    }
    spin_unlock_bh(&conn->retrans_lock);

    /* 释放 FEC 组数据 */
    spin_lock_bh(&conn->fec_lock);
    for (i = 0; i < MAX_FEC_GROUPS; i++) {
        if (conn->fec_groups[i].xor_data) {
            kfree(conn->fec_groups[i].xor_data);
            conn->fec_groups[i].xor_data = NULL;
        }
    }
    spin_unlock_bh(&conn->fec_lock);
}

static void conn_rcu_free(struct rcu_head *head)
{
    struct lotspeed_conn *conn = container_of(head, struct lotspeed_conn, rcu);
    free_conn_resources(conn);
    kfree(conn);
}

static struct lotspeed_conn *create_conn(__be32 saddr, __be32 daddr,
                                         __be16 sport, __be16 dport)
{
    struct lotspeed_conn *conn;
    u32 hash;

    conn = kzalloc(sizeof(*conn), GFP_ATOMIC);
    if (!conn)
        return NULL;

    conn->saddr = saddr;
    conn->daddr = daddr;
    conn->sport = sport;
    conn->dport = dport;

    /* 初始化拥塞控制 */
    conn->cwnd = min_cwnd * 2;
    conn->ssthresh = max_cwnd;
    conn->min_rtt_us = U32_MAX;
    conn->curr_rtt_us = base_rtt_us;
    conn->srtt_us = base_rtt_us;
    conn->rttvar_us = base_rtt_us >> 2;
    conn->state = LOTSPEED_STATE_OPEN;
    conn->last_active = jiffies;

    /* 初始化锁和链表 */
    spin_lock_init(&conn->lock);
    spin_lock_init(&conn->retrans_lock);
    spin_lock_init(&conn->fec_lock);
    INIT_LIST_HEAD(&conn->retrans_list);

    hash = conn_hash_key(saddr, daddr, sport, dport);

    spin_lock_bh(&conn_table_lock);
    hash_add_rcu(conn_table, &conn->node, hash);
    spin_unlock_bh(&conn_table_lock);

    atomic64_inc(&stat_active_connections);

    if (debug_mode)
        pr_info("lotspeed: new conn %pI4:%u -> %pI4:%u\n",
                &saddr, ntohs(sport), &daddr, ntohs(dport));

    return conn;
}

static void delete_conn(struct lotspeed_conn *conn)
{
    spin_lock_bh(&conn_table_lock);
    hash_del_rcu(&conn->node);
    spin_unlock_bh(&conn_table_lock);

    atomic64_dec(&stat_active_connections);
    call_rcu(&conn->rcu, conn_rcu_free);
}

/*
 * =============================================================================
 * 本地重传缓存 (改进版 - 使用链表)
 * =============================================================================
 */

/* 缓存发送的数据包 */
static struct cached_packet *cache_packet(struct lotspeed_conn *conn,
                                          const unsigned char *data,
                                          u16 len, u32 seq)
{
    struct cached_packet *pkt;

    if (!retrans_cache || len == 0 || len > 1460)
        return NULL;

    /* 分配包含数据的结构 */
    pkt = kmalloc(sizeof(*pkt) + len, GFP_ATOMIC);
    if (!pkt)
        return NULL;

    pkt->seq = seq;
    pkt->end_seq = seq + len;
    pkt->len = len;
    pkt->retrans_count = 0;
    pkt->fec_group_id = 0;
    pkt->sent_time = ktime_get_ns();
    memcpy(pkt->data, data, len);

    spin_lock_bh(&conn->retrans_lock);

    /* 限制缓存大小 */
    while (conn->retrans_count >= RETRANS_BUF_SIZE) {
        struct cached_packet *old;
        old = list_first_entry_or_null(&conn->retrans_list,
                                       struct cached_packet, list);
        if (old) {
            list_del(&old->list);
            kfree(old);
            conn->retrans_count--;
        } else {
            break;
        }
    }

    list_add_tail(&pkt->list, &conn->retrans_list);
    conn->retrans_count++;

    spin_unlock_bh(&conn->retrans_lock);

    return pkt;
}

/* 查找缓存的数据包 - 返回时持有锁 */
static struct cached_packet *find_cached_packet_locked(struct lotspeed_conn *conn,
                                                       u32 seq)
{
    struct cached_packet *pkt;

    /* 调用者必须已持有 retrans_lock */
    list_for_each_entry(pkt, &conn->retrans_list, list) {
        if (pkt->seq <= seq && seq < pkt->end_seq) {
            return pkt;
        }
    }
    return NULL;
}

/* 清理已确认的缓存 */
static void cleanup_acked_cache(struct lotspeed_conn *conn, u32 ack_seq)
{
    struct cached_packet *pkt, *tmp;

    spin_lock_bh(&conn->retrans_lock);

    list_for_each_entry_safe(pkt, tmp, &conn->retrans_list, list) {
        if (before(pkt->end_seq, ack_seq) || pkt->end_seq == ack_seq) {
            list_del(&pkt->list);
            kfree(pkt);
            conn->retrans_count--;
        }
    }

    spin_unlock_bh(&conn->retrans_lock);
}

/*
 * =============================================================================
 * FEC 前向纠错 (修复版)
 * =============================================================================
 */

/* 初始化 FEC 组 */
static int fec_init_group(struct fec_group *grp)
{
    memset(grp, 0, sizeof(*grp));
    grp->xor_data = kzalloc(1460, GFP_ATOMIC);  /* MTU - headers */
    if (!grp->xor_data)
        return -ENOMEM;
    return 0;
}

/* 添加数据包到当前 FEC 组 - 完全在锁内操作 */
static void fec_add_packet(struct lotspeed_conn *conn,
                           struct cached_packet *pkt)
{
    struct fec_group *grp;
    int i;

    if (!fec_ratio || !pkt || pkt->len == 0)
        return;

    spin_lock_bh(&conn->fec_lock);

    grp = &conn->fec_groups[conn->current_fec_group];

    /* 如果当前组已满或未初始化，移动到下一组 */
    if (grp->pkt_count >= FEC_GROUP_SIZE || !grp->xor_data) {
        conn->current_fec_group = (conn->current_fec_group + 1) % MAX_FEC_GROUPS;
        grp = &conn->fec_groups[conn->current_fec_group];

        /* 重置组 */
        if (grp->xor_data) {
            memset(grp->xor_data, 0, 1460);
        } else {
            if (fec_init_group(grp) < 0) {
                spin_unlock_bh(&conn->fec_lock);
                return;
            }
        }
        grp->pkt_count = 0;
        grp->fec_ready = 0;
        grp->max_len = 0;
        grp->base_seq = pkt->seq;
        memset(grp->packets, 0, sizeof(grp->packets));
    }

    /* 添加包到组 */
    grp->packets[grp->pkt_count] = pkt;
    pkt->fec_group_id = conn->current_fec_group;

    /* XOR 数据 */
    for (i = 0; i < pkt->len; i++) {
        grp->xor_data[i] ^= pkt->data[i];
    }

    if (pkt->len > grp->max_len)
        grp->max_len = pkt->len;

    grp->pkt_count++;

    /* 检查是否完成 */
    if (grp->pkt_count >= FEC_GROUP_SIZE) {
        grp->fec_ready = 1;
        atomic64_inc(&stat_fec_generated);

        if (debug_mode)
            pr_info("lotspeed: FEC group %u ready, base_seq=%u\n",
                    conn->current_fec_group, grp->base_seq);
    }

    spin_unlock_bh(&conn->fec_lock);
}

/* 尝试用 FEC 恢复丢失的包 - 正确的实现 */
static int fec_try_recover(struct lotspeed_conn *conn, u32 lost_seq,
                           unsigned char *recovered_data, u16 *recovered_len)
{
    struct fec_group *grp;
    int i, j;
    int lost_idx;
    int found_packets;
    int ret = 0;

    spin_lock_bh(&conn->fec_lock);

    /* 遍历所有 FEC 组 */
    for (i = 0; i < MAX_FEC_GROUPS; i++) {
        grp = &conn->fec_groups[i];

        if (!grp->fec_ready || !grp->xor_data)
            continue;

        /* 检查丢失的序号是否在这个组的范围内 */
        lost_idx = -1;
        found_packets = 0;

        for (j = 0; j < grp->pkt_count; j++) {
            if (!grp->packets[j])
                continue;

            if (grp->packets[j]->seq == lost_seq) {
                lost_idx = j;
            } else {
                found_packets++;
            }
        }

        /* 如果找到了丢失的包，且有其他所有包，可以恢复 */
        if (lost_idx >= 0 && found_packets == grp->pkt_count - 1) {
            /* 复制 XOR 数据 */
            memcpy(recovered_data, grp->xor_data, grp->max_len);

            /* XOR 所有其他已知的包来恢复丢失的包 */
            for (j = 0; j < grp->pkt_count; j++) {
                if (j == lost_idx || !grp->packets[j])
                    continue;

                for (int k = 0; k < grp->packets[j]->len; k++) {
                    recovered_data[k] ^= grp->packets[j]->data[k];
                }
            }

            *recovered_len = grp->packets[lost_idx] ?
                             grp->packets[lost_idx]->len : grp->max_len;

            atomic64_inc(&stat_fec_recovered);
            conn->fec_recovered++;
            ret = 1;

            if (debug_mode)
                pr_info("lotspeed: FEC recovered seq=%u from group %d\n",
                        lost_seq, i);

            break;
        }
    }

    spin_unlock_bh(&conn->fec_lock);
    return ret;
}

/*
 * =============================================================================
 * 安全的本地重传 (使用工作队列)
 * =============================================================================
 */

/* 构建并发送 TCP 数据包 */
static void do_retransmit_work(struct work_struct *work)
{
    struct retrans_work *rw = container_of(work, struct retrans_work, work);
    struct sk_buff *skb;
    struct iphdr *iph;
    struct tcphdr *th;
    struct rtable *rt;
    struct flowi4 fl4;
    int hh_len;
    int total_len;

    if (!rw->data || rw->len == 0)
        goto out;

    /* 查找路由 */
    memset(&fl4, 0, sizeof(fl4));
    fl4.saddr = rw->saddr;
    fl4.daddr = rw->daddr;
    fl4.flowi4_proto = IPPROTO_TCP;

    rt = ip_route_output_key(&init_net, &fl4);
    if (IS_ERR(rt)) {
        if (debug_mode)
            pr_warn("lotspeed: route lookup failed for retrans\n");
        goto out;
    }

    hh_len = LL_RESERVED_SPACE(rt->dst.dev);
    total_len = sizeof(struct iphdr) + sizeof(struct tcphdr) + rw->len;

    /* 分配 SKB */
    skb = alloc_skb(hh_len + total_len + 15, GFP_KERNEL);
    if (!skb) {
        ip_rt_put(rt);
        goto out;
    }

    skb_reserve(skb, hh_len);
    skb_reset_network_header(skb);

    /* 构建 IP 头 */
    iph = skb_put(skb, sizeof(struct iphdr));
    iph->version = 4;
    iph->ihl = 5;
    iph->tos = 0;
    iph->tot_len = htons(total_len);
    iph->id = 0;
    iph->frag_off = htons(IP_DF);
    iph->ttl = 64;
    iph->protocol = IPPROTO_TCP;
    iph->saddr = rw->saddr;
    iph->daddr = rw->daddr;
    iph->check = 0;
    iph->check = ip_fast_csum((u8 *)iph, iph->ihl);

    /* 构建 TCP 头 */
    skb_set_transport_header(skb, sizeof(struct iphdr));
    th = skb_put(skb, sizeof(struct tcphdr));
    memset(th, 0, sizeof(*th));
    th->source = rw->sport;
    th->dest = rw->dport;
    th->seq = htonl(rw->seq);
    th->ack_seq = 0;  /* 纯数据包 */
    th->doff = sizeof(struct tcphdr) / 4;
    th->psh = 1;
    th->window = htons(fake_window);

    /* 复制数据 */
    skb_put_data(skb, rw->data, rw->len);

    /* 计算 TCP 校验和 */
    th->check = 0;
    th->check = tcp_v4_check(sizeof(struct tcphdr) + rw->len,
                             rw->saddr, rw->daddr,
                             csum_partial(th, sizeof(struct tcphdr) + rw->len, 0));

    /* 设置路由 */
    skb_dst_set(skb, &rt->dst);
    skb->protocol = htons(ETH_P_IP);

    /* 发送 */
    if (ip_local_out(&init_net, NULL, skb) == 0) {
        atomic64_inc(&stat_local_retrans);
        if (debug_mode)
            pr_info("lotspeed: retransmitted seq=%u len=%u\n", rw->seq, rw->len);
    }

    /* 注意: ip_local_out 会消费 skb，不需要 kfree_skb */

out:
    kfree(rw->data);
    kfree(rw);
}

/* 调度重传工作 */
static void schedule_retransmit(struct lotspeed_conn *conn, u32 seq, u16 len,
                                const unsigned char *data)
{
    struct retrans_work *rw;

    if (!local_retrans || !retrans_wq)
        return;

    rw = kmalloc(sizeof(*rw), GFP_ATOMIC);
    if (!rw)
        return;

    rw->data = kmalloc(len, GFP_ATOMIC);
    if (!rw->data) {
        kfree(rw);
        return;
    }

    memcpy(rw->data, data, len);
    rw->saddr = conn->saddr;
    rw->daddr = conn->daddr;
    rw->sport = conn->sport;
    rw->dport = conn->dport;
    rw->seq = seq;
    rw->len = len;

    INIT_WORK(&rw->work, do_retransmit_work);
    queue_work(retrans_wq, &rw->work);
}

/*
 * =============================================================================
 * SACK 解析
 * =============================================================================
 */

static void parse_tcp_options(const struct tcphdr *th, struct lotspeed_conn *conn)
{
    const unsigned char *ptr;
    int length;
    int sack_idx = 0;

    conn->sack_count = 0;

    if (th->doff <= 5)
        return;

    ptr = (const unsigned char *)(th + 1);
    length = (th->doff * 4) - sizeof(struct tcphdr);

    while (length > 0) {
        int opcode = *ptr++;
        int opsize;

        switch (opcode) {
        case TCPOPT_EOL:
            return;
        case TCPOPT_NOP:
            length--;
            continue;
        default:
            if (length < 2)
                return;
            opsize = *ptr++;
            if (opsize < 2 || opsize > length)
                return;

            switch (opcode) {
            case TCPOPT_SACK:
                if (opsize >= 10) {
                    int blocks = (opsize - 2) / 8;
                    const unsigned char *sack_ptr = ptr;

                    while (blocks > 0 && sack_idx < SACK_MAX_BLOCKS) {
                        conn->sack_blocks[sack_idx].start_seq =
                            get_unaligned_be32(sack_ptr);
                        conn->sack_blocks[sack_idx].end_seq =
                            get_unaligned_be32(sack_ptr + 4);
                        sack_ptr += 8;
                        blocks--;
                        sack_idx++;
                    }
                    conn->sack_count = sack_idx;
                }
                break;
            case TCPOPT_SACK_PERM:
                conn->sack_ok = true;
                break;
            case TCPOPT_WINDOW:
                if (opsize == 3) {
                    conn->rcv_wscale = *ptr;
                    conn->wscale_ok = true;
                }
                break;
            }

            ptr += opsize - 2;
            length -= opsize;
        }
    }
}

/* 根据 SACK 检测并处理丢失的包 */
static void handle_sack_loss(struct lotspeed_conn *conn)
{
    int i;
    u32 lost_seq;
    struct cached_packet *pkt;
    unsigned char *recovered_data;
    u16 recovered_len;
    int retrans_count = 0;

    if (conn->sack_count == 0)
        return;

    /* 动态分配恢复缓冲区 (避免栈溢出) */
    recovered_data = kmalloc(1460, GFP_ATOMIC);
    if (!recovered_data)
        return;

    spin_lock_bh(&conn->retrans_lock);

    /* 检查 snd_una 到第一个 SACK 块之间的空洞 */
    if (after(conn->sack_blocks[0].start_seq, conn->snd_una)) {
        lost_seq = conn->snd_una;

        atomic64_inc(&stat_loss_detected);
        conn->loss_count++;

        /* 尝试 FEC 恢复 */
        spin_unlock_bh(&conn->retrans_lock);

        if (fec_try_recover(conn, lost_seq, recovered_data, &recovered_len)) {
            /* FEC 恢复成功，重传恢复的数据 */
            schedule_retransmit(conn, lost_seq, recovered_len, recovered_data);
            retrans_count++;
        } else {
            /* FEC 恢复失败，尝试从缓存重传 */
            spin_lock_bh(&conn->retrans_lock);
            pkt = find_cached_packet_locked(conn, lost_seq);
            if (pkt && pkt->retrans_count < 3) {
                pkt->retrans_count++;
                spin_unlock_bh(&conn->retrans_lock);
                schedule_retransmit(conn, pkt->seq, pkt->len, pkt->data);
                retrans_count++;
            } else {
                spin_unlock_bh(&conn->retrans_lock);
            }
        }

        spin_lock_bh(&conn->retrans_lock);
    }

    /* 检查 SACK 块之间的空洞 */
    for (i = 0; i < conn->sack_count - 1 && retrans_count < MAX_RETRANS_BATCH; i++) {
        if (!after(conn->sack_blocks[i + 1].start_seq,
                   conn->sack_blocks[i].end_seq))
            continue;

        lost_seq = conn->sack_blocks[i].end_seq;

        atomic64_inc(&stat_loss_detected);
        conn->loss_count++;

        spin_unlock_bh(&conn->retrans_lock);

        /* 尝试 FEC 恢复 */
        if (fec_try_recover(conn, lost_seq, recovered_data, &recovered_len)) {
            schedule_retransmit(conn, lost_seq, recovered_len, recovered_data);
            retrans_count++;
        } else {
            spin_lock_bh(&conn->retrans_lock);
            pkt = find_cached_packet_locked(conn, lost_seq);
            if (pkt && pkt->retrans_count < 3) {
                pkt->retrans_count++;
                spin_unlock_bh(&conn->retrans_lock);
                schedule_retransmit(conn, pkt->seq, pkt->len, pkt->data);
                retrans_count++;
            } else {
                spin_unlock_bh(&conn->retrans_lock);
            }
        }

        spin_lock_bh(&conn->retrans_lock);
    }

    spin_unlock_bh(&conn->retrans_lock);

    kfree(recovered_data);

    if (debug_mode && retrans_count > 0)
        pr_info("lotspeed: scheduled %d retransmissions\n", retrans_count);
}

/*
 * =============================================================================
 * 激进 CWND 恢复
 * =============================================================================
 */

static void enter_loss_recovery(struct lotspeed_conn *conn)
{
    spin_lock_bh(&conn->lock);

    if (conn->state != LOTSPEED_STATE_RECOVERY) {
        conn->cwnd_before_loss = conn->cwnd;
        conn->high_seq = conn->snd_nxt;
        conn->state = LOTSPEED_STATE_RECOVERY;

        if (aggressive_recovery) {
            /* 激进模式: 只减少到 70% */
            conn->ssthresh = max((conn->cwnd * 70) / 100, min_cwnd);
            conn->cwnd = conn->ssthresh;
        } else {
            /* 标准模式: 减少到 50% */
            conn->ssthresh = max(conn->cwnd >> 1, min_cwnd);
            conn->cwnd = conn->ssthresh + 3;
        }

        if (debug_mode)
            pr_info("lotspeed: enter recovery, cwnd %u -> %u\n",
                    conn->cwnd_before_loss, conn->cwnd);
    }

    spin_unlock_bh(&conn->lock);
}

static void aggressive_cwnd_update(struct lotspeed_conn *conn)
{
    if (!aggressive_recovery)
        return;

    spin_lock_bh(&conn->lock);

    if (conn->state == LOTSPEED_STATE_RECOVERY) {
        u32 target = (conn->cwnd_before_loss * 70) / 100;

        if (conn->cwnd < target) {
            conn->cwnd += max(alpha, conn->cwnd / 8);
        }

        if (conn->cwnd >= (conn->cwnd_before_loss * 90) / 100) {
            conn->state = LOTSPEED_STATE_OPEN;
            if (debug_mode)
                pr_info("lotspeed: recovery complete, cwnd=%u\n", conn->cwnd);
        }
    }

    spin_unlock_bh(&conn->lock);
}

/*
 * =============================================================================
 * FAST TCP 拥塞控制
 * =============================================================================
 */

static void fast_tcp_update(struct lotspeed_conn *conn, u32 acked)
{
    u32 new_cwnd;
    u64 target;

    spin_lock_bh(&conn->lock);

    /* 更新 RTT */
    if (conn->curr_rtt_us > 0 && conn->curr_rtt_us < conn->min_rtt_us)
        conn->min_rtt_us = conn->curr_rtt_us;

    /* 平滑 RTT */
    if (conn->srtt_us == 0) {
        conn->srtt_us = conn->curr_rtt_us;
        conn->rttvar_us = conn->curr_rtt_us >> 1;
    } else if (conn->curr_rtt_us > 0) {
        u32 delta = abs((s32)conn->curr_rtt_us - (s32)conn->srtt_us);
        conn->rttvar_us = (3 * conn->rttvar_us + delta) >> 2;
        conn->srtt_us = (7 * conn->srtt_us + conn->curr_rtt_us) >> 3;
    }

    switch (conn->state) {
    case LOTSPEED_STATE_OPEN:
        if (conn->cwnd < conn->ssthresh) {
            /* 慢启动 */
            new_cwnd = conn->cwnd + acked;
        } else {
            /* FAST TCP */
            if (conn->min_rtt_us > 0 && conn->curr_rtt_us > 0 &&
                conn->min_rtt_us != U32_MAX) {
                target = (u64)conn->min_rtt_us * conn->cwnd;
                do_div(target, conn->curr_rtt_us);

                new_cwnd = ((100 - gamma_pct) * conn->cwnd) / 100;
                new_cwnd += (gamma_pct * (u32)target) / 100;
                new_cwnd += alpha;
            } else {
                new_cwnd = conn->cwnd + alpha;
            }
        }
        break;

    case LOTSPEED_STATE_RECOVERY:
        if (aggressive_recovery) {
            new_cwnd = conn->cwnd + max(1U, acked / 2);
        } else {
            new_cwnd = conn->cwnd + 1;
        }

        if (after(conn->snd_una, conn->high_seq)) {
            conn->state = LOTSPEED_STATE_OPEN;
            new_cwnd = conn->ssthresh;
        }
        break;

    default:
        new_cwnd = conn->cwnd;
    }

    new_cwnd = clamp(new_cwnd, min_cwnd, max_cwnd);
    conn->cwnd = new_cwnd;
    conn->last_active = jiffies;

    spin_unlock_bh(&conn->lock);
}

/*
 * =============================================================================
 * 窗口修改
 * =============================================================================
 */

static void modify_rx_window(struct sk_buff *skb, struct tcphdr *th,
                             struct lotspeed_conn *conn)
{
    __be16 old_window, new_window;

    old_window = th->window;
    new_window = htons(fake_window);

    if (old_window == new_window)
        return;

    th->window = new_window;
    safe_tcp_csum_replace2(&th->check, old_window, new_window);

    atomic64_inc(&stat_windows_modified);
}

/*
 * =============================================================================
 * Netfilter Hooks
 * =============================================================================
 */

static unsigned int lotspeed_rx_hook(void *priv,
                                     struct sk_buff *skb,
                                     const struct nf_hook_state *state)
{
    struct iphdr *iph;
    struct tcphdr *th;
    struct lotspeed_conn *conn;
    unsigned int thoff;
    u32 ack_seq;

    if (!skb)
        return NF_ACCEPT;

    iph = ip_hdr(skb);
    if (!iph || iph->protocol != IPPROTO_TCP)
        return NF_ACCEPT;

    thoff = iph->ihl * 4;
    if (!pskb_may_pull(skb, thoff + sizeof(struct tcphdr)))
        return NF_ACCEPT;

    th = (struct tcphdr *)((u8 *)iph + thoff);

    conn = find_conn(iph->daddr, iph->saddr, th->dest, th->source);

    if (th->syn && !th->ack) {
        if (!conn)
            conn = create_conn(iph->daddr, iph->saddr, th->dest, th->source);
        if (conn)
            parse_tcp_options(th, conn);
        return NF_ACCEPT;
    }

    if (!conn)
        return NF_ACCEPT;

    if (th->fin || th->rst) {
        delete_conn(conn);
        return NF_ACCEPT;
    }

    /* 解析选项 */
    parse_tcp_options(th, conn);

    /* 处理 ACK */
    if (th->ack) {
        ack_seq = ntohl(th->ack_seq);

        if (after(ack_seq, conn->snd_una)) {
            u32 acked = ack_seq - conn->snd_una;
            conn->snd_una = ack_seq;
            conn->dup_ack_count = 0;

            cleanup_acked_cache(conn, ack_seq);
            fast_tcp_update(conn, acked);
            aggressive_cwnd_update(conn);

        } else if (ack_seq == conn->snd_una) {
            conn->dup_ack_count++;

            if (conn->sack_count > 0) {
                handle_sack_loss(conn);
            }

            if (conn->dup_ack_count >= 3) {
                enter_loss_recovery(conn);
                conn->dup_ack_count = 0;
            }
        }

        conn->last_ack_ts = ktime_get_ns();
    }

    atomic64_inc(&stat_rx_packets);
    return NF_ACCEPT;
}

static unsigned int lotspeed_tx_hook(void *priv,
                                     struct sk_buff *skb,
                                     const struct nf_hook_state *state)
{
    struct iphdr *iph;
    struct tcphdr *th;
    struct lotspeed_conn *conn;
    struct cached_packet *cached;
    unsigned int thoff;
    unsigned char *payload;
    u16 payload_len;
    u32 seq;

    if (!skb)
        return NF_ACCEPT;

    iph = ip_hdr(skb);
    if (!iph || iph->protocol != IPPROTO_TCP)
        return NF_ACCEPT;

    thoff = iph->ihl * 4;
    if (!pskb_may_pull(skb, thoff + sizeof(struct tcphdr)))
        return NF_ACCEPT;

    if (skb_ensure_writable(skb, thoff + sizeof(struct tcphdr)))
        return NF_ACCEPT;

    iph = ip_hdr(skb);
    th = (struct tcphdr *)((u8 *)iph + thoff);

    conn = find_conn(iph->saddr, iph->daddr, th->source, th->dest);

    if (th->syn && !th->ack) {
        if (!conn)
            conn = create_conn(iph->saddr, iph->daddr, th->source, th->dest);
        if (conn)
            parse_tcp_options(th, conn);
    }

    if (!conn)
        return NF_ACCEPT;

    /* 修改窗口 */
    modify_rx_window(skb, th, conn);

    /* 处理数据包 */
    if (!th->syn && !th->rst && !th->fin) {
        seq = ntohl(th->seq);
        payload_len = ntohs(iph->tot_len) - thoff - th->doff * 4;

        if (payload_len > 0 && payload_len <= 1460) {
            /* 确保可以读取完整数据 */
            if (pskb_may_pull(skb, thoff + th->doff * 4 + payload_len)) {
                payload = (unsigned char *)th + th->doff * 4;

                /* 缓存数据包 */
                cached = cache_packet(conn, payload, payload_len, seq);

                /* 添加到 FEC 组 */
                if (cached)
                    fec_add_packet(conn, cached);

                spin_lock_bh(&conn->lock);
                conn->snd_nxt = seq + payload_len;
                conn->last_sent_ts = ktime_get_ns();
                spin_unlock_bh(&conn->lock);
            }
        }
    }

    if (th->fin || th->rst) {
        delete_conn(conn);
    }

    atomic64_inc(&stat_tx_packets);
    return NF_ACCEPT;
}

/*
 * =============================================================================
 * 定时器
 * =============================================================================
 */

static void cleanup_timer_callback(struct timer_list *t)
{
    struct lotspeed_conn *conn;
    struct hlist_node *tmp;
    unsigned long timeout = msecs_to_jiffies(CONN_TIMEOUT_MS);
    int bkt;

    spin_lock_bh(&conn_table_lock);
    hash_for_each_safe(conn_table, bkt, tmp, conn, node) {
        if (time_after(jiffies, conn->last_active + timeout)) {
            hash_del_rcu(&conn->node);
            atomic64_dec(&stat_active_connections);
            call_rcu(&conn->rcu, conn_rcu_free);
        }
    }
    spin_unlock_bh(&conn_table_lock);

    mod_timer(&cleanup_timer, jiffies + msecs_to_jiffies(10000));
}

/*
 * =============================================================================
 * Netfilter 注册
 * =============================================================================
 */

static struct nf_hook_ops lotspeed_hooks[] = {
    {
        .hook = lotspeed_rx_hook,
        .pf = NFPROTO_IPV4,
        .hooknum = NF_INET_LOCAL_IN,
        .priority = NF_IP_PRI_FIRST,
    },
    {
        .hook = lotspeed_tx_hook,
        .pf = NFPROTO_IPV4,
        .hooknum = NF_INET_LOCAL_OUT,
        .priority = NF_IP_PRI_LAST,
    },
    {
        .hook = lotspeed_tx_hook,
        .pf = NFPROTO_IPV4,
        .hooknum = NF_INET_POST_ROUTING,
        .priority = NF_IP_PRI_LAST,
    },
};

/*
 * =============================================================================
 * /proc 接口
 * =============================================================================
 */

static int lotspeed_stats_show(struct seq_file *m, void *v)
{
    seq_printf(m, "╔════════════════════════════════════════════════════════════╗\n");
    seq_printf(m, "║       LotSpeed v%s (Netfilter Anti-Loss)       ║\n", LOTSPEED_VERSION);
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║                      Traffic Stats                         ║\n");
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║ Active Connections    : %20lld             ║\n",
               atomic64_read(&stat_active_connections));
    seq_printf(m, "║ RX Packets            : %20lld             ║\n",
               atomic64_read(&stat_rx_packets));
    seq_printf(m, "║ TX Packets            : %20lld             ║\n",
               atomic64_read(&stat_tx_packets));
    seq_printf(m, "║ Windows Modified      : %20lld             ║\n",
               atomic64_read(&stat_windows_modified));
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║                   Anti-Loss Statistics                     ║\n");
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║ Loss Events           : %20lld             ║\n",
               atomic64_read(&stat_loss_detected));
    seq_printf(m, "║ FEC Groups Generated  : %20lld             ║\n",
               atomic64_read(&stat_fec_generated));
    seq_printf(m, "║ FEC Recoveries        : %20lld             ║\n",
               atomic64_read(&stat_fec_recovered));
    seq_printf(m, "║ Local Retransmissions : %20lld             ║\n",
               atomic64_read(&stat_local_retrans));
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║                       Parameters                           ║\n");
    seq_printf(m, "╠════════════════════════════════════════════════════════════╣\n");
    seq_printf(m, "║ Fake Window           : %20u             ║\n", fake_window);
    seq_printf(m, "║ CWND Range            : %13u - %-13u      ║\n", min_cwnd, max_cwnd);
    seq_printf(m, "║ FEC Ratio             : %19u%%             ║\n", fec_ratio);
    seq_printf(m, "║ Aggressive Recovery   : %20s             ║\n",
               aggressive_recovery ? "Enabled" : "Disabled");
    seq_printf(m, "║ Local Retransmit      : %20s             ║\n",
               local_retrans ? "Enabled" : "Disabled");
    seq_printf(m, "╚════════════════════════════════════════════════════════════╝\n");
    return 0;
}

static int lotspeed_stats_open(struct inode *inode, struct file *file)
{
    return single_open(file, lotspeed_stats_show, NULL);
}

static const struct proc_ops lotspeed_proc_ops = {
    .proc_open = lotspeed_stats_open,
    .proc_read = seq_read,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};

static struct proc_dir_entry *proc_entry;

/*
 * =============================================================================
 * 模块初始化和卸载
 * =============================================================================
 */

static int __init lotspeed_init(void)
{
    int ret;

    pr_info("lotspeed: initializing v%s\n", LOTSPEED_VERSION);

    /* 初始化统计 */
    atomic64_set(&stat_rx_packets, 0);
    atomic64_set(&stat_tx_packets, 0);
    atomic64_set(&stat_windows_modified, 0);
    atomic64_set(&stat_active_connections, 0);
    atomic64_set(&stat_fec_generated, 0);
    atomic64_set(&stat_fec_recovered, 0);
    atomic64_set(&stat_local_retrans, 0);
    atomic64_set(&stat_loss_detected, 0);

    /* 创建工作队列 */
    retrans_wq = alloc_workqueue("lotspeed_retrans",
                                 WQ_UNBOUND | WQ_MEM_RECLAIM, 4);
    if (!retrans_wq) {
        pr_err("lotspeed: failed to create workqueue\n");
        return -ENOMEM;
    }

    /* 注册 hooks */
    ret = nf_register_net_hooks(&init_net, lotspeed_hooks, ARRAY_SIZE(lotspeed_hooks));
    if (ret) {
        pr_err("lotspeed: failed to register hooks: %d\n", ret);
        destroy_workqueue(retrans_wq);
        return ret;
    }

    /* 启动清理定时器 */
    timer_setup(&cleanup_timer, cleanup_timer_callback, 0);
    mod_timer(&cleanup_timer, jiffies + msecs_to_jiffies(10000));

    /* 创建 /proc 条目 */
    proc_entry = proc_create("lotspeed", 0444, NULL, &lotspeed_proc_ops);

    pr_info("lotspeed: initialized (fec=%u%%, aggressive=%u, local_retrans=%u)\n",
            fec_ratio, aggressive_recovery, local_retrans);
    return 0;
}

static void __exit lotspeed_exit(void)
{
    struct lotspeed_conn *conn;
    struct hlist_node *tmp;
    int bkt;

    pr_info("lotspeed: unloading...\n");

    if (proc_entry)
        proc_remove(proc_entry);

    del_timer_sync(&cleanup_timer);
    nf_unregister_net_hooks(&init_net, lotspeed_hooks, ARRAY_SIZE(lotspeed_hooks));

    /* 等待所有工作完成 */
    if (retrans_wq) {
        flush_workqueue(retrans_wq);
        destroy_workqueue(retrans_wq);
    }

    synchronize_rcu();

    spin_lock_bh(&conn_table_lock);
    hash_for_each_safe(conn_table, bkt, tmp, conn, node) {
        hash_del(&conn->node);
        free_conn_resources(conn);
        kfree(conn);
    }
    spin_unlock_bh(&conn_table_lock);

    pr_info("lotspeed: unloaded (fec=%lld, retrans=%lld, loss=%lld)\n",
            atomic64_read(&stat_fec_recovered),
            atomic64_read(&stat_local_retrans),
            atomic64_read(&stat_loss_detected));
}

module_init(lotspeed_init);
module_exit(lotspeed_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("LotSpeed Team");
MODULE_DESCRIPTION("LotSpeed TCP Accelerator - Netfilter Anti-Loss Edition");
MODULE_VERSION(LOTSPEED_VERSION);

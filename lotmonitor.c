// SPDX-License-Identifier: GPL-2.0
/*
 * LotMonitor - TCP Connection Monitor for MDP Training
 *
 * 用于马尔可夫决策过程(MDP)拥塞控制训练的数据采集模块
 *
 * 采集的状态(State)向量:
 *   - RTT 相关: min_rtt, curr_rtt, srtt, rtt_var, queue_delay
 *   - 丢包相关: loss_rate, dup_ack_count
 *   - 吞吐相关: throughput, packets_sent, packets_acked
 *   - 时序相关: inter_arrival_time, ack_interval
 *
 * 数据输出:
 *   - /proc/lotmonitor/stats    - 全局统计
 *   - /proc/lotmonitor/conns    - 连接列表
 *   - /proc/lotmonitor/samples  - 时序样本 (用于训练)
 *
 * Copyright (C) 2024 LotSpeed Team
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
#include <linux/rculist.h>
#include <linux/ktime.h>
#include <net/tcp.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/circ_buf.h>

#define LOTMON_VERSION		"1.0.0"

/* 配置常量 */
#define CONN_HASH_BITS		12
#define CONN_TIMEOUT_MS		60000

/* 样本环形缓冲区大小 (必须是2的幂) */
#define SAMPLE_BUFFER_SIZE	4096
#define SAMPLE_BUFFER_MASK	(SAMPLE_BUFFER_SIZE - 1)

/* 采样间隔 (毫秒) */
static unsigned int sample_interval_ms = 100;

/* 模块参数 */
static bool debug_mode;

module_param(sample_interval_ms, uint, 0644);
MODULE_PARM_DESC(sample_interval_ms, "Sample interval in milliseconds");

module_param(debug_mode, bool, 0644);
MODULE_PARM_DESC(debug_mode, "Enable debug logging");

/**
 * struct mdp_sample - MDP 训练样本
 *
 * 这是输出给用户空间的状态向量
 */
struct mdp_sample {
	/* 时间戳 */
	u64		timestamp_us;	/* 微秒时间戳 */

	/* 连接标识 */
	__be32		saddr;
	__be32		daddr;
	__be16		sport;
	__be16		dport;

	/* RTT 状态 (微秒) */
	u32		min_rtt_us;	/* 最小 RTT (baseRTT) */
	u32		curr_rtt_us;	/* 当前 RTT */
	u32		srtt_us;	/* 平滑 RTT */
	u32		rtt_var_us;	/* RTT 方差 */
	u32		queue_delay_us;	/* 队列延迟 = curr_rtt - min_rtt */

	/* 丢包状态 */
	u32		loss_count;	/* 累计丢包数 */
	u16		dup_ack_count;	/* 当前重复 ACK 数 */
	u16		loss_rate_ppm;	/* 丢包率 (百万分比) */

	/* 吞吐状态 */
	u32		bytes_sent;	/* 发送字节数 (采样周期内) */
	u32		bytes_acked;	/* 确认字节数 (采样周期内) */
	u32		packets_sent;	/* 发送包数 */
	u32		packets_acked;	/* 确认包数 */
	u32		throughput_kbps;/* 吞吐量 (kbps) */

	/* 时序状态 */
	u32		ack_interval_us;/* ACK 间隔 */
	u32		send_interval_us;/* 发送间隔 */

	/* 窗口状态 */
	u32		inflight;	/* 在途数据量 */
	u16		rwnd;		/* 对方通告的接收窗口 */

	/* 事件标志 */
	u8		event;		/* 事件类型 */
#define EVENT_NONE		0
#define EVENT_ACK		1
#define EVENT_LOSS		2
#define EVENT_TIMEOUT		3
#define EVENT_RTT_SAMPLE	4
};

/**
 * struct lotmon_conn - 连接监控状态
 */
struct lotmon_conn {
	struct hlist_node	node;
	struct rcu_head		rcu;

	/* 连接四元组 */
	__be32			saddr;
	__be32			daddr;
	__be16			sport;
	__be16			dport;

	/* 序号跟踪 */
	u32			snd_una;	/* 最小未确认序号 */
	u32			snd_nxt;	/* 下一个发送序号 */
	u32			rcv_nxt;	/* 期望接收序号 */

	/* RTT 测量 */
	u32			min_rtt_us;	/* 最小 RTT */
	u32			curr_rtt_us;	/* 当前 RTT */
	u32			srtt_us;	/* 平滑 RTT (EWMA) */
	u32			rtt_var_us;	/* RTT 方差 */
	ktime_t			rtt_stamp;	/* RTT 采样时间戳 */
	u32			rtt_seq;	/* RTT 采样序号 */

	/* 丢包统计 */
	u32			loss_count;	/* 累计丢包 */
	u32			total_packets;	/* 总包数 */
	u8			dup_ack_count;	/* 重复 ACK 计数 */

	/* 吞吐量测量 */
	u64			bytes_sent;	/* 总发送字节 */
	u64			bytes_acked;	/* 总确认字节 */
	u32			packets_sent;	/* 总发送包数 */
	u32			packets_acked;	/* 总确认包数 */

	/* 采样周期内的增量 */
	u32			delta_bytes_sent;
	u32			delta_bytes_acked;
	u32			delta_packets_sent;
	u32			delta_packets_acked;

	/* 时序测量 */
	ktime_t			last_send_time;	/* 上次发送时间 */
	ktime_t			last_ack_time;	/* 上次 ACK 时间 */
	u32			send_interval_us;
	u32			ack_interval_us;

	/* 窗口 */
	u16			peer_rwnd;	/* 对方通告窗口 */

	/* 状态 */
	unsigned long		last_active;
	unsigned long		last_sample;	/* 上次采样时间 */
	spinlock_t		lock;
};

/* 样本环形缓冲区 */
struct sample_buffer {
	struct mdp_sample	samples[SAMPLE_BUFFER_SIZE];
	unsigned int		head;	/* 写入位置 */
	unsigned int		tail;	/* 读取位置 */
	spinlock_t		lock;
};

/* 全局变量 */
static DEFINE_HASHTABLE(conn_table, CONN_HASH_BITS);
static DEFINE_SPINLOCK(conn_table_lock);
static struct timer_list cleanup_timer;
static struct timer_list sample_timer;

/* 样本缓冲区 */
static struct sample_buffer sample_buf;

/* 统计计数器 */
static atomic64_t stat_rx_packets;
static atomic64_t stat_tx_packets;
static atomic64_t stat_active_conns;
static atomic64_t stat_total_samples;
static atomic64_t stat_dropped_samples;	/* 缓冲区满时丢弃的样本 */

/* 序号比较宏 */
#define seq_before(a, b)	((s32)((a) - (b)) < 0)
#define seq_after(a, b)		seq_before(b, a)

/**
 * conn_hash_key - 计算连接哈希键
 */
static inline u32 conn_hash_key(__be32 saddr, __be32 daddr,
				__be16 sport, __be16 dport)
{
	return jhash_3words((__force u32)saddr ^ (__force u32)daddr,
			    ((__force u32)sport << 16) | (__force u32)dport,
			    0, 0);
}

/**
 * find_conn - 查找连接
 */
static struct lotmon_conn *find_conn(__be32 saddr, __be32 daddr,
				     __be16 sport, __be16 dport)
{
	struct lotmon_conn *conn;
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

/**
 * conn_rcu_free - RCU 回调释放连接
 */
static void conn_rcu_free(struct rcu_head *head)
{
	struct lotmon_conn *conn;

	conn = container_of(head, struct lotmon_conn, rcu);
	kfree(conn);
}

/**
 * create_conn - 创建新连接
 */
static struct lotmon_conn *create_conn(__be32 saddr, __be32 daddr,
				       __be16 sport, __be16 dport)
{
	struct lotmon_conn *conn;
	u32 hash;

	conn = kzalloc(sizeof(*conn), GFP_ATOMIC);
	if (!conn)
		return NULL;

	conn->saddr = saddr;
	conn->daddr = daddr;
	conn->sport = sport;
	conn->dport = dport;

	/* RTT 初始化 */
	conn->min_rtt_us = U32_MAX;
	conn->curr_rtt_us = 0;
	conn->srtt_us = 0;
	conn->rtt_var_us = 0;
	conn->rtt_stamp = 0;

	conn->last_active = jiffies;
	conn->last_sample = jiffies;
	conn->last_send_time = ktime_get();
	conn->last_ack_time = ktime_get();

	spin_lock_init(&conn->lock);

	hash = conn_hash_key(saddr, daddr, sport, dport);

	spin_lock_bh(&conn_table_lock);
	hash_add_rcu(conn_table, &conn->node, hash);
	spin_unlock_bh(&conn_table_lock);

	atomic64_inc(&stat_active_conns);

	if (debug_mode)
		pr_info("lotmonitor: new conn %pI4:%u -> %pI4:%u\n",
			&saddr, ntohs(sport), &daddr, ntohs(dport));

	return conn;
}

/**
 * delete_conn - 删除连接
 */
static void delete_conn(struct lotmon_conn *conn)
{
	spin_lock_bh(&conn_table_lock);
	hash_del_rcu(&conn->node);
	spin_unlock_bh(&conn_table_lock);

	atomic64_dec(&stat_active_conns);
	call_rcu(&conn->rcu, conn_rcu_free);
}

/**
 * push_sample - 将样本推入环形缓冲区
 */
static void push_sample(struct mdp_sample *sample)
{
	unsigned int head, tail, next;
	unsigned long flags;

	spin_lock_irqsave(&sample_buf.lock, flags);

	head = sample_buf.head;
	tail = sample_buf.tail;
	next = (head + 1) & SAMPLE_BUFFER_MASK;

	if (next == tail) {
		/* 缓冲区满，丢弃最旧的样本 */
		sample_buf.tail = (tail + 1) & SAMPLE_BUFFER_MASK;
		atomic64_inc(&stat_dropped_samples);
	}

	memcpy(&sample_buf.samples[head], sample, sizeof(*sample));
	sample_buf.head = next;

	spin_unlock_irqrestore(&sample_buf.lock, flags);

	atomic64_inc(&stat_total_samples);
}

/**
 * update_rtt - 更新 RTT 测量
 */
static void update_rtt(struct lotmon_conn *conn, u32 rtt_us)
{
	u32 delta;

	/* 更新最小 RTT */
	if (rtt_us < conn->min_rtt_us)
		conn->min_rtt_us = rtt_us;

	/* 更新当前 RTT */
	conn->curr_rtt_us = rtt_us;

	/* 更新平滑 RTT: srtt = 7/8 * srtt + 1/8 * rtt */
	if (conn->srtt_us == 0) {
		conn->srtt_us = rtt_us;
		conn->rtt_var_us = rtt_us / 2;
	} else {
		/* 计算 RTT 方差 */
		if (rtt_us > conn->srtt_us)
			delta = rtt_us - conn->srtt_us;
		else
			delta = conn->srtt_us - rtt_us;

		conn->rtt_var_us = (conn->rtt_var_us * 3 + delta) / 4;
		conn->srtt_us = (conn->srtt_us * 7 + rtt_us) / 8;
	}
}

/**
 * collect_sample - 从连接收集 MDP 样本
 */
static void collect_sample(struct lotmon_conn *conn, u8 event)
{
	struct mdp_sample sample;
	u64 now_us = ktime_to_us(ktime_get());
	u32 elapsed_ms;

	memset(&sample, 0, sizeof(sample));

	/* 时间戳 */
	sample.timestamp_us = now_us;

	/* 连接标识 */
	sample.saddr = conn->saddr;
	sample.daddr = conn->daddr;
	sample.sport = conn->sport;
	sample.dport = conn->dport;

	/* RTT 状态 */
	sample.min_rtt_us = (conn->min_rtt_us == U32_MAX) ? 0 : conn->min_rtt_us;
	sample.curr_rtt_us = conn->curr_rtt_us;
	sample.srtt_us = conn->srtt_us;
	sample.rtt_var_us = conn->rtt_var_us;

	/* 队列延迟 = 当前RTT - 最小RTT */
	if (conn->min_rtt_us != U32_MAX && conn->curr_rtt_us > conn->min_rtt_us)
		sample.queue_delay_us = conn->curr_rtt_us - conn->min_rtt_us;
	else
		sample.queue_delay_us = 0;

	/* 丢包状态 */
	sample.loss_count = conn->loss_count;
	sample.dup_ack_count = conn->dup_ack_count;

	/* 丢包率 (百万分比) */
	if (conn->total_packets > 0)
		sample.loss_rate_ppm = (u32)div64_u64(
			(u64)conn->loss_count * 1000000, conn->total_packets);

	/* 吞吐状态 */
	sample.bytes_sent = conn->delta_bytes_sent;
	sample.bytes_acked = conn->delta_bytes_acked;
	sample.packets_sent = conn->delta_packets_sent;
	sample.packets_acked = conn->delta_packets_acked;

	/* 计算吞吐量 (kbps) */
	elapsed_ms = jiffies_to_msecs(jiffies - conn->last_sample);
	if (elapsed_ms > 0 && conn->delta_bytes_acked > 0) {
		sample.throughput_kbps = (conn->delta_bytes_acked * 8) / elapsed_ms;
	}

	/* 时序状态 */
	sample.ack_interval_us = conn->ack_interval_us;
	sample.send_interval_us = conn->send_interval_us;

	/* 窗口状态 */
	sample.inflight = conn->snd_nxt - conn->snd_una;
	sample.rwnd = conn->peer_rwnd;

	/* 事件 */
	sample.event = event;

	/* 重置增量计数器 */
	conn->delta_bytes_sent = 0;
	conn->delta_bytes_acked = 0;
	conn->delta_packets_sent = 0;
	conn->delta_packets_acked = 0;
	conn->last_sample = jiffies;

	/* 推入缓冲区 */
	push_sample(&sample);
}

/**
 * detect_loss - 检测丢包
 */
static void detect_loss(struct lotmon_conn *conn)
{
	spin_lock_bh(&conn->lock);
	conn->loss_count++;
	conn->dup_ack_count = 0;
	spin_unlock_bh(&conn->lock);

	/* 收集丢包事件样本 */
	collect_sample(conn, EVENT_LOSS);
}

/*
 * =============================================================================
 * Netfilter Hooks - 纯监控
 * =============================================================================
 */

/**
 * lotmon_in_hook - LOCAL_IN hook (监控入站)
 */
static unsigned int lotmon_in_hook(void *priv, struct sk_buff *skb,
				   const struct nf_hook_state *state)
{
	struct iphdr *iph;
	struct tcphdr *th;
	struct lotmon_conn *conn;
	unsigned int thoff;
	u32 ack_seq;
	ktime_t now;

	if (!skb)
		return NF_ACCEPT;

	iph = ip_hdr(skb);
	if (!iph || iph->protocol != IPPROTO_TCP)
		return NF_ACCEPT;

	thoff = iph->ihl * 4;
	if (!pskb_may_pull(skb, thoff + sizeof(struct tcphdr)))
		return NF_ACCEPT;

	th = (struct tcphdr *)((u8 *)iph + thoff);
	now = ktime_get();

	/* 查找连接 (入站包: 目的是本机) */
	conn = find_conn(iph->daddr, iph->saddr, th->dest, th->source);

	/* SYN 包 - 创建连接 */
	if (th->syn && !th->ack) {
		if (!conn)
			create_conn(iph->daddr, iph->saddr,
				    th->dest, th->source);
		goto out;
	}

	if (!conn)
		goto out;

	/* FIN/RST - 删除连接 */
	if (th->fin || th->rst) {
		delete_conn(conn);
		goto out;
	}

	/* 处理 ACK */
	if (th->ack) {
		ack_seq = ntohl(th->ack_seq);

		spin_lock_bh(&conn->lock);

		/* 记录对方的接收窗口 */
		conn->peer_rwnd = ntohs(th->window);

		if (seq_after(ack_seq, conn->snd_una)) {
			u32 acked = ack_seq - conn->snd_una;

			/* RTT 测量 */
			if (conn->rtt_stamp != 0 &&
			    seq_after(ack_seq, conn->rtt_seq)) {
				s64 rtt_ns = ktime_to_ns(ktime_sub(now, conn->rtt_stamp));
				u32 rtt_us = (u32)(rtt_ns / 1000);

				if (rtt_us > 0 && rtt_us < 30000000)
					update_rtt(conn, rtt_us);

				conn->rtt_stamp = 0;
			}

			/* ACK 间隔测量 */
			conn->ack_interval_us = (u32)ktime_to_us(
				ktime_sub(now, conn->last_ack_time));
			conn->last_ack_time = now;

			/* 更新统计 */
			conn->snd_una = ack_seq;
			conn->bytes_acked += acked;
			conn->delta_bytes_acked += acked;
			conn->packets_acked++;
			conn->delta_packets_acked++;
			conn->dup_ack_count = 0;

			spin_unlock_bh(&conn->lock);

			/* 定期采样 */
			if (time_after(jiffies, conn->last_sample +
				       msecs_to_jiffies(sample_interval_ms))) {
				collect_sample(conn, EVENT_ACK);
			}

		} else if (ack_seq == conn->snd_una) {
			/* 重复 ACK */
			conn->dup_ack_count++;
			spin_unlock_bh(&conn->lock);

			if (conn->dup_ack_count >= 3) {
				detect_loss(conn);
			}
		} else {
			spin_unlock_bh(&conn->lock);
		}

		conn->last_active = jiffies;
	}

out:
	atomic64_inc(&stat_rx_packets);
	return NF_ACCEPT;
}

/**
 * lotmon_out_hook - LOCAL_OUT hook (监控出站)
 */
static unsigned int lotmon_out_hook(void *priv, struct sk_buff *skb,
				    const struct nf_hook_state *state)
{
	struct iphdr *iph;
	struct tcphdr *th;
	struct lotmon_conn *conn;
	unsigned int thoff;
	u32 seq;
	u16 payload_len;
	ktime_t now;

	if (!skb)
		return NF_ACCEPT;

	iph = ip_hdr(skb);
	if (!iph || iph->protocol != IPPROTO_TCP)
		return NF_ACCEPT;

	thoff = iph->ihl * 4;
	if (!pskb_may_pull(skb, thoff + sizeof(struct tcphdr)))
		return NF_ACCEPT;

	th = (struct tcphdr *)((u8 *)iph + thoff);
	payload_len = ntohs(iph->tot_len) - thoff - th->doff * 4;
	now = ktime_get();

	/* 查找连接 (出站包: 源是本机) */
	conn = find_conn(iph->saddr, iph->daddr, th->source, th->dest);

	/* SYN 包 - 创建连接 */
	if (th->syn && !th->ack) {
		if (!conn)
			create_conn(iph->saddr, iph->daddr,
				    th->source, th->dest);
		goto out;
	}

	if (!conn)
		goto out;

	/* FIN/RST - 删除连接 */
	if (th->fin || th->rst) {
		delete_conn(conn);
		goto out;
	}

	/* 更新发送序号 */
	if (!th->syn && payload_len > 0) {
		seq = ntohl(th->seq);

		spin_lock_bh(&conn->lock);

		if (seq_after(seq + payload_len, conn->snd_nxt))
			conn->snd_nxt = seq + payload_len;

		/* RTT 采样 */
		if (conn->rtt_stamp == 0) {
			conn->rtt_stamp = now;
			conn->rtt_seq = seq + payload_len;
		}

		/* 发送间隔测量 */
		conn->send_interval_us = (u32)ktime_to_us(
			ktime_sub(now, conn->last_send_time));
		conn->last_send_time = now;

		/* 更新统计 */
		conn->bytes_sent += payload_len;
		conn->delta_bytes_sent += payload_len;
		conn->packets_sent++;
		conn->delta_packets_sent++;
		conn->total_packets++;

		conn->last_active = jiffies;

		spin_unlock_bh(&conn->lock);
	}

out:
	atomic64_inc(&stat_tx_packets);
	return NF_ACCEPT;
}

/**
 * lotmon_prerouting_hook - PRE_ROUTING hook (透传)
 */
static unsigned int lotmon_prerouting_hook(void *priv, struct sk_buff *skb,
					   const struct nf_hook_state *state)
{
	return NF_ACCEPT;
}

/**
 * lotmon_forward_hook - FORWARD hook (透传)
 */
static unsigned int lotmon_forward_hook(void *priv, struct sk_buff *skb,
					const struct nf_hook_state *state)
{
	return NF_ACCEPT;
}

/**
 * lotmon_postrouting_hook - POST_ROUTING hook (透传)
 */
static unsigned int lotmon_postrouting_hook(void *priv, struct sk_buff *skb,
					    const struct nf_hook_state *state)
{
	return NF_ACCEPT;
}

/**
 * cleanup_timer_fn - 清理超时连接
 */
static void cleanup_timer_fn(struct timer_list *t)
{
	struct lotmon_conn *conn;
	struct hlist_node *tmp;
	unsigned long timeout = msecs_to_jiffies(CONN_TIMEOUT_MS);
	int bkt;

	spin_lock_bh(&conn_table_lock);
	hash_for_each_safe(conn_table, bkt, tmp, conn, node) {
		if (time_after(jiffies, conn->last_active + timeout)) {
			hash_del_rcu(&conn->node);
			atomic64_dec(&stat_active_conns);
			call_rcu(&conn->rcu, conn_rcu_free);
		}
	}
	spin_unlock_bh(&conn_table_lock);

	mod_timer(&cleanup_timer, jiffies + msecs_to_jiffies(10000));
}

/**
 * sample_timer_fn - 定期采样所有连接
 */
static void sample_timer_fn(struct timer_list *t)
{
	struct lotmon_conn *conn;
	int bkt;

	rcu_read_lock();
	hash_for_each_rcu(conn_table, bkt, conn, node) {
		if (time_after(jiffies, conn->last_sample +
			       msecs_to_jiffies(sample_interval_ms))) {
			collect_sample(conn, EVENT_NONE);
		}
	}
	rcu_read_unlock();

	mod_timer(&sample_timer, jiffies + msecs_to_jiffies(sample_interval_ms));
}

/* Netfilter hooks */
static struct nf_hook_ops lotmon_hooks[] = {
	{
		.hook		= lotmon_prerouting_hook,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_PRE_ROUTING,
		.priority	= NF_IP_PRI_LAST,
	},
	{
		.hook		= lotmon_in_hook,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_LOCAL_IN,
		.priority	= NF_IP_PRI_LAST,
	},
	{
		.hook		= lotmon_forward_hook,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_FORWARD,
		.priority	= NF_IP_PRI_LAST,
	},
	{
		.hook		= lotmon_out_hook,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_LOCAL_OUT,
		.priority	= NF_IP_PRI_LAST,
	},
	{
		.hook		= lotmon_postrouting_hook,
		.pf		= NFPROTO_IPV4,
		.hooknum	= NF_INET_POST_ROUTING,
		.priority	= NF_IP_PRI_LAST,
	},
};

/*
 * =============================================================================
 * /proc 接口
 * =============================================================================
 */

/* /proc/lotmonitor/stats - 全局统计 */
static int stats_show(struct seq_file *m, void *v)
{
	seq_printf(m, "LotMonitor v%s\n", LOTMON_VERSION);
	seq_puts(m, "=====================================\n");
	seq_printf(m, "Active Connections: %lld\n",
		   atomic64_read(&stat_active_conns));
	seq_printf(m, "RX Packets:         %lld\n",
		   atomic64_read(&stat_rx_packets));
	seq_printf(m, "TX Packets:         %lld\n",
		   atomic64_read(&stat_tx_packets));
	seq_puts(m, "-------------------------------------\n");
	seq_printf(m, "Total Samples:      %lld\n",
		   atomic64_read(&stat_total_samples));
	seq_printf(m, "Dropped Samples:    %lld\n",
		   atomic64_read(&stat_dropped_samples));
	seq_printf(m, "Sample Interval:    %u ms\n", sample_interval_ms);
	seq_printf(m, "Buffer Size:        %d\n", SAMPLE_BUFFER_SIZE);
	seq_printf(m, "Buffer Used:        %u\n",
		   (sample_buf.head - sample_buf.tail) & SAMPLE_BUFFER_MASK);

	return 0;
}

static int stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, stats_show, NULL);
}

static const struct proc_ops stats_proc_ops = {
	.proc_open	= stats_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* /proc/lotmonitor/conns - 连接列表 */
static int conns_show(struct seq_file *m, void *v)
{
	struct lotmon_conn *conn;
	int bkt;

	seq_puts(m, "# saddr,daddr,sport,dport,min_rtt,curr_rtt,srtt,loss,pkts,bytes\n");

	rcu_read_lock();
	hash_for_each_rcu(conn_table, bkt, conn, node) {
		seq_printf(m, "%pI4,%pI4,%u,%u,%u,%u,%u,%u,%u,%llu\n",
			   &conn->saddr, &conn->daddr,
			   ntohs(conn->sport), ntohs(conn->dport),
			   conn->min_rtt_us == U32_MAX ? 0 : conn->min_rtt_us,
			   conn->curr_rtt_us,
			   conn->srtt_us,
			   conn->loss_count,
			   conn->packets_sent,
			   conn->bytes_sent);
	}
	rcu_read_unlock();

	return 0;
}

static int conns_open(struct inode *inode, struct file *file)
{
	return single_open(file, conns_show, NULL);
}

static const struct proc_ops conns_proc_ops = {
	.proc_open	= conns_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* /proc/lotmonitor/samples - MDP 训练样本 (CSV 格式) */
static int samples_show(struct seq_file *m, void *v)
{
	struct mdp_sample sample;
	unsigned int head, tail;
	unsigned long flags;
	int count = 0;

	/* CSV 头 */
	seq_puts(m, "timestamp_us,saddr,daddr,sport,dport,");
	seq_puts(m, "min_rtt,curr_rtt,srtt,rtt_var,queue_delay,");
	seq_puts(m, "loss_count,dup_ack,loss_rate_ppm,");
	seq_puts(m, "bytes_sent,bytes_acked,pkts_sent,pkts_acked,throughput_kbps,");
	seq_puts(m, "ack_interval,send_interval,inflight,rwnd,event\n");

	spin_lock_irqsave(&sample_buf.lock, flags);
	head = sample_buf.head;
	tail = sample_buf.tail;

	while (tail != head && count < 1000) {
		memcpy(&sample, &sample_buf.samples[tail], sizeof(sample));
		tail = (tail + 1) & SAMPLE_BUFFER_MASK;
		count++;

		spin_unlock_irqrestore(&sample_buf.lock, flags);

		seq_printf(m, "%llu,%pI4,%pI4,%u,%u,",
			   sample.timestamp_us,
			   &sample.saddr, &sample.daddr,
			   ntohs(sample.sport), ntohs(sample.dport));
		seq_printf(m, "%u,%u,%u,%u,%u,",
			   sample.min_rtt_us, sample.curr_rtt_us,
			   sample.srtt_us, sample.rtt_var_us,
			   sample.queue_delay_us);
		seq_printf(m, "%u,%u,%u,",
			   sample.loss_count, sample.dup_ack_count,
			   sample.loss_rate_ppm);
		seq_printf(m, "%u,%u,%u,%u,%u,",
			   sample.bytes_sent, sample.bytes_acked,
			   sample.packets_sent, sample.packets_acked,
			   sample.throughput_kbps);
		seq_printf(m, "%u,%u,%u,%u,%u\n",
			   sample.ack_interval_us, sample.send_interval_us,
			   sample.inflight, sample.rwnd, sample.event);

		spin_lock_irqsave(&sample_buf.lock, flags);
	}

	/* 更新 tail 以移除已读取的样本 */
	sample_buf.tail = tail;
	spin_unlock_irqrestore(&sample_buf.lock, flags);

	return 0;
}

static int samples_open(struct inode *inode, struct file *file)
{
	return single_open(file, samples_show, NULL);
}

static const struct proc_ops samples_proc_ops = {
	.proc_open	= samples_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

static struct proc_dir_entry *proc_dir;

static int __init lotmon_init(void)
{
	int ret;

	pr_info("lotmonitor: initializing v%s\n", LOTMON_VERSION);
	pr_info("lotmonitor: sample_interval=%u ms, buffer_size=%d\n",
		sample_interval_ms, SAMPLE_BUFFER_SIZE);

	/* 初始化样本缓冲区 */
	spin_lock_init(&sample_buf.lock);
	sample_buf.head = 0;
	sample_buf.tail = 0;

	/* 初始化统计 */
	atomic64_set(&stat_rx_packets, 0);
	atomic64_set(&stat_tx_packets, 0);
	atomic64_set(&stat_active_conns, 0);
	atomic64_set(&stat_total_samples, 0);
	atomic64_set(&stat_dropped_samples, 0);

	/* 注册 Netfilter hooks */
	ret = nf_register_net_hooks(&init_net, lotmon_hooks,
				    ARRAY_SIZE(lotmon_hooks));
	if (ret) {
		pr_err("lotmonitor: failed to register hooks: %d\n", ret);
		return ret;
	}

	/* 启动定时器 */
	timer_setup(&cleanup_timer, cleanup_timer_fn, 0);
	mod_timer(&cleanup_timer, jiffies + msecs_to_jiffies(10000));

	timer_setup(&sample_timer, sample_timer_fn, 0);
	mod_timer(&sample_timer, jiffies + msecs_to_jiffies(sample_interval_ms));

	/* 创建 /proc/lotmonitor 目录 */
	proc_dir = proc_mkdir("lotmonitor", NULL);
	if (proc_dir) {
		proc_create("stats", 0444, proc_dir, &stats_proc_ops);
		proc_create("conns", 0444, proc_dir, &conns_proc_ops);
		proc_create("samples", 0444, proc_dir, &samples_proc_ops);
	}

	pr_info("lotmonitor: initialized successfully\n");
	return 0;
}

static void __exit lotmon_exit(void)
{
	struct lotmon_conn *conn;
	struct hlist_node *tmp;
	int bkt;

	pr_info("lotmonitor: unloading...\n");

	/* 移除 /proc 接口 */
	if (proc_dir) {
		remove_proc_entry("samples", proc_dir);
		remove_proc_entry("conns", proc_dir);
		remove_proc_entry("stats", proc_dir);
		remove_proc_entry("lotmonitor", NULL);
	}

	/* 停止定时器 */
	del_timer_sync(&cleanup_timer);
	del_timer_sync(&sample_timer);

	/* 注销 hooks */
	nf_unregister_net_hooks(&init_net, lotmon_hooks,
				ARRAY_SIZE(lotmon_hooks));

	synchronize_rcu();

	/* 清理连接 */
	spin_lock_bh(&conn_table_lock);
	hash_for_each_safe(conn_table, bkt, tmp, conn, node) {
		hash_del(&conn->node);
		kfree(conn);
	}
	spin_unlock_bh(&conn_table_lock);

	pr_info("lotmonitor: unloaded (samples=%lld, dropped=%lld)\n",
		atomic64_read(&stat_total_samples),
		atomic64_read(&stat_dropped_samples));
}

module_init(lotmon_init);
module_exit(lotmon_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("LotSpeed Team");
MODULE_DESCRIPTION("TCP Connection Monitor for MDP Training");
MODULE_VERSION(LOTMON_VERSION);

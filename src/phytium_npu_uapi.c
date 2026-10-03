// SPDX-License-Identifier: GPL-2.0
/* Platform NPU driver for Phytium NPU controller
 *
 * Copyright (C) 2023 Phytium Technology Co., Ltd.
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/device.h>
#include <linux/miscdevice.h>
#include <linux/poll.h>
#include <linux/fs.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/anon_inodes.h>
#include <linux/dma-mapping.h>
#include <linux/crc32.h>
#include <linux/pm_runtime.h>
#include <linux/ktime.h>
#include "include/phytium_npu.h"
#include "include/phytium_npu_uapi.h"
#include "include/phytium_npu_mmu.h"
#ifdef PHYTIUM_NPU_PLATFORM
#include "include/phytium_npu_leopard_reg.h"
#else
#include "include/phytium_npu_reg.h"
#endif

/* VHA emulation mode: 1 = simulate completion (no HW), 0 = real NPU execution */
static int vha_sim_mode = 1;
module_param(vha_sim_mode, int, 0644);
MODULE_PARM_DESC(vha_sim_mode, "VHA: 1=simulate (default), 0=real NPU");

static int vha_use_repeat = 1;
module_param(vha_use_repeat, int, 0644);
MODULE_PARM_DESC(vha_use_repeat, "VHA: 1=is_use_repeat TRUE (default), 0=A/B off");

static int vha_settle_ms = 50;
module_param(vha_settle_ms, int, 0644);
MODULE_PARM_DESC(vha_settle_ms, "VHA: wait until write-back CRC stable N ms (0=off)");
/* Hermes 2026-09-27: 实测同进程第 2 次起每次多等 ~40.6s（提交前被卡），
 * 定位用：默认只在**首次**提交做 resume + reset，之后跳过。
 */
static int vha_reset_each_run;
module_param(vha_reset_each_run, int, 0644);
MODULE_PARM_DESC(vha_reset_each_run, "VHA: 1=每次提交都做 resume+reset (default 0=only first)");
static int vha_did_first_reset;

/* override command-stream buffer page (-1 = use descriptor t) */
static int vha_cmd_page = -1;
module_param(vha_cmd_page, int, 0644);
MODULE_PARM_DESC(vha_cmd_page, "VHA: override command buffer page index");

/* T3 killer experiment: if >0, force ADDR bank0+8 (input) to this IOVA */
static unsigned long vha_bad_addr;
module_param(vha_bad_addr, ulong, 0644);
MODULE_PARM_DESC(vha_bad_addr, "VHA: override ADDR0+8 with this (bad) IOVA");

/* verbose diagnostics (default off) */
static int vha_debug;
module_param(vha_debug, int, 0644);
MODULE_PARM_DESC(vha_debug, "VHA: verbose diagnostics");

/* Hermes 2026-09-27 (item 3, A/B only, DEFAULT OFF):
 * Delivery fixup for models whose NOT-folded intermediate output is
 * written by the engine but never mmap'd by the library -- the library's
 * host-side __copy_N then has no source and the app's buffer stays 0
 * (case: yunet conf: engine writes page93=INT-3, app reads page47=dnn_buf_).
 * With vha_int_fixup=1 the bridge copies such a buffer into the
 * same-size app-visible buffer right after completion.
 */
static int vha_int_fixup;
module_param(vha_int_fixup, int, 0644);
/* Hermes item 3 v2: 0=裸拷贝（= 图里 __copy 的语义） 1=拷完再做 2 类 softmax */
static int vha_int_fixup_mode;
module_param(vha_int_fixup_mode, int, 0644);
MODULE_PARM_DESC(vha_int_fixup_mode, "VHA: int fixup post-op 0=raw copy 1=2-class softmax (default 0)");
MODULE_PARM_DESC(vha_int_fixup, "VHA: 1=copy engine-written unmapped buffer into same-size app buffer after completion (default 0)");


/* ===== VHA emulation: output-sync fd =====
 * Becomes readable ONLY after the bridge has detected that the engine
 * wrote back an output buffer. (An always-readable fd makes the lib
 * think the inference already finished and read stale output.)
 */
static atomic_t vha_sync_ready = ATOMIC_INIT(0);
static wait_queue_head_t vha_sync_wq;
static int vha_sync_wq_inited;
/* Hermes 2026-09-27: 累计"已交付给库的响应数"。完成判定必须用这个累计量：
 * ① 不能用"输出 CRC 变化"——同一输入重复推理时结果逐轮相同 ⇒ CRC 恒定（本案例实测）
 * ② 不能用"响应列表长度"——库会并发消费，长度先增后减，瞬时值必然漏
 * ③ 累计量不受"被消费"影响，等价于"库确实拿到了这一轮的完成响应"
 */
static atomic_t vha_rsp_served = ATOMIC_INIT(0);

static void vha_sync_wq_ensure(void)
{
	if (!vha_sync_wq_inited) {
		init_waitqueue_head(&vha_sync_wq);
		vha_sync_wq_inited = 1;
	}
}

static void vha_sync_signal(void)
{
	vha_sync_wq_ensure();
	atomic_set(&vha_sync_ready, 1);
	wake_up_all(&vha_sync_wq);
}

static __poll_t vha_sync_poll(struct file *file, poll_table *wait)
{
	vha_sync_wq_ensure();
	poll_wait(file, &vha_sync_wq, wait);
	if (atomic_read(&vha_sync_ready))
		return EPOLLIN | EPOLLRDNORM;
	return 0;
}

static ssize_t vha_sync_read(struct file *file, char __user *buf,
			     size_t count, loff_t *ppos)
{
	return 0;
}

static ssize_t vha_sync_write(struct file *file, const char __user *buf,
			      size_t count, loff_t *ppos)
{
	return count;
}

static int vha_sync_release(struct inode *inode, struct file *file)
{
	return 0;
}

static const struct file_operations vha_sync_fops = {
	.owner   = THIS_MODULE,
	.poll    = vha_sync_poll,
	.read    = vha_sync_read,
	.write   = vha_sync_write,
	.release = vha_sync_release,
};

/* ===== VHA emulation: host-mappable allocations ===== */
struct vha_alloc_entry {
	struct list_head list;
	void *kvaddr;
	dma_addr_t dma_handle;   /* DMA/bus address (NPU-visible via MMU) */
	struct phytium_npu_dev *npu;
	size_t size;
	size_t req_size;   /* HERMES-OVERALLOC: 库请求的逻辑尺寸 */
	unsigned long start_page;
	u64 iova;                /* mapped NPU IOVA (B2) */
	u32 map_type;            /* NPU_MAP_TYPE_* used at B2 */
	u32 buf_status;          /* NPU_BUF_* (0x7109 DnnSetupInputBuffer) */
	int alloc_ord;           /* allocation ordinal (same-size aliasing) */
	int mapped;              /* B2 done */
	u32 crc_snap;            /* CRC snapshot taken right before submit (int fixup) */
};

/* page -> user VA recorded at mmap (4-column table, col ④) */
struct vha_mmap_rec {
	struct list_head list;
	unsigned long page;
	unsigned long uva;
	size_t size;
};
static LIST_HEAD(vha_mmaps);

static LIST_HEAD(vha_allocs);
static DEFINE_MUTEX(vha_alloc_mutex);
static size_t vha_alloc_ask;   /* HERMES-OVERALLOC */
static unsigned long vha_next_page;
/* HERMES-OVERALLOC: 内部按放大尺寸分配，但【回报给库的尺寸保持原值】。
 * 动机：厂商库在"建网络对象"阶段会用【段 IO 声明的尺寸】校验缓冲容量
 * (实测 sensevoice: 申请 457776 但校验要 913920)，而库自己申请时用的是较小值。
 * 解耦后：库的记账不变(不会触发 parser 错误)，实际容量变大(能过校验)。
 * 0=关闭(默认)；N=按 N 倍放大(仅当请求 >= vha_overalloc_min 时生效)。 */
static int vha_overalloc_mul;
module_param(vha_overalloc_mul, int, 0644);
MODULE_PARM_DESC(vha_overalloc_mul, "VHA: internal alloc = req.size * N (report size unchanged)");
static int vha_overalloc_min = 65536;
/* HERMES-OVERALLOC-EXACT: 只放大【请求尺寸恰好等于 vha_overalloc_exact】的那块缓冲。
 * 动机：sensevoice 的 x 输入(x[1,200,560] f32 = 448000)被段 IO 按 913920 校验，
 * 而全序列里 448000 只出现 1 次 => 只放大它，多花 0.46MB，CMA 完全够。
 * 0=关闭。 */
static unsigned long long vha_overalloc_exact;
/* HERMES-REPORT-BOOST: 是否把【回报给库的尺寸】也改成放大后的值。
 * 0=只放大实际分配(库记账不变)；1=连回报值一起放大(库会看到更大的容量)。 */
static int vha_overalloc_report;
/* HERMES-GFP-TUNE: CMA 分配失败(-16)时，用更积极的 gfp 重试。
 * 0=GFP_KERNEL(原行为)；1=GFP_KERNEL|__GFP_RETRY_MAYFAIL；
 * 2=GFP_KERNEL|__GFP_RETRY_MAYFAIL|__GFP_ATOMIC 等组合。 */
static int vha_gfp_tune;
/* HERMES-INFO-FIX: 报告给库的 L3 大小（字节）。默认 512MB。 */
static unsigned int vha_info_l3_size = 512u << 20;
module_param(vha_info_l3_size, uint, 0644);
MODULE_PARM_DESC(vha_info_l3_size, "VHA: l3_size reported via NPU_INFO (bytes)");

module_param(vha_gfp_tune, int, 0644);
MODULE_PARM_DESC(vha_gfp_tune, "VHA: gfp flags for dma_alloc_coherent (0=GFP_KERNEL)");

module_param(vha_overalloc_report, int, 0644);
MODULE_PARM_DESC(vha_overalloc_report, "VHA: also report the boosted size to userspace");
static int vha_report_boost;
module_param(vha_overalloc_exact, ullong, 0644);
MODULE_PARM_DESC(vha_overalloc_exact, "VHA: only overalloc buffers whose req.size == this");

module_param(vha_overalloc_min, int, 0644);
MODULE_PARM_DESC(vha_overalloc_min, "VHA: apply overalloc only when req.size >= this");

static int vha_alloc_ord;

static void vha_dump_crcs(struct phytium_npu_dev *npu, const char *tag)
{
	struct vha_alloc_entry *a;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry(a, &vha_allocs, list) {
		if (!a->mapped)
			continue;
		dev_info(npu->dev,
			 "[VHA-CRC-%s] page=%lu size=%zu crc32=%#x\n",
			 tag, a->start_page, a->size,
			 crc32_le(0xffffffff, a->kvaddr, a->size) ^ 0xffffffff);
	}
	mutex_unlock(&vha_alloc_mutex);
}

static bool vha_find_str(const u8 *buf, size_t len, const char *needle)
{
	size_t nl = strlen(needle), i;

	if (!nl || len < nl)
		return false;
	for (i = 0; i + nl <= len; i++)
		if (memcmp(buf + i, needle, nl) == 0)
			return true;
	return false;
}

static struct vha_alloc_entry *vha_find_by_page(unsigned long page)
{
	struct vha_alloc_entry *e;

	list_for_each_entry(e, &vha_allocs, list) {
		unsigned long pages = (e->size + PAGE_SIZE - 1) >> PAGE_SHIFT;
		if (page >= e->start_page && page < e->start_page + pages)
			return e;
	}
	return NULL;
}

/* HERMES-REALFREE: 真正释放单条分配。
 * 原 PG5/PG8 只把 e->mapped 清 0，既不 dma_free_coherent 也不摘链
 * => 库以为释放了，驱动侧内存一直占着；而 vha_free_allocs 只在
 * close() 时调用，池的 worker 是长驻进程 => 732 次分配 0 次回收，CMA 被吃干。 */
static void vha_free_one(struct phytium_npu_dev *npu, unsigned long page_idx)
{
	struct vha_alloc_entry *e, *tmp;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry_safe(e, tmp, &vha_allocs, list) {
		if (e->start_page != page_idx)
			continue;
		list_del(&e->list);
		if (e->dma_handle)
			dma_free_coherent(e->npu->dev, PAGE_ALIGN(e->size),
					  e->kvaddr, e->dma_handle);
		else if (e->kvaddr)
			vfree(e->kvaddr);
		dev_info(npu->dev,
			 "[VHA-REALFREE] page=%lu size=%zu freed (ord=%d)\n",
			 page_idx, e->size, e->alloc_ord);
		kfree(e);
		break;
	}
	mutex_unlock(&vha_alloc_mutex);
}

static void vha_free_allocs(void)
{
	struct vha_alloc_entry *e, *tmp;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry_safe(e, tmp, &vha_allocs, list) {
		list_del(&e->list);
		if (e->dma_handle)
			dma_free_coherent(e->npu->dev, PAGE_ALIGN(e->size),
					  e->kvaddr, e->dma_handle);
		else
			vfree(e->kvaddr);
		kfree(e);
	}
	vha_next_page = 0;
	mutex_unlock(&vha_alloc_mutex);
}

static int phytium_npu_open(struct inode *inode, struct file *file)
{
	struct miscdevice  *miscdev = (struct miscdevice *)file->private_data;
	struct phytium_npu_dev *npudev = container_of(miscdev, struct phytium_npu_dev, miscdev);

	pr_debug("open device here!, npudev addr:%p, miscdev:%p", npudev, miscdev);
	if (!npudev->dev)
		return -1;

	struct phytium_npu_session *sess = phytium_npu_session_create(npudev->dev);

	if (!sess) {
		dev_err(npudev->dev, "No memory for creating session.");
		return -ENOMEM;
	}

	phytium_npu_session_init(npudev, sess);

	phytium_npu_create_new_mmu_context(npudev, sess);
	mutex_lock(&npudev->mutex_lock);
	phytium_npu_try_resume_work(npudev);
	mutex_unlock(&npudev->mutex_lock);
	file->private_data = sess;
	return 0;
}

static int phytium_npu_release(struct inode *inode, struct file *file)
{
	struct phytium_npu_session *sess = file->private_data;
	struct phytium_npu_dev *npu;
	int ret;

	if (!sess)
		return -EINVAL;
	npu = sess->npu_dev;
	pr_debug("npu close here!, npudev addr:%p, sess:%p", npu, sess);
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	phytium_npu_session_release(npu, sess);
	/* release coherent allocations of this session (fix leak) */
	vha_free_allocs();
	file->private_data = NULL;
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static ssize_t phytium_npu_read(struct file *file, char __user *buf, size_t len, loff_t *ppos)
{
	struct phytium_npu_session *sess = file->private_data;
	struct phytium_npu_dev *npu = sess->npu_dev;
	int ret, ret_len;

	pr_debug("%s:user reads the response", __func__);
	if (!sess)
		return -EINVAL;
	pr_debug("%s: with sess :%p, id:%d", __func__, sess, sess->id);
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;
	while (list_empty(&sess->response_list)) {
		if (file->f_flags & O_NONBLOCK) {
			dev_dbg(npu->dev, "%s: no block!", __func__);
			mutex_unlock(&npu->mutex_lock);
			return -EAGAIN;
		}
		dev_dbg(npu->dev, "%s: going to sleep\n", __func__);
		if (wait_event_interruptible(sess->response_wq,
					     !list_empty(&sess->response_list))) {
			dev_dbg(npu->dev, "%s: signal\n", __func__);
			mutex_unlock(&npu->mutex_lock);
			return -ERESTARTSYS;
		}

		dev_dbg(npu->dev, "%s: woken up\n", __func__);
	}

	if (list_empty(&sess->response_list)) {
		ret = 0;
		goto out;
	}

	struct npu_user_stream_rsp *rsp;

	rsp = list_first_entry(&sess->response_list,
			       struct npu_user_stream_rsp,
								stream_rsp_list_entry);
	if (!rsp) {
		pr_debug("%s:get response NULL", __func__);
		ret = 0;
		goto out;
	}
	if (len >= rsp->rsp_size)
		ret_len = rsp->rsp_size;
	else
		ret_len = len;
	/* HERMES-RESP-FIX: 库 libnpusession 的 GetVhaResponse 取响应 +2 处的 u16 当 task/事件 id,
	 * <=0 时直接构造 "Error reading response from VHA device." 并丢弃响应
	 * (池路径表现为 phydnnWaitForEvent 失败 / ORT 路径表现为 5s 超时)。
	 * 实测库只接受 1 或 4。回退=删掉本块。 */
	{
		u16 *ridp = (u16 *)&rsp->ursp;

		ridp[1] = 1;
		dev_info(npu->dev, "[VHA-RESPFIX] rsp[+2] <- 1\n");
	}
	ret = copy_to_user(buf, &rsp->ursp, ret_len);
	if (ret) {
		ret = -EFAULT;
		goto out;
	}

	list_del(&rsp->stream_rsp_list_entry);
	atomic_inc(&vha_rsp_served);
	ret = ret_len;

	if (!rsp->session)
		kfree(rsp);
out:
	mutex_unlock(&npu->mutex_lock);
	return ret;
}

static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)
{
	struct npu_user_stream_rsp *rsp;
	u32 size = MAX_NPU_UCNN_RSP_SIZE;

	rsp = kzalloc(sizeof(*rsp), GFP_KERNEL);
	if (!rsp)
		return;
	INIT_LIST_HEAD(&rsp->stream_rsp_list_entry);
	rsp->ursp.sid = sid;
	rsp->ursp.err_no = (u32)err_no;
	/* VHA response: u16 event type at byte offset 2 (must be > 0) */
	rsp->ursp.rsp_err_flags = (u64)1 << 16;
	rsp->ursp.session_id = sess->id;
	rsp->rsp_size = (int)size;
	rsp->session = sess;

	list_add_tail(&rsp->stream_rsp_list_entry, &sess->response_list);
	wake_up(&sess->response_wq);
}

/* combined CRC over all NON-INPUT buffers; buffers larger than
 * VHA_CRC_SAMPLE are sampled (head+tail) so the watchdog stays cheap.
 *
 * Hermes 2026-09-27: the old `size > 65536 -> skip` filter made this
 * watchdog blind for every model whose buffers are ALL >64KB
 * (yolov5s: 6.5MB/1.6MB/408KB/11.9MB/32.5MB, scrfd similar) =>
 * crc stayed constant => `done` never set => 5s timeout => no
 * completion response pushed to the library => app "stuck on frame 1".
 * Root cause of yolov5s/scrfd stalls is HERE, not in the engine.
 */
#define VHA_CRC_SAMPLE 65536
static u32 vha_out_crc(void)
{
	struct vha_alloc_entry *e;
	u32 crc = 0;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry(e, &vha_allocs, list) {
		size_t len = e->req_size ? e->req_size : e->size;   /* HERMES-CMDSIZE-FIX */

		if (!e->mapped || !e->kvaddr || !len)
			continue;
		if (e->start_page == 0)   /* input: engine never writes it */
			continue;
		if (len > VHA_CRC_SAMPLE) {
			crc ^= crc32_le(0xffffffff, e->kvaddr,
					VHA_CRC_SAMPLE) ^ 0xffffffff;
			crc ^= crc32_le(0xffffffff,
					(u8 *)e->kvaddr + len - VHA_CRC_SAMPLE,
					VHA_CRC_SAMPLE) ^ 0xffffffff;
		} else {
			crc ^= crc32_le(0xffffffff, e->kvaddr, len) ^ 0xffffffff;
		}
	}
	mutex_unlock(&vha_alloc_mutex);
	return crc;
}

/* Hermes 2026-09-27 (item 3): per-alloc CRC with the same sampling rule
 * as vha_out_crc() so big buffers are covered too.
 */
static u32 vha_alloc_crc(struct vha_alloc_entry *e)
{
	size_t len = e->size;

	if (!e->mapped || !e->kvaddr || !len)
		return 0;
	if (len > VHA_CRC_SAMPLE)
		return (crc32_le(0xffffffff, e->kvaddr, VHA_CRC_SAMPLE) ^ 0xffffffff) ^
		       (crc32_le(0xffffffff, (u8 *)e->kvaddr + len - VHA_CRC_SAMPLE,
				 VHA_CRC_SAMPLE) ^ 0xffffffff);
	return crc32_le(0xffffffff, e->kvaddr, len) ^ 0xffffffff;
}

/* Hermes item 3 v2 (2026-09-27): 交付补齐（触发点 = 用户态 mmap 该缓冲的时刻）。
 * 若该缓冲引擎没写过、且存在"同尺寸且引擎写过"的缓冲 => 把后者拷进来。
 * 可选再施加 2 类 softmax（vha_int_fixup_mode=1），因为厂商运行时应做、却整个跳过了。
 * 背景：yunet 的 conf 由 NPU 写在 INT-3(page93)，App 读的是同尺寸的另一块(page47)，
 *       图里本该由 CPU 节点 __copy_1 完成拷贝，但它从未执行 => App 读到全 0。
 */
/* 注意（2026-09-27 实测）：麒麟 arm64 内核用 -mgeneral-regs-only 编译，
 * 内核代码里出现 float/double 类型直接编译不过（即使用 kernel_neon_begin 也不行，
 * 除非改 Makefile 放开 FP —— 那会让整个文件都可能用 SIMD 寄存器，风险太大）。
 * 结论：**本模块只做"传输"（把引擎写过的缓冲拷到 App 读的那块），
 *        激活（如 conf 的 2 类 softmax）交给用户态**。见 [VHA-INTFIX] 日志。
 */
static void vha_int_fixup_snapshot(void)
{
	struct vha_alloc_entry *e;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry(e, &vha_allocs, list)
		e->crc_snap = vha_alloc_crc(e);
	mutex_unlock(&vha_alloc_mutex);
}

/* 调用者需持 vha_alloc_mutex（mmap 处理路径已持）。全程只读 CRC + 一次 memcpy。 */
static void vha_int_fixup_fill(struct phytium_npu_dev *npu, struct vha_alloc_entry *dst)
{
	struct vha_alloc_entry *a, *src = NULL;
	int cands = 0;

	if (!dst || !dst->mapped || !dst->kvaddr || !dst->size)
		return;
	if (vha_alloc_crc(dst) != dst->crc_snap)	/* 引擎写过/已被改 => 不当 dst */
		return;
	list_for_each_entry(a, &vha_allocs, list) {
		if (a == dst || !a->mapped || !a->kvaddr || a->size != dst->size)
			continue;
		if (vha_alloc_crc(a) == a->crc_snap)	/* 引擎没写过 => 不能当源 */
			continue;
		cands++;
		if (!src)
			src = a;
	}
	if (!src) {
		dev_dbg(npu->dev,
			"[VHA-INTFIX] page=%lu size=%zu 无同尺寸'引擎写过'缓冲, 不动\n",
			dst->start_page, dst->size);
		return;
	}
	if (cands > 1)
		dev_warn(npu->dev,
			 "[VHA-INTFIX] AMBIGUOUS: %d 个同尺寸'引擎写过'缓冲, 取 page=%lu\n",
			 cands, src->start_page);
	memcpy(dst->kvaddr, src->kvaddr, dst->size);
	if (vha_int_fixup_mode)
		dev_warn(npu->dev,
			 "[VHA-INTFIX] mode=%d 请求了内核侧激活, 但本内核禁用浮点(-mgeneral-regs-only): 只做裸拷贝, 激活请在用户态做\n",
			 vha_int_fixup_mode);
	dev_info(npu->dev,
		 "[VHA-INTFIX] fill page=%lu <- page=%lu size=%zu mode=%d\n",
		 dst->start_page, src->start_page, dst->size, vha_int_fixup_mode);
}

/* Persistent synthetic stream for the official IRQ completion path.
 * Never freed -> no UAF; is_use_repeat=TRUE -> driver won't free it.
 */
static struct phytium_npu_stream *vha_dummy;

static void vha_install_dummy(struct phytium_npu_dev *npu,
			      struct phytium_npu_session *sess, u32 sid)
{
	if (!vha_dummy) {
		vha_dummy = kzalloc(sizeof(*vha_dummy), GFP_KERNEL);
		if (!vha_dummy)
			return;
		INIT_LIST_HEAD(&vha_dummy->stream_list_entry);
		vha_dummy->rsp = NULL;
	}
	vha_dummy->session = sess;
	vha_dummy->stream_status = NPU_STREAM_IN_HW;
	vha_dummy->infer_status = NPU_STREAM_INFER_WORK;
	vha_dummy->nustream.estream.sflags = 0x1;
	vha_dummy->nustream.estream.stype = 0x201; /* SUBMIT -> 40B rsp */
	vha_dummy->nustream.estream.sid = sid;
	npu->is_use_repeat = vha_use_repeat ? TRUE : FALSE;
	npu->activated_stream = vha_dummy;
}

static struct vha_alloc_entry *vha_find_by_iova(u64 iova)
{
	struct vha_alloc_entry *e;
	list_for_each_entry(e, &vha_allocs, list)
		if (e->mapped && e->iova == iova)
			return e;
	return NULL;
}

/*
 * B4: translate a VHA 272-byte submit descriptor and program the NPU.
 * Descriptor layout (confirmed by reverse engineering):
 *   @0 sflags @2 stype @4 sid @8 sp1 @9 sp2 @10 all @11 in @12 t
 *   @16 u32 fd[16]
 *   @80 stream_off @84 stream_fd @88 stream_size
 */
static ssize_t vha_real_submit(struct phytium_npu_dev *npu,
			       struct phytium_npu_session *sess,
			       const char __user *ubuf, size_t count)
{
	u8 desc[272];
	u16 sflags, stype;
	u32 sid, t, fd[16];
	s32 stream_off, stream_fd, stream_size;
	int all, in, i;
	u64 cmd_base = 0;
	u32 cmd_words = 0;   /* expected command-stream words (= size/32) */

	if (count < 96 || count > sizeof(desc))
		return -EINVAL;
	if (copy_from_user(desc, ubuf, count))
		return -EFAULT;

	memcpy(&sflags, &desc[0], 2);
	memcpy(&stype, &desc[2], 2);
	memcpy(&sid, &desc[4], 4);
	all = desc[10];
	in = desc[11];
	memcpy(&t, &desc[12], 4);
	memcpy(fd, &desc[16], sizeof(fd));
	memcpy(&stream_off, &desc[80], 4);
	memcpy(&stream_fd, &desc[84], 4);
	memcpy(&stream_size, &desc[88], 4);

	dev_info(npu->dev,
		 "[VHA-SUBMIT] sflags=%#x stype=%#x sid=%#x all=%d in=%d t=%d "
		 "soff=%d sfd=%d ssize=%d\n",
		 sflags, stype, sid, all, in, t, stream_off, stream_fd,
		 stream_size);
	print_hex_dump(KERN_INFO, "[VHA-DESC] ", DUMP_PREFIX_OFFSET, 16, 1,
		       desc, count, false);
	for (i = 0; i < 16; i++) {
		if (fd[i])
			dev_info(npu->dev, "[VHA-SUBMIT]   fd[%d]=%u\n", i, fd[i]);
	}

	/*
	 * VHA descriptor (272B) layout:
	 *   @0x10 u32 fd[16]        buffer handle == page_idx (from VHA_ALLOC_MEM)
	 *   @0x90 u32 bufsizes[16]
	 *   @0xd0 u8  idx[16]       ADDR register index
	 *   t (u32 @12)             command-stream buffer handle
	 */
	{
		u32 bufsz[16];
		u8 idx[16];
		u64 used = 0;
		u32 bufsz_official[4], bufsz_ours[4];

		/* our lib layout: bufsizes@0x90 idx@0xd0
		 * official header: bufsizes@0x9c idx@0xdc (12B later)
		 * log both to disambiguate
		 */
		memcpy(bufsz_ours, &desc[0x90], sizeof(bufsz_ours));
		memcpy(bufsz_official, &desc[0x9c], sizeof(bufsz_official));
		dev_info(npu->dev,
			 "[VHA-OFF] ours@0x90: %u %u %u %u | official@0x9c: %u %u %u %u\n",
			 bufsz_ours[0], bufsz_ours[1], bufsz_ours[2], bufsz_ours[3],
			 bufsz_official[0], bufsz_official[1], bufsz_official[2],
			 bufsz_official[3]);
		dev_info(npu->dev,
			 "[VHA-OFF] idx ours@0xd0: %u %u %u %u %u %u | official@0xdc: %u %u %u %u\n",
			 desc[0xd0], desc[0xd1], desc[0xd2], desc[0xd3], desc[0xd4], desc[0xd5],
			 desc[0xdc], desc[0xdd], desc[0xde], desc[0xdf]);

		memcpy(bufsz, &desc[0x90], sizeof(bufsz));
		memcpy(idx, &desc[0xd0], sizeof(idx));

		/* command stream buffer */
		{
			struct vha_alloc_entry *e;
			mutex_lock(&vha_alloc_mutex);
			struct vha_alloc_entry *a;
			list_for_each_entry(a, &vha_allocs, list) {
				if (!a->mapped)
					continue;
				dev_info(npu->dev,
					 "[VHA-ALLOC] page=%lu iova=%#llx size=%zu head=%02x%02x%02x%02x\n",
					 a->start_page, a->iova, a->size,
					 ((u8 *)a->kvaddr)[0], ((u8 *)a->kvaddr)[1],
					 ((u8 *)a->kvaddr)[2], ((u8 *)a->kvaddr)[3]);
			}
			e = vha_find_by_page(vha_cmd_page >= 0 ? (unsigned)vha_cmd_page : t);
			if (e && e->mapped) {
				cmd_base = e->iova;
				/* HERMES-CMDSIZE-FIX: 命令流必须用【逻辑尺寸】(e->req_size)。
				 * e->size 现在是"实际分配尺寸"(可能被 OVERALLOC 放大)，
				 * 用它算 cmd_words 会把 26 条算成 128 条 => 库按错字数解析 => 不写回。 */
				cmd_words = (e->req_size ? e->req_size : e->size) / 32;
				dev_info(npu->dev,
					 "[VHA-SUBMIT] cmd buf page=%u iova=%#llx size=%zu words=%u crc32=%#x\n",
					 t, cmd_base, e->req_size ? e->req_size : e->size, cmd_words,
					 crc32_le(0xffffffff, e->kvaddr,
						  e->req_size ? e->req_size : e->size) ^ 0xffffffff);
				/* Hermes 25th: decode command-stream header */
				{
					u32 *w = e->kvaddr;

					dev_info(npu->dev,
						 "[VHA-CMDS-HDR] word0=%#x word1=%#x word2=%#x word3=%#x (w0&0xffff=%u)\n",
						 w[0], w[1], w[2], w[3], w[0] & 0xffff);
					print_hex_dump(KERN_INFO, "[VHA-CMDS-BYTES] ",
						       DUMP_PREFIX_OFFSET, 16, 1,
						       e->kvaddr, 64, false);
				}
			}
			mutex_unlock(&vha_alloc_mutex);
		}
		if (!cmd_base) {
			dev_err(npu->dev, "[VHA-SUBMIT] no cmd buffer for t=%u\n", t);
			return -EINVAL;
		}

		dev_info(npu->dev,
			 "[VHA-TD-A] before: power=%d load=%d STATUS=%#x ACE=%#x CTRL=%#x EVT=%#x CLK=%#x MDBG_IDLE=%#x\n",
			 npu->power_status, npu->load_status,
			 REGREAD32(npu, NPU_CH0_STATUS),
			 phytium_npu_get_axi_err_status(npu),
			 REGREAD32(npu, NPU_CH0_CONTROL),
			 REGREAD32(npu, NPU_CH0_VHA_EVENT_STATUS),
			 REGREAD32(npu, NPU_SYS_CLK_STATUS),
			 REGREAD32(npu, NPU_MDBG_IDLE));
		{
			u64 vha_ta = ktime_get_ns();

			phytium_npu_try_resume_work(npu);
			phytium_npu_config_clock(npu, TRUE);
			phytium_npu_config_hl_wdt(npu);
			dev_info(npu->dev, "[VHA-TIME] try_resume+clock+hl_wdt: %llu ms\n",
				 (unsigned long long)(ktime_get_ns() - vha_ta) / 1000000);
		}
		/* explicit power-up + self reset (try_resume_work short-circuits
		 * when power_status==ON, so call these directly)
		 * Hermes 2026-09-27: vha_reset_each_run=0 时只有**首跑**做，之后跳过
		 * （实测第 2 次起每次多等 ~40.6s，定位此处）
		 */
		{
			u64 vha_tb = ktime_get_ns();
			int rr = 0;
			int r2 = 0;

			if (vha_reset_each_run || !vha_did_first_reset) {
				u64 t = ktime_get_ns();

				rr = phytium_npu_common_resume(npu->dev);
				dev_info(npu->dev, "[VHA-TIME] common_resume: %llu ms (rc=%d)\n",
					 (unsigned long long)(ktime_get_ns() - t) / 1000000, rr);
				t = ktime_get_ns();
				r2 = phytium_npu_hw_reset_self(npu);
				dev_info(npu->dev, "[VHA-TIME] hw_reset_self: %llu ms (rc=%d)\n",
					 (unsigned long long)(ktime_get_ns() - t) / 1000000, r2);
				vha_did_first_reset = 1;
			} else {
				dev_info(npu->dev,
					 "[VHA-TIME] 跳过 resume/reset（非首跑, vha_reset_each_run=0）\n");
			}
			dev_info(npu->dev,
				 "[VHA-TD-A] common_resume -> %d EVT=%#x\n",
				 rr, REGREAD32(npu, NPU_CH0_VHA_EVENT_STATUS));
			dev_info(npu->dev,
				 "[VHA-TD-A/C] hw_reset_self -> %d EVT_after=%#x CLK=%#x MDBG_IDLE=%#x PSIZE_RONE=%#x MMU_CTRL_BS=%#llx MMU_ERR_S1=%#llx MMU_ERR_S2=%#llx\n",
				 r2, REGREAD32(npu, NPU_CH0_VHA_EVENT_STATUS),
				 REGREAD32(npu, NPU_SYS_CLK_STATUS),
				 REGREAD32(npu, NPU_MDBG_IDLE),
				 REGREAD32(npu, NPU_SYS_MMU_PSIZE_RONE),
				 REGREAD64(npu, NPU_CH0_MMU_CTRL_BS),
				 REGREAD64(npu, NPU_CH0_MMU_ERR_S1),
				 REGREAD64(npu, NPU_CH0_MMU_ERR_S2));
			dev_info(npu->dev, "[VHA-TIME] 复位段合计: %llu ms\n",
				 (unsigned long long)(ktime_get_ns() - vha_tb) / 1000000);
		}
		phytium_npu_mmu_config_dev_mmu(sess);
		REGWRITE64(npu, NPU_CH0_CMD_BASE_ADDRESS, cmd_base);

		/* Program ADDR per official semantics:
		 *   buffer i<8 -> ADDR0 bank ; i>=8 -> ADDR8 bank
		 *   ADDR index = idx[i] ; skip the stream buffer
		 *   high 16 bits of ADDR_USED mark non-inference buffers
		 */
		for (i = 0; i < all && i < 16; i++) {
			struct vha_alloc_entry *e;
			u8 a = idx[i];

			/* NOTE: handle 0 is a VALID buffer in this lib
			 * (input page 0) -> do NOT use "fd==0 means empty";
			 * empty slots have idx[i]==0 instead.
			 */
			if (a == 0)
				continue;
			if (fd[i] == t ||
			    (stream_fd && fd[i] == (u32)stream_fd)) {
				dev_info(npu->dev,
					 "[VHA-SUBMIT] i=%d fd=%u is stream buf -> not in ADDR\n",
					 i, fd[i]);
				continue;
			}
			if (a >= 16)
				continue;
			mutex_lock(&vha_alloc_mutex);
			e = vha_find_by_page(fd[i]);
			if (e && e->mapped) {
				u64 iova = e->iova;

				if (vha_bad_addr && a == 1) {
					iova = vha_bad_addr;
					dev_info(npu->dev,
						 "[VHA-T3] forcing ADDR1 -> bad iova %#lx\n",
						 vha_bad_addr);
				}
				if (i < 8)
					REGWRITE64(npu, NPU_CH0_ADDR0 + a * 8, iova);
				else
					REGWRITE64(npu, NPU_CH0_ADDR8 + a * 8, iova);
				used |= 1ULL << a;
				if (!(e->map_type & NPU_MAP_TYPE_INFERENCE))
					used |= 1ULL << (a + 16);
				dev_info(npu->dev,
					 "[VHA-SUBMIT] i=%d fd=%u sz=%u idx=%u iova=%#llx reg=ADDR%s+%u type=%#x\n",
					 i, fd[i], bufsz[i], a, e->iova,
					 i < 8 ? "0" : "8", a * 8, e->map_type);
				/* Hermes 4-column table */
				{
					struct vha_mmap_rec *mr;
					unsigned long uva = 0;

					list_for_each_entry(mr, &vha_mmaps, list)
						if (mr->page == e->start_page) {
							uva = mr->uva;
							break;
						}
					dev_info(npu->dev,
						 "[VHA-4COL] slot=%d ①fd=%u,idx=%u,sz=%u | ②page=%lu,ord=%d,kva=%p | ③ADDR%s+%u,iova=%#llx | ④uva=%#lx %s\n",
						 i, fd[i], a, bufsz[i],
						 e->start_page, e->alloc_ord, e->kvaddr,
						 i < 8 ? "0" : "8", a * 8, e->iova,
						 uva, uva ? "MMAP" : "NOT-mmap");
				}
			} else {
				dev_warn(npu->dev,
					 "[VHA-SUBMIT] i=%d fd=%u page %u NOT FOUND\n",
					 i, fd[i], fd[i]);
			}
			mutex_unlock(&vha_alloc_mutex);
		}
		REGWRITE64(npu, NPU_CH0_ADDR_USED, used);
		wmb();   /* make descriptors/command stream visible before start */

		/* T1: output-buffer CRC before submit */
		vha_dump_crcs(npu, "before");

		/* Table B: enable cache counters, snapshot before start */
		REGWRITE32(npu, NPU_CACHE_RESET, 0x3fffffff);
		REGWRITE32(npu, NPU_CACHE_REQ_CNT_EN, 0x1);
		dev_info(npu->dev,
			 "[VHA-TD-B] before start: CMDREQ_RD=%#x CMDREQ_RD_WORD=%#x OUTSTANDING_RD=%#x MDBG_IDLE=%#x\n",
			 REGREAD32(npu, NPU_CACHE_CMDREQ_RD),
			 REGREAD32(npu, NPU_CACHE_CMDREQ_RD_WORD),
			 REGREAD32(npu, NPU_OUTSTANDING_READ),
			 REGREAD32(npu, NPU_MDBG_IDLE));

		/* Install a persistent synthetic stream and ENABLE the
		 * completion-event IRQ (the engine write-back appears to be
		 * gated on the event). The official IRQ path then pushes the
		 * completion response. common.c bug-B (NULL deref) is fixed
		 * and is_use_repeat=TRUE avoids the stream being freed.
		 */
		vha_install_dummy(npu, sess, sid);
		phytium_npu_config_event(npu, NPU_ALL_EVENT, TRUE);

		/* Hermes (item 3): per-alloc CRC snapshot for the delivery fixup */
		if (vha_int_fixup)
			vha_int_fixup_snapshot();

		/* capture pre-run output CRC (stable: input written before ioctl) */
		{
			u32 crc0 = vha_out_crc();
			/* Hermes 25th: use REAL stream size, guard underflow
			 * (stream_size==0 -> (0/32-1) underflows -> 0xFFFFFFFF)
			 */
			u32 stream_size = (u32)(cmd_words * 32);
			u32 ctrl;
			int tmo;
			u32 done = 0;

			if (!stream_size) {
				dev_err(npu->dev,
					"[VHA-SUBMIT] stream_size==0, refuse (avoid CONTROL underflow)\n");
				return -EINVAL;
			}
			ctrl = min(2048, stream_size);
			ctrl = (ctrl / 32 - 1) << 1;
			ctrl |= NPU_HW_START_EN;
			ctrl |= (sess->mmu_ctx[NPU_MMU_CONTEXT_MODULE_ID].context_id << 12);
			dev_info(npu->dev,
				 "[VHA-SUBMIT] CONTROL=%#x used=%#llx ctxid=%u sid=%#x stream_size=%u cmd_words=%u\n",
				 ctrl, used,
				 sess->mmu_ctx[NPU_MMU_CONTEXT_MODULE_ID].context_id,
				 sid, stream_size, cmd_words);
			wmb();
			REGWRITE32(npu, NPU_CH0_CONTROL, ctrl);

			/* completion = engine wrote back output buffer(s).
			 * Hermes: the completion signal can precede the last
			 * output write landing -> app would read pre-write
			 * (all-zero) data. Also wait until the write-back CRC
			 * is STABLE for vha_settle_ms before returning.
			 */
			/* Hermes 2026-09-27: 原写法 `for (tmo=0; tmo<5000; tmo++) msleep(1)`
			 * 把"迭代次数"当毫秒用，而本内核 msleep(1)≈8ms ⇒ 空转满一次 ~40s！
			 * 改为：①真实 5s 截止 ②完成判定优先看"IRQ 响应已入队"
			 * （官方 IRQ 路径 phytium_npu_response_stream 会往 sess->response_list 推），
			 * CRC 变化作为后备 ③ 报真实等待时长与来源。
			 */
			{
				u64 vha_t_start = ktime_get_ns();
				u64 vha_deadline = vha_t_start + 5000ULL * 1000000ULL;
				int served_before = atomic_read(&vha_rsp_served);
				int src = 0;

				for (tmo = 0; ktime_get_ns() < vha_deadline; tmo++) {
					msleep(1);
					if (atomic_read(&vha_rsp_served) > served_before) {
						done = 1;
						src = 1;
						vha_sync_signal();
						break;
					}
					if (vha_out_crc() != crc0) {
						done = 1;
						src = 2;
						vha_sync_signal();
						break;
					}
					if (REGREAD32(npu, NPU_MDBG_FAULT_STOP_STATUS) ||
					    REGREAD32(npu, NPU_PAGE_FAULT_STALL))
						break;   /* fault -> stop waiting */
				}
				tmo = (int)((ktime_get_ns() - vha_t_start) / 1000000ULL);
				dev_info(npu->dev, "[VHA-TIME] 等待完成: %d ms 来源=%s done=%u\n",
					 tmo, src == 1 ? "IRQ响应" : (src == 2 ? "CRC" : (src == 3 ? "硬件进度" : "超时/其他")), done);
			}
			if (done && vha_settle_ms > 0) {
				u32 last = vha_out_crc();
				int stable = 0, g;

				for (g = 0; g < 2000 &&
					    stable < vha_settle_ms; g++) {
					msleep(1);
					if (vha_out_crc() == last) {
						stable++;
					} else {
						last = vha_out_crc();
						stable = 0;
						done = 2;
					}
				}
				dev_info(npu->dev,
					 "[VHA-SETTLE] done=%u extra=%dms stable=%dms\n",
					 done, g, stable);
			}
			/* Hermes item 3 v2: 触发点已挪到"用户态 mmap 该缓冲"的时刻
			 * （完成时 App 还没 map 输出缓冲, 此处条件永不成立）
			 */
			/* Hermes 2026-09-27: was hardcoded to yunet pages
			 * 37/49/93/47 -> useless for any other model.
			 * Now prints the head of EVERY mapped buffer
			 * (bounded to 16), so it works for all models.
			 */
			{
				struct vha_alloc_entry *oe;
				int shown = 0;

				mutex_lock(&vha_alloc_mutex);
				list_for_each_entry(oe, &vha_allocs, list) {
					u32 *up = oe->kvaddr;

					if (!oe->mapped || !up || oe->size < 16)
						continue;
					if (shown++ >= 16)
						break;
					dev_info(npu->dev,
						 "[VHA-OUTHEAD] page=%lu sz=%zu: %08x %08x %08x %08x\n",
						 oe->start_page, oe->size,
						 up[0], up[1], up[2], up[3]);
				}
				mutex_unlock(&vha_alloc_mutex);
			}
			dev_info(npu->dev,
				 "[VHA-SUBMIT] done=%d after %dms CMDREQ_RD_WORD=%#x MDBG_IDLE=%#x FAULT=%#x\n",
				 done, tmo,
				 REGREAD32(npu, NPU_CACHE_CMDREQ_RD_WORD),
				 REGREAD32(npu, NPU_MDBG_IDLE),
				 REGREAD32(npu, NPU_MDBG_FAULT_STOP_STATUS));
			/* Hermes 2026-09-27: extra evidence when the watchdog
			 * did NOT fire -- tells us whether the engine signalled
			 * anything at all.
			 */
			if (!done)
				dev_info(npu->dev,
					 "[VHA-NODONE] EVENT_STATUS=%#x EVENT_ENABLE=%#x MDBG_STATUS3=%#x MDBG_S1=%#x S2=%#x PAGEFAULT_STALL=%#x\n",
					 REGREAD32(npu, NPU_CH0_VHA_EVENT_STATUS),
					 REGREAD32(npu, NPU_CH0_VHA_EVENT_ENABLE),
					 REGREAD32(npu, NPU_MDBG_STATUS3),
					 REGREAD32(npu, NPU_MDBG_S1),
					 REGREAD32(npu, NPU_MDBG_S2),
					 REGREAD32(npu, NPU_PAGE_FAULT_STALL));
			dev_info(npu->dev,
				 "[VHA-DIAG] OPK_WR=%#x MM_REQ_WR=%#x CMDBCK_WR=%#x CREQ_RD=%#x MMU_REQ_RD=%#x AREQ_RD=%#x EWO_RD=%#x FIFO=%#x OUTSTD=%#x PAGEFAULT=%#x MMU_S1=%#llx\n",
				 REGREAD32(npu, 0x0BB8), REGREAD32(npu, 0x0B98),
				 REGREAD32(npu, 0x0A68), REGREAD32(npu, 0x0BA8),
				 REGREAD32(npu, 0x0B20), REGREAD32(npu, 0x0BB0),
				 REGREAD32(npu, 0x0B30), REGREAD32(npu, NPU_FIFO_WORD_COUNT),
				 REGREAD32(npu, NPU_OUTSTANDING_READ),
				 REGREAD32(npu, NPU_PAGE_FAULT_STALL),
				 REGREAD64(npu, NPU_CH0_MMU_ERR_S1));
			vha_dump_crcs(npu, "after");
		}
	}

	/* completion response is pushed by the official IRQ path
	 * (see vha_install_dummy + phytium_npu_inference_complete).
	 */
	return count;
}


static ssize_t phytium_npu_write(struct file *file, const char __user *buf,
				 size_t count, loff_t *pposn)
{
	struct phytium_npu_session *sess = file->private_data;
	struct phytium_npu_dev *npu = sess->npu_dev;

	if (!sess)
		return -EINVAL;

	if (vha_sim_mode) {
		u8 d[272];
		size_t n = min(count, sizeof(d));
		dev_info(npu->dev, "%s: emulated submit count=%zu\n", __func__, count);
		if (!copy_from_user(d, buf, n))
			print_hex_dump(KERN_INFO, "[VHA-DESC-SIM] ",
				       DUMP_PREFIX_OFFSET, 16, 1, d, n, false);
		vha_push_response(sess, 0, 0);
		vha_sync_signal();
		return count;
	}
	return vha_real_submit(npu, sess, buf, count);
}

static unsigned int phytium_npu_poll(struct file *file, poll_table *wait)
{
	struct phytium_npu_session *sess = file->private_data;
	unsigned long event = poll_requested_events(wait);
	unsigned int mask = 0, ret;

	if (!sess)
		return -EINVAL;
	pr_debug("%s: PID: %d, sess id: %d, link: %p\n", __func__,
		 task_pid_nr(current), sess->id, sess);
	ret = mutex_lock_interruptible(&sess->npu_dev->mutex_lock);
	if (ret)
		return POLLERR;
	if (event & (POLLIN | POLLRDNORM)) {
		/* Register for event */
		poll_wait(file, &sess->response_wq, wait);

		if (!list_empty(&sess->response_list))
			mask = POLLIN | POLLRDNORM;
	}
	mutex_unlock(&sess->npu_dev->mutex_lock);
	pr_debug("return mask %x, POLLIN:%x, POLLRDNORM:%x", mask, POLLIN, POLLRDNORM);
	return mask;
}

static int phytium_npu_mm_debug_perf(struct phytium_npu_dev *npu,
				     struct phytium_npu_session *sess,
							void *arg)
{
	struct npu_debug_perf *dbg_cfg = (struct npu_debug_perf *)arg;
	struct phytium_npu_debugfs *dbgfs = &sess->dbgfs;
	int ret;

	if (copy_from_user(&sess->dbgfs, dbg_cfg, sizeof(*dbg_cfg)))
		return -EFAULT;
	pr_debug("[%s]:config debug info:%d,type:%#x", __func__,
		 dbgfs->debug_mode, dbgfs->debug_type);

	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	ret = phytiun_npu_check_debug_fs_cfg(sess);
	mutex_unlock(&npu->mutex_lock);
	return ret;
}

static int phytium_npu_mm_repeat_stream(struct phytium_npu_dev *npu,
					struct phytium_npu_session *sess,
							void *arg)
{
	struct npu_repeat_stream stream;
	struct npu_repeat_stream *rstream = &stream;
	int ret;

	if (copy_from_user(rstream, arg, sizeof(*rstream)))
		return -EFAULT;
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	phytium_npu_repeat_stream(sess, rstream->stream_id & rstream->stream_id_mask,
				  rstream->is_repeat);
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static int phytium_npu_mm_delete_stream(struct phytium_npu_dev *npu,
					struct phytium_npu_session *sess,
							void *arg)
{
	struct npu_delete_stream stream;
	struct npu_delete_stream *dstream = &stream;
	int ret;

	if (copy_from_user(dstream, arg, sizeof(*dstream)))
		return -EFAULT;
	pr_info("%s: dstream id :%x, mask:%x, response:%d", __func__, dstream->stream_id,
		dstream->stream_id_mask, dstream->is_res);
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	phytium_npu_delete_stream(npu, sess, dstream);
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static int phytium_npu_mm_sync_buf(struct phytium_npu_dev *npu,
				   struct phytium_npu_session *sess, void *arg)
{//TODO.
	return 0;
}

static int phytium_npu_mm_set_buf(struct phytium_npu_dev *npu,
				  struct phytium_npu_session *sess,
						void *arg)
{
	struct npu_set_buffer buf;
	struct npu_set_buffer *sbuf = &buf;
	int ret;

	if (copy_from_user(sbuf, arg, sizeof(*sbuf)))
		return -EFAULT;
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;
	phytium_npu_set_stream_buf_status_with_fd(sess, sbuf->fd, sbuf->set_state);
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static int phytium_npu_mm_unmap(struct phytium_npu_dev *npu,
				struct phytium_npu_session *sess,
					void *arg)
{
	int ret;
	struct npu_memory_unmap usr_unmap;

	if (copy_from_user(&usr_unmap, arg, sizeof(usr_unmap)))
		return -EFAULT;
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	phytium_npu_mmu_unmap(npu, sess, &usr_unmap);
	pr_debug("------unmap done");
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static int phytium_npu_mm_import(struct phytium_npu_dev *npu,
				 struct phytium_npu_session *sess,
							void *arg)
{
	struct npu_memory_map tmp;
	struct npu_memory_map *map = &tmp;
	int ret;

	if (copy_from_user(map, arg, sizeof(*map)))
		return -EFAULT;
	pr_debug("map type:%x, fd:%d, vaddr:%llx", map->map_type, map->fd, map->vaddr);
	ret = mutex_lock_interruptible(&npu->mutex_lock);
	if (ret)
		return ret;

	ret = phytium_npu_mmu_map_init(npu, sess, map);
	if (ret)
		return ret;
	phytium_npu_import_dmabuf(npu, sess, map);
	mutex_unlock(&npu->mutex_lock);
	return 0;
}

static int phytium_npu_mm_map2cache(struct phytium_npu_dev *npu,
				    struct phytium_npu_session *sess, void *arg)
{
	return 0;
}

#define PRODUCT_ID 0x0102030405060708
#define KVERSION    0x00020000
static int
phytium_npu_get_info(struct phytium_npu_dev *npu, struct phytium_npu_session *sess, void *arg)
{
	struct npu_info sinfo;
	struct npu_info *info = &sinfo;

	info->pid = PRODUCT_ID;
	info->version = 0x0001;
	info->is_have_mmu = 1;
	info->mmu_page_size = npu->nmmu_config.page_size;
	info->mefficiency = 1;
	info->use_debug = 0;
	info->core_num = 1;
	/* HERMES-INFO-FIX: 原来全填 0 => 库认为"没有可用内存" =>
	 * 大块(27MB)分配在【发起之前】就被库自己拒绝
	 * (FATAL: failed to allocate 28459008 bytes, 但驱动侧从未收到该请求)。
	 * 填成实际可用量（CMA 1GB，留余量）。 */
	info->l1_size = 0;
	info->l3_size = vha_info_l3_size;
	info->l3_percore_size = vha_info_l3_size;
	info->clock_freq = npu->clock_freq;
	if (copy_to_user(arg, info, sizeof(*info)))
		return -EFAULT;
	return 0;
}

static long phytium_npu_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct phytium_npu_session *sess = file->private_data;
	struct phytium_npu_dev *npu;
	int retval = 0;

	/* HERMES-IOCTL-ENTRY: 无条件记录每个 ioctl（验证驱动是否收到） */
	pr_err("[VHA-IOCTL-ENTRY] cmd=%#x nr=%u sess=%p\n",
	       cmd, cmd & 0xff, sess);
	if (!sess)
		return -EINVAL;
	npu = sess->npu_dev;
	dev_dbg(npu->dev, "%s: cmd: 0x%x\n", __func__, cmd);

	/* T1': log every 'q' command with its payload (first 64B) */
	if (((cmd >> 8) & 0xff) == 0x71) {
		unsigned int isz = (cmd >> 16) & 0x3fff;
		u8 tmp[64];
		size_t n = min_t(unsigned int, sizeof(tmp), isz);
		if (n && !copy_from_user(tmp, (void __user *)arg, n)) {
			dev_info(npu->dev,
				 "[VHA-CMD] cmd=%#x dir=%u type=%#x nr=%#x size=%u\n",
				 cmd, (cmd >> 30) & 3, (cmd >> 8) & 0xff,
				 cmd & 0xff, isz);
			print_hex_dump(KERN_INFO, "[VHA-CMD]   ",
				       DUMP_PREFIX_OFFSET, 16, 1, tmp, n, false);
		}
	}

	switch (cmd) {
	case VHA_INFO_COMPAT: {
		u8 vi[0x50];
		u32 clk_khz = npu->clock_freq ? (npu->clock_freq / 1000) : 800000;

		memset(vi, 0, sizeof(vi));
		/* Pid/version block (first bytes) */
		*(u32 *)&vi[0] = (u32)PRODUCT_ID;
		*(u32 *)&vi[4] = KVERSION;
		*(u32 *)&vi[8] = 1;            /* is_have_mmu */
		*(u32 *)&vi[12] = npu->nmmu_config.page_size;
		*(u32 *)&vi[16] = 1;           /* mefficiency */
		*(u32 *)&vi[20] = 0;           /* use_debug */
		*(u32 *)&vi[24] = 1;           /* core_num (legacy offset) */
		*(u32 *)&vi[40] = clk_khz;     /* clock_freq */

		/* VHA-expected layout (reverse engineered) */
		vi[56] = 0;                    /* 0 => print clock info */
		vi[59] = 1;                    /* num cores */
		*(u32 *)&vi[72] = clk_khz;     /* NPU clock kHz */

		if (copy_to_user((void __user *)arg, vi, sizeof(vi)))
			retval = -EFAULT;
		break;
	}

	case VHA_GET_DRIVER_VERSION: {
		struct vha_driver_version ver;
		memset(&ver, 0, sizeof(ver));
		memcpy(ver.iface_magic, "c0d861123db93c890132d3b2a181f656", 32);
		memcpy(ver.version_str,
		       "NNA_API_2.0.0_DDK_3.14@REL_3.14-cl6273746", 41);
		if (copy_to_user((void __user *)arg, &ver, sizeof(ver)))
			retval = -EFAULT;
		break;
	}

	case VHA_GET_MEM_HEAPS: {
		struct vha_heap_desc heaps[16];
		memset(heaps, 0, sizeof(heaps));
		/* heap 0: unified system memory (always present) */
		heaps[0].base = 0x80000000;
		heaps[0].type = 1;   /* unified */
		heaps[0].flags = 1;  /* present */
		if (copy_to_user((void __user *)arg, heaps, sizeof(heaps)))
			retval = -EFAULT;
		break;
	}

	case VHA_ALLOC_MEM: {
		struct vha_mem_alloc req;
		struct vha_alloc_entry *e;
		unsigned long pages;

		if (copy_from_user(&req, (void __user *)arg, sizeof(req))) {
			retval = -EFAULT;
			break;
		}
		/* HERMES-ALLOC-ERR: 用 pr_err 确保输出（验证分支是否执行） */
		pr_err("[VHA-ALLOC-ERR] %s: alloc size=%llu name=%.8s\n",
		       __func__, req.size, req.name);
		/* Hermes 20th: dump raw 32B ALLOC payload to find flags
		 * (mem_attr: NOMAP=0x20 / OCM=0x20000000)
		 */
		print_hex_dump(KERN_INFO, "[VHA-ALLOC-RAW] ", DUMP_PREFIX_OFFSET,
			       16, 1, &req, sizeof(req), false);

		if (req.size == 0) {
			retval = -EINVAL;
			break;
		}
		e = kzalloc(sizeof(*e), GFP_KERNEL);
		if (!e) {
			retval = -ENOMEM;
			break;
		}
		e->npu = npu;
		/* HERMES-OVERALLOC: 计算实际分配尺寸(内部)，回报尺寸仍用 req.size */
		{
			size_t ask = PAGE_ALIGN(req.size);

			if (vha_overalloc_mul > 1 &&
			    req.size >= (u64)vha_overalloc_min) {
				ask = PAGE_ALIGN(req.size * (size_t)vha_overalloc_mul);
				dev_info(npu->dev,
					 "[VHA-OVERALLOC] req=%llu -> ask=%zu (x%d) name=%.8s\n",
					 req.size, ask, vha_overalloc_mul, req.name);
			}
			/* HERMES-OVERALLOC-EXACT: 只放大精确匹配的那块 */
			vha_report_boost = 0;
			if (vha_overalloc_exact &&
			    req.size == (u64)vha_overalloc_exact) {
				ask = PAGE_ALIGN(req.size * (size_t)(vha_overalloc_mul > 1 ? vha_overalloc_mul : 3));
				vha_report_boost = vha_overalloc_report;
				dev_info(npu->dev,
					 "[VHA-OVERALLOC-EXACT] req=%llu -> ask=%zu name=%.8s report_boost=%d\n",
					 req.size, ask, req.name, vha_report_boost);
			}
			vha_alloc_ask = ask;
		}
		if (vha_sim_mode) {
			e->kvaddr = vmalloc_user(vha_alloc_ask);
			e->dma_handle = 0;
		} else {
			/* B1: NPU-visible coherent memory */
			gfp_t g = GFP_KERNEL;
			if (vha_gfp_tune == 1)
				g = GFP_KERNEL | __GFP_RETRY_MAYFAIL;
			else if (vha_gfp_tune == 2)
				g = GFP_KERNEL | __GFP_RETRY_MAYFAIL | __GFP_NORETRY;
			/* HERMES-ALLOC-DIAG: 打印分配前后的详细信息 */
			dev_info(npu->dev,
				 "[VHA-ALLOC-DIAG] try size=%zu gfp=%#x dev=%s dma_mask=%#llx coh_mask=%#llx\n",
				 vha_alloc_ask, g, dev_name(npu->dev),
				 (unsigned long long)dma_get_mask(npu->dev),
				 (unsigned long long)npu->dev->coherent_dma_mask);
			e->kvaddr = dma_alloc_coherent(npu->dev, vha_alloc_ask,
						       &e->dma_handle, g);
			dev_info(npu->dev,
				 "[VHA-ALLOC-DIAG] ret=%p phys=%pad\n",
				 e->kvaddr, &e->dma_handle);
		}
		if (!e->kvaddr) {
			kfree(e);
			retval = -ENOMEM;
			break;
		}
		e->req_size = req.size;        /* 逻辑尺寸(库请求的) */
		e->size = vha_alloc_ask;       /* 实际分配尺寸(可能放大) */
		pages = (vha_alloc_ask + PAGE_SIZE - 1) >> PAGE_SHIFT;
		e->alloc_ord = vha_alloc_ord++;
		dev_info(npu->dev, "%s: alloc#%d size=%llu page=%lu pgoff=%lu phys=%pad kva=%p%s\n",
			 __func__, e->alloc_ord, req.size, vha_next_page,
			 (unsigned long)pages, &e->dma_handle, e->kvaddr,
			 vha_sim_mode ? " [SIM]" : " [REAL]");

		mutex_lock(&vha_alloc_mutex);
		e->start_page = vha_next_page;
		vha_next_page += pages;
		list_add_tail(&e->list, &vha_allocs);
		mutex_unlock(&vha_alloc_mutex);

		req.addr = (u64)e->start_page << PAGE_SHIFT;
		req.page_idx = (u32)e->start_page;
		/* HERMES-REPORT-BOOST-USE: 可选地把回报尺寸也改成放大后的值 */
		if (vha_report_boost)
			req.size = (u64)e->size;

		if (copy_to_user((void __user *)arg, &req, sizeof(req)))
			retval = -EFAULT;
		break;
	}

	case VHA_MAP_BUF: {
		struct vha_map_buf req;
		struct vha_alloc_entry *e;
		u32 mtype;

		if (copy_from_user(&req, (void __user *)arg, sizeof(req))) {
			retval = -EFAULT;
			break;
		}
		/* NOTE: must be computed AFTER copy_from_user (was using
		 * uninitialized req.flags -> random read-only mappings).
		 */
		mtype = (req.flags & 0x4) ? NPU_MAP_TYPE_INFERENCE
					  : NPU_MAP_TYPE_BUF;
		dev_info(npu->dev, "%s: map addr=0x%llx field8=%u flags=0x%x\n",
			 __func__, req.addr, req.field8, req.flags);

		if (vha_sim_mode)
			break;

		/* field8 == page_idx returned by VHA_ALLOC_MEM */
		mutex_lock(&vha_alloc_mutex);
		e = vha_find_by_page(req.field8);
		if (!e && req.field8)
			e = vha_find_by_page(req.field8);
		if (e && !e->mapped && e->dma_handle) {
			phytium_npu_map_phys_range(sess, e->dma_handle, req.addr,
						   PAGE_ALIGN(e->size), mtype);
			e->iova = req.addr;
			e->map_type = mtype;
			e->mapped = 1;
		} else if (!e) {
			dev_warn(npu->dev, "%s: no alloc for page_idx=%u addr=%#llx\n",
				 __func__, req.field8, req.addr);
		}
		mutex_unlock(&vha_alloc_mutex);
		break;
	}

	case VHA_BUF_OP: {
		struct vha_buf_op req;
		struct vha_alloc_entry *e;

		if (copy_from_user(&req, (void __user *)arg, sizeof(req))) {
			retval = -EFAULT;
			break;
		}
		/* 0x7109 = DnnSetupInputBuffer = NPU_SET_BUF:
		 * {fd=buf handle, set_state=NPU_BUF_*}
		 */
		mutex_lock(&vha_alloc_mutex);
		e = vha_find_by_page(req.f0);
		if (e)
			e->buf_status = req.f4;
		mutex_unlock(&vha_alloc_mutex);
		/* Hermes 2026-09-27: also print the FULL 16-byte payload --
		 * struct npu_set_buffer{fd, set_state, input_sync_fd,
		 * is_output_sync}. The bridge only used fd/state; if a
		 * model attaches an input/output sync fd (sync handshake)
		 * we need to see it here.
		 */
		{
			u32 raw[4] = { 0, 0, 0, 0 };

			if (!copy_from_user(raw, (void __user *)arg,
					   sizeof(raw)))
				dev_info(npu->dev,
					 "[VHA-SET_BUF] fd=%u state=%u in_sync_fd=%d is_output_sync=%u | raw=%#x %#x %#x %#x %s\n",
					 raw[0], raw[1], (int)raw[2], raw[3],
					 raw[0], raw[1], raw[2], raw[3],
					 e ? "ok" : "?(no buf)");
			else
				dev_info(npu->dev,
					 "[VHA-SET_BUF] fd=%u state=%u %s (raw read failed)\n",
					 req.f0, req.f4,
					 e ? "ok" : "?(no buf)");
		}
		break;
	}

	case VHA_CANCEL_SEG: {
		struct vha_buf_op req;
		if (copy_from_user(&req, (void __user *)arg, sizeof(req))) {
			retval = -EFAULT;
			break;
		}
		break;
	}

	case VHA_OUTPUT_SYNC: {
		struct vha_output_sync req;
		int fd;

		if (copy_from_user(&req, (void __user *)arg, sizeof(req))) {
			retval = -EFAULT;
			break;
		}
		/* arm: new sync fd starts NOT-ready */
		vha_sync_wq_ensure();
		atomic_set(&vha_sync_ready, 0);
		fd = anon_inode_getfd("[vha_sync]", &vha_sync_fops, NULL,
				      O_RDWR | O_CLOEXEC);
		if (fd < 0) {
			retval = fd;
			break;
		}
		req.out_fd = fd;
		if (copy_to_user((void __user *)arg, &req, sizeof(req)))
			retval = -EFAULT;
		break;
	}

	case NPU_INFO:
		retval =  phytium_npu_get_info(npu, sess, (void __user *)arg);
		break;

	case NPU_MAP2CACHE:
		retval = phytium_npu_mm_map2cache(npu, sess, (void __user *)arg);
		break;

	case NPU_MEMORY_IMPORT:
		retval = phytium_npu_mm_import(npu, sess, (void __user *)arg);
		break;

	case NPU_MEMORY_UNMAP:
		retval = phytium_npu_mm_unmap(npu, sess, (void __user *)arg);
		break;

	case NPU_SET_BUF:
		retval = phytium_npu_mm_set_buf(npu, sess, (void __user *)arg);
		break;

	case NPU_SYNC_BUF:
		retval = phytium_npu_mm_sync_buf(npu, sess, (void __user *)arg);
		break;
	case NPU_DELET_STREAM:
		retval = phytium_npu_mm_delete_stream(npu, sess, (void __user *)arg);
		break;
	case NPU_REPEAT_STREAM:
		retval = phytium_npu_mm_repeat_stream(npu, sess, (void __user *)arg);
		break;
	case NPU_DEBUG_PERF:
		retval = phytium_npu_mm_debug_perf(npu, sess, (void __user *)arg);
		break;

	/* Hermes 2026-10-01: 运行时确实会发的两条【释放类】命令。
	 * 此前落到 default ⇒ 返回 -EINVAL ⇒ 厂商库在 buffer 释放/解映射路径上
	 * 失败并无限重试（dmesg: "No this cmd to execute." 洪泛 + 21438 解映射失败）。
	 * 这里只做驱动侧簿记：把该 page_idx 标记为不再映射，成功返回 0。
	 */
	case VHA_RELEASE_PG5: {
		u32 idx = 0;
		struct vha_alloc_entry *e;

		if (copy_from_user(&idx, (void __user *)arg, sizeof(idx))) {
			retval = -EFAULT;
			break;
		}
		mutex_lock(&vha_alloc_mutex);
		mutex_unlock(&vha_alloc_mutex);
		/* HERMES-REALFREE: 真正释放（原来只清 mapped 标志） */
		vha_free_one(npu, idx);
		dev_info(npu->dev, "[VHA-REL5] page_idx=%u released(real)\n", idx);
		retval = 0;
		break;
	}

	case VHA_RELEASE_PG8: {
		u64 raw = 0;
		u32 idx;
		struct vha_alloc_entry *e;

		if (copy_from_user(&raw, (void __user *)arg, sizeof(raw))) {
			retval = -EFAULT;
			break;
		}
		idx = (u32)raw;
		mutex_lock(&vha_alloc_mutex);
		mutex_unlock(&vha_alloc_mutex);
		/* HERMES-REALFREE: 真正释放（原来只清 mapped 标志） */
		vha_free_one(npu, idx);
		dev_info(npu->dev, "[VHA-REL8] page_idx=%u released(real)\n", idx);
		retval = 0;
		break;
	}

	default:
		dev_err(npu->dev, "No this cmd to execute.");
		retval = -EINVAL;
		break;
	}

	return retval;
}

static int phytium_npu_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct vha_alloc_entry *e;
	unsigned long page = vma->vm_pgoff;
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long within;
	int ret = -ENODEV;

	pr_info("[VHA-MMAP] page=%lu size=%lu pgoff=%#lx prot=%#lx (PAGE_SHARED=%#lx)\n",
		page, size, vma->vm_pgoff,
		(unsigned long)pgprot_val(vma->vm_page_prot),
		(unsigned long)pgprot_val(PAGE_SHARED));

	mutex_lock(&vha_alloc_mutex);
	e = vha_find_by_page(page);
	if (e) {
		unsigned long pages = (e->size + PAGE_SIZE - 1) >> PAGE_SHIFT;
		unsigned long e_aligned = pages << PAGE_SHIFT;

		within = (page - e->start_page) << PAGE_SHIFT;
		if (within + size <= e_aligned) {
			if (e->dma_handle) {
				unsigned long save = vma->vm_pgoff;

				/* Hermes 2026-10-01 修正: dma_common_mmap 内部
				 * pfn = page_to_pfn(virt_to_page(cpu_addr)) + vm_pgoff，
				 * 因此 vm_pgoff 只能放"缓冲内偏移"，不能加 dma_handle
				 * （加了会重复计算 → "No such device or address"）。
				 * 长度传 VMA 自身 size；within=0 时与旧行为完全一致。
				 */
				vma->vm_pgoff = within >> PAGE_SHIFT;
				ret = dma_mmap_coherent(e->npu->dev, vma,
							e->kvaddr, e->dma_handle,
							size);
				vma->vm_pgoff = save;
			} else if (remap_vmalloc_range(vma, e->kvaddr + within, 0) == 0) {
				ret = 0;
			} else {
				ret = -EAGAIN;
			}
		} else {
			ret = -EINVAL;
		}
		if (ret == 0) {
			struct vha_mmap_rec *m = kzalloc(sizeof(*m), GFP_KERNEL);

			if (m) {
				m->page = e->start_page;
				m->uva = vma->vm_start;
				m->size = size;
				list_add_tail(&m->list, &vha_mmaps);
			}
			/* Hermes item 3 v2: App 即将读这块缓冲 —— 若本该由库拷
			 * 而库没拷, 在这里补齐（同尺寸"引擎写过"缓冲 -> 本缓冲）
			 */
			if (vha_int_fixup)
				vha_int_fixup_fill(e->npu, e);
		}
	}
	mutex_unlock(&vha_alloc_mutex);

	if (ret)
		pr_err("[phytium_npu] mmap failed: page=%lu size=%lu ret=%d\n",
		       page, size, ret);
	return ret;
}

static const struct file_operations phytium_npu_fops = {
	.owner			= THIS_MODULE,
	.read			= phytium_npu_read,
	.poll			= phytium_npu_poll,
	.write			= phytium_npu_write,
	.open			= phytium_npu_open,
	.unlocked_ioctl		= phytium_npu_ioctl,
	.compat_ioctl		= phytium_npu_ioctl,
	.mmap			= phytium_npu_mmap,
	.release		= phytium_npu_release,
};

int phytium_npu_register_misc(struct phytium_npu_dev *npudev)
{
	int ret;
	char *npu_dev_name = NULL;

	if (!npudev || !npudev->dev) {
		pr_err("%s: invalid params!\n", __func__);
		return -EINVAL;
	}

	npu_dev_name = devm_kzalloc(npudev->dev, 8, GFP_KERNEL);
	if (!npu_dev_name)
		return -ENOMEM;

	snprintf(npu_dev_name, 8, "npu%d", 0);

	dev_dbg(npudev->dev, "%s: trying to register NPU misc /dev/%s ...\n",
		__func__, npu_dev_name);

	npudev->miscdev.minor = MISC_DYNAMIC_MINOR;
	npudev->miscdev.fops = &phytium_npu_fops;
	npudev->miscdev.name = npu_dev_name;

	ret = misc_register(&npudev->miscdev);
	if (ret) {
		dev_err(npudev->dev, "%s: Unable to register NPU misc device\n", __func__);
		goto err;
	}

	dev_dbg(npudev->dev, "%s: NPU misc device registered successfully\n", __func__);
	pr_info("%s, misc:%p, npu:%p\n", __func__, &npudev->miscdev, npudev);

	return 0;

err:
	devm_kfree(npudev->dev, npu_dev_name);
	return ret;
}

int phytium_npu_unregister_misc(struct phytium_npu_dev *npudev)
{
	if (!npudev || !npudev->dev) {
		pr_err("%s: invalid params!\n", __func__);
		return -EINVAL;
	}

	misc_deregister(&npudev->miscdev);
	vha_free_allocs();

	dev_dbg(npudev->dev, "%s: NPU misc device unregistered successfully\n", __func__);

	return 0;
}

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-PUSHONREAD：响应「读一条、延后再推下一条」。

依据（静态+实测）：
  * 库接收线程 _M_run@0x36420 把 read() 到的响应当 map key 查找；
  * 查不到时走 0x366f8 → ReleaseVhaResponse ⇒ **响应被直接丢弃**；
  * 而 map 条目是 HandleResponse 时才注册（VhaDnnTask::GetSlot 给 key）；
  * 所以在 submit 完成时"一次全推"，除第一条外都会被丢掉 ⇒ 库死等。
对策：同一时刻只保留 1 条在途；库 read() 掉一条后，延 vha_rsp_on_read_ms
      再推下一条，让它落在"库已注册下一个 slot"之后。

用法: apply_pushonread.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

ANCHOR_FUNC = "static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)\n{"

HELPER = r'''/* HERMES-PUSHONREAD (2026-10-05): 响应改为「读一条、再推下一条」。
 * 根因：库接收线程在 map 里查不到该 slot 的条目时会 ReleaseVhaResponse（丢弃），
 * 而条目由 HandleResponse 注册 ⇒ submit 完成时一次性推多条，除第一条外全被丢。
 * vha_rsp_on_read=0 退回旧行为。
 */
static int vha_rsp_on_read = 1;
module_param(vha_rsp_on_read, int, 0644);
MODULE_PARM_DESC(vha_rsp_on_read, "push next response only after library reads previous (1=yes)");

static int vha_rsp_on_read_ms = 120;
module_param(vha_rsp_on_read_ms, int, 0644);
MODULE_PARM_DESC(vha_rsp_on_read_ms, "delay (ms) before pushing next response (on-read mode)");

static struct phytium_npu_session *vha_rr_sess;
static u32 vha_rr_sid;
static int vha_rr_err;
static int vha_rr_owed;			/* 还欠库多少条 */
static int vha_rr_inflight;		/* 已推、尚未被 read() 走 */
static DEFINE_MUTEX(vha_rr_lock);
static struct delayed_work vha_rr_dwork;
static int vha_rr_inited;

static void vha_rr_push_one(void)
{
	u32 slot;

	mutex_lock(&vha_rr_lock);
	if (vha_rr_owed <= 0 || vha_rr_inflight || !vha_rr_sess) {
		mutex_unlock(&vha_rr_lock);
		return;
	}
	slot = vha_alloc_slot();
	vha_rr_owed--;
	vha_rr_inflight = 1;
	/* 在锁内推送：vha_push_response_now 不做阻塞操作 */
	vha_push_response_now(vha_rr_sess, vha_rr_sid, vha_rr_err, slot);
	mutex_unlock(&vha_rr_lock);
}

static void vha_rr_work(struct work_struct *w)
{
	vha_rr_push_one();
}

static void vha_rr_ensure(void)
{
	if (vha_rr_inited)
		return;
	vha_rr_inited = 1;
	INIT_DELAYED_WORK(&vha_rr_dwork, vha_rr_work);
}

/* 库刚 read() 走一条 ⇒ 释放"在途"并安排下一条 */
static void vha_rr_on_consumed(void)
{
	if (!vha_rsp_on_read)
		return;
	vha_rr_ensure();
	mutex_lock(&vha_rr_lock);
	vha_rr_inflight = 0;
	mutex_unlock(&vha_rr_lock);
	if (vha_rsp_on_read_ms > 0)
		schedule_delayed_work(&vha_rr_dwork,
				      msecs_to_jiffies(vha_rsp_on_read_ms));
	else
		vha_rr_push_one();
}

'''

OLD_PUSH_HEAD = """	if (!vha_push_enable) {
		dev_info(sess->npu_dev->dev,
			 "[VHA-NOPUSH] 自己的推送已关闭 sid=%#x\\n", sid);
		return;
	}
"""

NEW_PUSH_HEAD = OLD_PUSH_HEAD + """	if (vha_rsp_on_read) {
		vha_rr_ensure();
		mutex_lock(&vha_rr_lock);
		vha_rr_sess = sess;
		vha_rr_sid = sid;
		vha_rr_err = err_no;
		vha_rr_owed++;
		mutex_unlock(&vha_rr_lock);
		vha_rr_push_one();
		return;
	}
"""

OLD_READ = """	list_del(&rsp->stream_rsp_list_entry);
	atomic_inc(&vha_rsp_served);
	ret = ret_len;"""

NEW_READ = """	list_del(&rsp->stream_rsp_list_entry);
	atomic_inc(&vha_rsp_served);
	/* HERMES-PUSHONREAD: 库消费掉一条 ⇒ 安排推下一条 */
	vha_rr_on_consumed();
	ret = ret_len;"""


READ_ANCHOR = "static ssize_t phytium_npu_read(struct file *file, char __user *buf, size_t len, loff_t *ppos)"

FWD_DECL = """/* HERMES-PUSHONREAD: 前置声明（定义在 vha_push_response 之前） */
static void vha_rr_on_consumed(void);

"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_pushonread.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-PUSHONREAD" in src:
        print("[SKIP] 已打过 HERMES-PUSHONREAD")
        return 0
    n1 = src.count(ANCHOR_FUNC)
    n2 = src.count(OLD_PUSH_HEAD)
    n3 = src.count(OLD_READ)
    n4 = src.count(READ_ANCHOR)
    print("[INFO] 锚点: func=%d push_head=%d read=%d read_func=%d (期望 1/1/1/1)" % (n1, n2, n3, n4))
    if n1 != 1 or n2 != 1 or n3 != 1 or n4 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_prepushonread_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)

    out = src.replace(ANCHOR_FUNC, HELPER + ANCHOR_FUNC)
    out = out.replace(OLD_PUSH_HEAD, NEW_PUSH_HEAD)
    out = out.replace(OLD_READ, NEW_READ)
    out = out.replace(READ_ANCHOR, FWD_DECL + READ_ANCHOR)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-PUSHONREAD")
    return 0


if __name__ == "__main__":
    sys.exit(main())

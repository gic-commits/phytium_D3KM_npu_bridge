#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-RSPCYCLE：用定时器循环推送响应 key（1,3,5,…,max 循环）。

动机（实测）：库接收线程在 map 里查不到该 id 的条目就 ReleaseVhaResponse（丢弃），
而条目由 HandleResponse 注册 ⇒ "每条提交推一条"的时序必然踩空（实测 5/6 被丢）。
改为与提交解耦的**周期性循环推送**：每隔 vha_rsp_cycle_ms 推一条，key 按
vha_rsp_slot / vha_rsp_slot_step / vha_rsp_slot_max 循环 ⇒ 库何时注册都能在
一个周期内等到对应 key 的响应。

vha_rsp_cycle_ms=0（默认）时退回原来的"提交时推送"。

用法: apply_rspcycle.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

ANCHOR = "static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)\n{"

HELPER = r'''/* HERMES-RSPCYCLE (2026-10-05): 周期性循环推送响应 key（与提交解耦）。
 * 依据：库对"map 里尚无该 id 条目"的响应会 ReleaseVhaResponse 丢弃（实测 5/6），
 * 而条目是 HandleResponse 时才注册 ⇒ 与提交同步推送必然踩空。
 */
static int vha_rsp_cycle_ms;
module_param(vha_rsp_cycle_ms, int, 0644);
MODULE_PARM_DESC(vha_rsp_cycle_ms, "periodically push responses every N ms (0=off, use submit-time push)");

static struct timer_list vha_cyc_timer;
static int vha_cyc_inited;
static struct phytium_npu_session *vha_cyc_sess;
static u32 vha_cyc_sid;
static int vha_cyc_err;
static DEFINE_MUTEX(vha_cyc_lock);

static void vha_cyc_fn(struct timer_list *t)
{
	struct phytium_npu_session *s;
	u32 sid;
	int err;

	mutex_lock(&vha_cyc_lock);
	s = vha_cyc_sess;
	sid = vha_cyc_sid;
	err = vha_cyc_err;
	mutex_unlock(&vha_cyc_lock);
	if (!s)
		return;
	vha_push_response_now(s, sid, err, vha_alloc_slot());
	if (vha_rsp_cycle_ms > 0)
		mod_timer(&vha_cyc_timer,
			  jiffies + msecs_to_jiffies(vha_rsp_cycle_ms));
}

static void vha_cyc_start(void)
{
	if (vha_rsp_cycle_ms <= 0)
		return;
	if (!vha_cyc_inited) {
		vha_cyc_inited = 1;
		timer_setup(&vha_cyc_timer, vha_cyc_fn, 0);
	}
	if (!timer_pending(&vha_cyc_timer))
		mod_timer(&vha_cyc_timer,
			  jiffies + msecs_to_jiffies(vha_rsp_cycle_ms));
}

static void vha_cyc_stop(void)
{
	if (vha_cyc_inited)
		del_timer_sync(&vha_cyc_timer);
	mutex_lock(&vha_cyc_lock);
	vha_cyc_sess = NULL;
	mutex_unlock(&vha_cyc_lock);
}

'''

OLD_PUSH = """	if (!vha_push_enable) {
		dev_info(sess->npu_dev->dev,
			 "[VHA-NOPUSH] 自己的推送已关闭 sid=%#x\\n", sid);
		return;
	}
"""

NEW_PUSH = OLD_PUSH + """	if (vha_rsp_cycle_ms > 0) {
		/* 循环推送模式：只记录上下文并启动定时器，推送由定时器驱动 */
		mutex_lock(&vha_cyc_lock);
		vha_cyc_sess = sess;
		vha_cyc_sid = sid;
		vha_cyc_err = err_no;
		mutex_unlock(&vha_cyc_lock);
		vha_cyc_start();
		return;
	}
"""

# 在每次新执行（OUTPUT_SYNC arm）时重置循环序号并重启定时器
OLD_ARM = """		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);"""
NEW_ARM = """		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);
		vha_cyc_stop();"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_rspcycle.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-RSPCYCLE" in src:
        print("[SKIP] 已打过 HERMES-RSPCYCLE")
        return 0
    n1 = src.count(ANCHOR)
    n2 = src.count(OLD_PUSH)
    n3 = src.count(OLD_ARM)
    print("[INFO] 锚点: func=%d push=%d arm=%d (期望 1/1/1)" % (n1, n2, n3))
    if n1 != 1 or n2 != 1 or n3 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_prercycle_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(ANCHOR, HELPER + ANCHOR)
    out = out.replace(OLD_PUSH, NEW_PUSH)
    out = out.replace(OLD_ARM, NEW_ARM)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-RSPCYCLE")
    return 0


if __name__ == "__main__":
    sys.exit(main())

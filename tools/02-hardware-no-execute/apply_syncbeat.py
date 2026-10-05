#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 output-sync fd 加"心跳"：定时调用 vha_sync_signal()，让它持续就绪。
背景：实测接收线程卡在 GetVhaResponse 的 poll(nfds=2)（响应设备 + sync fd），
      而响应已被全部读走 ⇒ 库等的是 sync 就绪。若库再起，说明 sync 就是卡点。
      诊断用：vha_sync_beat_ms=0 关闭（默认）。

用法: apply_syncbeat.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

ANCHOR = "static __poll_t vha_sync_poll(struct file *file, poll_table *wait)"

HELPER = r'''/* HERMES-SYNCBEAT (2026-10-05): 诊断用 ── 定时把 output-sync fd 置为就绪。
 * 目的：验证「库在等 sync 就绪」这一假设。vha_sync_beat_ms=0 关闭（默认）。
 */
static struct timer_list vha_sync_beat_timer;
static int vha_sync_beat_ms;
module_param(vha_sync_beat_ms, int, 0644);
MODULE_PARM_DESC(vha_sync_beat_ms, "signal output-sync fd every N ms (0=off, diagnostic)");

static void vha_sync_beat_fn(struct timer_list *t)
{
	vha_sync_signal();
	if (vha_sync_beat_ms > 0)
		mod_timer(&vha_sync_beat_timer,
			  jiffies + msecs_to_jiffies(vha_sync_beat_ms));
}

static void vha_sync_beat_ensure(void)
{
	if (vha_sync_beat_ms <= 0)
		return;
	if (timer_pending(&vha_sync_beat_timer))
		return;
	timer_setup(&vha_sync_beat_timer, vha_sync_beat_fn, 0);
	mod_timer(&vha_sync_beat_timer,
		  jiffies + msecs_to_jiffies(vha_sync_beat_ms));
}

'''

# 在 OUTPUT_SYNC 的 arm 处启动心跳
OLD_ARM = """		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);"""
NEW_ARM = """		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);
		vha_sync_beat_ensure();"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_syncbeat.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-SYNCBEAT" in src:
        print("[SKIP] 已打过 HERMES-SYNCBEAT")
        return 0
    if src.count(ANCHOR) != 1:
        print("[FAIL] 找不到 vha_sync_poll")
        return 3
    if src.count(OLD_ARM) != 1:
        print("[FAIL] 找不到 OUTPUT_SYNC arm 片段（需先打 SLOTRESET）")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_presyncbeat_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(ANCHOR, HELPER + ANCHOR).replace(OLD_ARM, NEW_ARM)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SYNCBEAT")
    return 0


if __name__ == "__main__":
    sys.exit(main())

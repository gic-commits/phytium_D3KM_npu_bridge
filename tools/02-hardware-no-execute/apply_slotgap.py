#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slot 序号改为“按静默间隔重置” + 推送计数。
依据：库每次执行都从 slot=1 开始等（实测 [HR-CALL] = 1,3,5,7,9…），
      但 LOAD/INFER 两阶段之间只靠 OUTPUT_SYNC 标记不可靠（实测仍差一档）。
      改用时间判据：两次推送间隔 > vha_slot_gap_ms 视为“新一次执行”，序号归零。
      LOAD→INFER 间隔为秒级，段间间隔仅数十 ms，可稳定区分。

用法: apply_slotgap.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

ANCHOR = "static u32 vha_alloc_slot(void)\n"

OLD_BODY = """static u32 vha_alloc_slot(void)
{
	int n;
	u32 s;

	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;

	n = atomic_inc_return(&vha_rsp_slot_seq) - 1;	/* 0,1,2,... */
	s = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;
"""

NEW_BODY = """/* HERMES-SLOTGAP: 距上次推送超过 vha_slot_gap_ms 视为“新一次执行”，序号归零。 */
static u64 vha_last_push_ns;
static int vha_slot_gap_ms = 200;
module_param(vha_slot_gap_ms, int, 0644);
MODULE_PARM_DESC(vha_slot_gap_ms, "reset slot sequence if idle gap exceeds this (ms), 0=off");

static atomic_t vha_push_cnt = ATOMIC_INIT(0);

static u32 vha_alloc_slot(void)
{
	u64 now = ktime_get_ns();
	int n;
	u32 s;

	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;

	if (vha_slot_gap_ms > 0 && vha_last_push_ns &&
	    now - vha_last_push_ns > (u64)vha_slot_gap_ms * 1000000ULL) {
		atomic_set(&vha_rsp_slot_seq, 0);
		pr_info("[VHA-SLOTGAP] 静默 %llu ms > %d ms ⇒ 序号归零\\n",
			(now - vha_last_push_ns) / 1000000ULL, vha_slot_gap_ms);
	}
	vha_last_push_ns = now;
	atomic_inc(&vha_push_cnt);

	n = atomic_inc_return(&vha_rsp_slot_seq) - 1;	/* 0,1,2,... */
	s = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;
"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotgap.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-SLOTGAP" in src:
        print("[SKIP] 已打过 HERMES-SLOTGAP")
        return 0
    if src.count(OLD_BODY) != 1:
        print("[FAIL] vha_alloc_slot 原型不匹配 (%d)" % src.count(OLD_BODY))
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preslotgap_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD_BODY, NEW_BODY)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SLOTGAP")
    return 0


if __name__ == "__main__":
    sys.exit(main())

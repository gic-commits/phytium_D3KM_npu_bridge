#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-ALLOCDBG2：把 slot 序列的"入口值 + 复位点"全部打出来，钉死首值来源。

背景（第八轮-26）：实测首次推送 `n=1`（应为 0），但全程只记录到 3 次分配
⇒ 序列在首推前被加过/置过 1 次且无记录。

本补丁三处加日志：
  1. `vha_alloc_slot()` 入口（在 step<=0 提前返回**之前**）—— 打印进入时的 seq 与调用者，
     这样连"提前返回、不分配"的调用也看得见。
  2. 静默间隔复位点（`vha_slot_gap_ms` 分支）。
  3. `VHA_OUTPUT_SYNC` 的复位点（`vha_slot_reset_on_sync` 分支）。

用法: apply_allocdbg2.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

ENTRY_OLD = """	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;"""
ENTRY_NEW = """	/* HERMES-ALLOCDBG2: 入口值 + 调用者（在提前返回之前） */
	pr_info(\"[VHA-ALLOC2-ENTER] seq=%d step=%d slot0=%d caller=%pS\\n\",
		atomic_read(&vha_rsp_slot_seq), vha_rsp_slot_step,
		vha_rsp_slot, __builtin_return_address(0));
	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;"""

GAP_OLD = """		atomic_set(&vha_rsp_slot_seq, 0);
		pr_info(\"[VHA-SLOTGAP] 静默 %llu ms > %d ms ⇒ 序号归零\\n\",
			(now - vha_last_push_ns) / 1000000ULL, vha_slot_gap_ms);"""
GAP_NEW = """		atomic_set(&vha_rsp_slot_seq, 0);
		pr_info(\"[VHA-SLOTGAP] ★复位 seq=0（静默 %llu ms > %d ms） caller=%pS\\n\",
			(now - vha_last_push_ns) / 1000000ULL, vha_slot_gap_ms,
			__builtin_return_address(0));"""

SYNC_OLD = """		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);"""
SYNC_NEW = """		if (vha_slot_reset_on_sync) {
			/* HERMES-ALLOCDBG2: OUTPUT_SYNC 复位点 */
			pr_info(\"[VHA-SLOTRESET] ★OUTPUT_SYNC 复位 seq 0（复位前=%d）\\n\",
				atomic_read(&vha_rsp_slot_seq));
			atomic_set(&vha_rsp_slot_seq, 0);
		}"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_allocdbg2.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-ALLOCDBG2" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("entry", ENTRY_OLD), ("gap", GAP_OLD), ("sync", SYNC_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_prealloc2_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(ENTRY_OLD, ENTRY_NEW).replace(GAP_OLD, GAP_NEW).replace(SYNC_OLD, SYNC_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-ALLOCDBG2")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-ALLOCDBG：在 vha_alloc_slot() 里打印调用点符号名与返回的 slot。

目的：查清"推理首推为什么是 2 而不是 1" —— 即哪条路径在推理前多消耗了一次分配。
`%pS` 会把 return address 解析成符号名，一眼看出调用者。

用法: apply_allocdbg.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """	n = atomic_inc_return(&vha_rsp_slot_seq) - 1;	/* 0,1,2,... */
	s = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;"""

NEW = """	n = atomic_inc_return(&vha_rsp_slot_seq) - 1;	/* 0,1,2,... */
	s = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;
	/* HERMES-ALLOCDBG: 调用点 + 序号，用于定位"推理首推为 2"的多余消耗 */
	pr_info(\"[VHA-ALLOC] caller=%pS n=%d slot=%u step=%d gap_ms=%d\\n\",
		__builtin_return_address(0), n, s, vha_rsp_slot_step,
		vha_slot_gap_ms);"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_allocdbg.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-ALLOCDBG" in src:
        print("[SKIP] 已打过")
        return 0
    n = src.count(OLD)
    print("[INFO] 锚点=%d (期望 1)" % n)
    if n != 1:
        print("[FAIL] 锚点不唯一")
        return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_preallocdbg_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src.replace(OLD, NEW))
    print("[OK  ] 已打补丁：HERMES-ALLOCDBG")
    return 0


if __name__ == "__main__":
    sys.exit(main())

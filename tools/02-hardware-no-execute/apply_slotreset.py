#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 VHA_OUTPUT_SYNC(arm) 时把响应 slot 计数器清零。
依据：实测库每次执行都从 slot=1 开始等（[HR-CALL#1] 要 1、#2 要 3），
      而 LOAD 阶段已消耗掉 1,3,5 ⇒ 首次 INFER 推的是 7 ⇒ 库等 1 等不到。
      OUTPUT_SYNC 是库"开始一次新执行"的天然标记（arm 在新 sync fd 上）。

用法: apply_slotreset.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """		/* arm: new sync fd starts NOT-ready */
		vha_sync_wq_ensure();
		atomic_set(&vha_sync_ready, 0);"""

NEW = """		/* arm: new sync fd starts NOT-ready */
		vha_sync_wq_ensure();
		atomic_set(&vha_sync_ready, 0);
		/* HERMES-SLOTRESET (2026-10-05): 库每次执行都从 slot=1 重新等
		 * （实测 HandleResponse 依次等 1,3,5…）。若不清零，LOAD 阶段
		 * 消耗掉的序号会让本次执行的首条响应从中间值开始 ⇒ 库永远等不到。
		 */
		if (vha_slot_reset_on_sync)
			atomic_set(&vha_rsp_slot_seq, 0);"""

PARAM_ANCHOR = "static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)"
PARAM_DEF = """/* HERMES-SLOTRESET: 是否在库 arm OUTPUT_SYNC 时清零 slot 序号 */
static int vha_slot_reset_on_sync = 1;
module_param(vha_slot_reset_on_sync, int, 0644);
MODULE_PARM_DESC(vha_slot_reset_on_sync, "reset response slot sequence on VHA_OUTPUT_SYNC arm");

"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotreset.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-SLOTRESET" in src:
        print("[SKIP] 已打过 HERMES-SLOTRESET")
        return 0
    if src.count(OLD) != 1:
        print("[FAIL] arm 代码片段不唯一 (%d)" % src.count(OLD))
        return 3
    if src.count(PARAM_ANCHOR) != 1:
        print("[FAIL] 找不到 vha_push_response 函数头")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preslotreset_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)

    out = src.replace(OLD, NEW)
    out = out.replace(PARAM_ANCHOR, PARAM_DEF + PARAM_ANCHOR)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SLOTRESET")
    return 0


if __name__ == "__main__":
    sys.exit(main())

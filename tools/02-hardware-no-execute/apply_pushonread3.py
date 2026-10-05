#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PUSHONREAD-FIX2：在库 arm OUTPUT_SYNC（=新一次执行）时把 on-read 状态清零。
问题：vha_rr_kicked / vha_rr_inflight / vha_rr_owed 是模块级静态变量，
      只在加载时初始化 ⇒ 第一次执行之后，后续运行永不再推响应
      （实测：第二次跑探针时"推的 slot"为空、库解出 key=0、直接挂死；
        这也是 mobilenet 回归失败的原因）。

用法: apply_pushonread3.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """		vha_sync_beat_ensure();"""

NEW = """		vha_sync_beat_ensure();
		/* HERMES-PUSHONREAD-FIX2: 新一次执行 —— 重置 on-read 状态机，
		 * 否则 vha_rr_kicked 会一直是 1，之后的运行再也不推第一条响应。 */
		if (vha_rsp_on_read) {
			mutex_lock(&vha_rr_lock);
			vha_rr_kicked = 0;
			vha_rr_inflight = 0;
			vha_rr_owed = 0;
			mutex_unlock(&vha_rr_lock);
		}"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_pushonread3.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-PUSHONREAD-FIX2" in src:
        print("[SKIP] 已打过 PUSHONREAD-FIX2")
        return 0
    n = src.count(OLD)
    print("[INFO] 锚点 vha_sync_beat_ensure=%d (期望 1)" % n)
    if n != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_prepor3_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src.replace(OLD, NEW))
    print("[OK  ] 已打补丁：HERMES-PUSHONREAD-FIX2")
    return 0


if __name__ == "__main__":
    sys.exit(main())

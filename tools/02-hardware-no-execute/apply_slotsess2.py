#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-SLOTSESS2：把会话切换复位 + 入口探针加进 `vha_push_response()`。

第八轮-28 实测：真正调用 `vha_alloc_slot()` 的是 `vha_push_response`（`caller=` 已证实），
而 SLOTSESS 只加在了 `vha_rr_push_one` ⇒ 从未生效。

本补丁在 `vha_push_response()` 入口加：
  1. `vha_slot_session_check(sess);`  —— 会话切换即复位序号
  2. `[VHA-PUSH-ENTER]` 探针 —— 打印每次推送入口的会话与当前序号（观察复位是否发生）

用法: apply_slotsess2.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)
{
	struct vha_defer_ctx *d;
	int first;
"""

NEW = """static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)
{
	struct vha_defer_ctx *d;
	int first;

	/* HERMES-SLOTSESS2: 实测真正的 slot 分配发生在本函数
	 * ⇒ 会话切换（= 新一次推理）时把序号归零，对齐库"任务从 1 重新编号"。 */
	vha_slot_session_check(sess);
	pr_info(\"[VHA-PUSH-ENTER] sess=%p seq=%d sid=%#x\\n\",
		(void *)sess, atomic_read(&vha_rsp_slot_seq), sid);
"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotsess2.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-SLOTSESS2" in src:
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
    bak = path + ".bak_preslotsess2_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src.replace(OLD, NEW))
    print("[OK  ] 已打补丁：HERMES-SLOTSESS2")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-SLOTONPUSH：slot 序号只在"真正入队推送"时递增。

动机（第八轮34）：
  库会连续登记奇数键等待 1,3,5,7,9…；实测当键序列对上时管线从"5 等 4 唤"推进到
  "9 等 8 唤"。但 `vha_alloc_slot()` 会被比真实推送更多的调用消费序号（幻影分配），
  导致第一条真正推送的键带固定偏移（如 slot=1 时实际推 3）。

做法：
  - `vha_alloc_slot()` 在 vha_slot_on_push=1 时**不再自增**，直接返回 0（占位）
  - `vha_push_response_now()` 在**入队时**才 `atomic_inc_return()` 计算真实键

用法: apply_slotonpush.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

DECL_OLD = """static u32 vha_alloc_slot(void)
{"""
DECL_NEW = """/* HERMES-SLOTONPUSH: 1 = 序号只在真正入队推送时递增（消除幻影分配吃号） */
static int vha_slot_on_push = 0;
module_param(vha_slot_on_push, int, 0644);
MODULE_PARM_DESC(vha_slot_on_push, "1 = increment slot seq only on real push");

static u32 vha_alloc_slot(void)
{"""

ALLOC_OLD = """	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;"""
ALLOC_NEW = """	if (vha_slot_on_push)   /* HERMES-SLOTONPUSH: 真实推送时才递增 */
		return 0;
	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;"""

PUSH_OLD = """static void vha_push_response_now(struct phytium_npu_session *sess, u32 sid,
				  int err_no, u32 slot)
{
"""
PUSH_NEW = """static void vha_push_response_now(struct phytium_npu_session *sess, u32 sid,
				  int err_no, u32 slot)
{
	if (vha_slot_on_push) {   /* HERMES-SLOTONPUSH: 入队时才算真实键 */
		int n = atomic_inc_return(&vha_rsp_slot_seq) - 1;

		slot = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;
	}
"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotonpush.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-SLOTONPUSH" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("decl", DECL_OLD), ("alloc", ALLOC_OLD), ("push", PUSH_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 三个锚点唯一，可打补丁")
        return 0
    bak = path + ".bak_preslotonpush_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = (src.replace(DECL_OLD, DECL_NEW, 1)
              .replace(ALLOC_OLD, ALLOC_NEW, 1)
              .replace(PUSH_OLD, PUSH_NEW, 1))
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SLOTONPUSH")
    return 0


if __name__ == "__main__":
    sys.exit(main())

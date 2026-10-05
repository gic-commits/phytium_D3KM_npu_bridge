#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让响应 [+2] 的 slot 按“每次推送全局单调递增”分配。
判据：库的 VhaDnnTask::GetSlot() 序列是 1,3,5,7…（实测 [HR-CALL]），
      而原实现 delay_ms=0 时恒推 vha_rsp_slot(=1)，重放时多链交错 ⇒ 乱序。

用法:
  apply_slotseq.py <phytium_npu_uapi.c>          # 打补丁
  apply_slotseq.py <phytium_npu_uapi.c> --check  # 只检查
"""
import sys, os, shutil, time

HELPER = r'''
/* HERMES-SLOTSEQ (2026-10-05): 响应 [+2] 的 slot 必须【每次推送全局单调递增】。
 * 依据：库侧 VhaDnnTask::GetSlot() 的序列被 HandleResponse(observer, slot, cb, 0) 逐条等待，
 * 实测为 1,3,5,7…（奇数步长 2）。原实现只在“延迟重放链”里递增，且多条链互相交错，
 * delay_ms=0 时更是恒推同一个值 ⇒ 库第 2 条起就等不到，整条推理链死等。
 * 现改为：step>0 时按全局计数器分配 slot（1,3,5,…）；step<=0 时维持旧行为（常量）。
 */
static atomic_t vha_rsp_slot_seq = ATOMIC_INIT(0);

static u32 vha_alloc_slot(void)
{
	int n;
	u32 s;

	if (vha_rsp_slot_step <= 0)
		return (u32)vha_rsp_slot;

	n = atomic_inc_return(&vha_rsp_slot_seq) - 1;	/* 0,1,2,... */
	s = (u32)vha_rsp_slot + (u32)n * (u32)vha_rsp_slot_step;

	if (vha_rsp_slot_max > 0 && s > (u32)vha_rsp_slot_max) {
		u32 span = (u32)vha_rsp_slot_max - (u32)vha_rsp_slot + 1;
		s = (u32)vha_rsp_slot +
		    ((u32)n * (u32)vha_rsp_slot_step) % span;
	}
	return s;
}
'''

OLD_FUNC = "static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)\n{"
SUB1 = "vha_push_response_now(sess, sid, err_no, (u32)vha_rsp_slot);"
NEW1 = "vha_push_response_now(sess, sid, err_no, vha_alloc_slot());"
SUB2 = "\td->slot = (u32)vha_rsp_slot;"
NEW2 = "\td->slot = vha_alloc_slot();"


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotseq.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-SLOTSEQ" in src:
        print("[SKIP] 已打过 HERMES-SLOTSEQ 补丁")
        return 0

    n1 = src.count(SUB1)
    n2 = src.count(SUB2)
    print("[INFO] 目标出现次数: push_now=%d  d->slot=%d  (期望 2 / 1)" % (n1, n2))
    if n1 != 2 or n2 != 1:
        print("[FAIL] 出现次数与预期不符，中止（避免误改）")
        return 3
    if src.count(OLD_FUNC) != 1:
        print("[FAIL] 找不到唯一的 vha_push_response 函数头，中止")
        return 3

    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preslotseq_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)

    out = src.replace(OLD_FUNC, HELPER.strip("\n") + "\n\n" + OLD_FUNC)
    out = out.replace(SUB1, NEW1)
    out = out.replace(SUB2, NEW2)

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SLOTSEQ (slot 全局单调递增)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-SLOTSESS：会话切换时复位响应序号（对齐库的"每次推理任务从 1 重排"）。

★★ 依据（第八轮-26/27 实测）★★
  库的任务编号在**每次推理**都从 1 重新开始：
      mobilenet ：每次推理 task->slot = 1（多次推理 → 1,1,1…）
      sensevoice：一次推理内 task->slot = 1,2,3,4,5…（HandleResponse 只对奇数注册）
  而驱动侧实测到：**每次推理都会用一个新的 session**（sess 指针/id 变化），
  一次推理内的多次提交共用同一个 session。

  ⇒ 因此"会话变了"就是"新一次推理开始"的可靠信号。
     在会话切换时把 slot 序号归零，即可让
        mobilenet 每次推理首推 = 1（对齐库的 1）
        sensevoice 一次推理内 = 1,2,3,4,5（对齐库的任务编号）

  这同时解释了此前"首次进入 vha_alloc_slot() 时 seq 已是 1"的谜团
  （那 1 是上一次推理/加载留下的），并取代不可靠的时间间隔复位。

参数 vha_slot_reset_on_session（默认 1，0644）可一键对照。

用法: apply_slotsess.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

# 1) 定义 + 参数（挂在 SLOTRESET 参数之后）
DECL_OLD = """static int vha_slot_reset_on_sync = 1;
module_param(vha_slot_reset_on_sync, int, 0644);
MODULE_PARM_DESC(vha_slot_reset_on_sync, "reset response slot sequence on VHA_OUTPUT_SYNC arm");"""
DECL_NEW = """static int vha_slot_reset_on_sync = 1;
module_param(vha_slot_reset_on_sync, int, 0644);
MODULE_PARM_DESC(vha_slot_reset_on_sync, "reset response slot sequence on VHA_OUTPUT_SYNC arm");

/* HERMES-SLOTSESS: 库每次推理都用新 session，一次推理内共用同一 session
 * ⇒ 会话切换 = 新一次推理 ⇒ 序号归零，对其"任务从 1 重新编号"。 */
static int vha_slot_reset_on_session = 1;
module_param(vha_slot_reset_on_session, int, 0644);
MODULE_PARM_DESC(vha_slot_reset_on_session, "reset response slot sequence when session changes");

static struct phytium_npu_session *vha_slot_last_sess;

static void vha_slot_session_check(struct phytium_npu_session *sess)
{
	if (!vha_slot_reset_on_session || !sess)
		return;
	if (sess != vha_slot_last_sess) {
		pr_info("[VHA-SLOTSESS] ★会话切换 %p -> %p ⇒ 序号归零（复位前=%d）\\n",
			vha_slot_last_sess, sess,
			atomic_read(&vha_rsp_slot_seq));
		vha_slot_last_sess = sess;
		atomic_set(&vha_rsp_slot_seq, 0);
	}
}"""

# 2) rr 推送路径（实测实际走这条）
RR_OLD = """	slot = vha_alloc_slot();
	vha_rr_owed--;"""
RR_NEW = """	vha_slot_session_check(vha_rr_sess);
	slot = vha_alloc_slot();
	vha_rr_owed--;"""


def do(path, pairs, tag, check):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-SLOTSESS" in src:
        print("[SKIP] %s 已打过" % tag)
        return True
    for old, new in pairs:
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return False
    if check:
        return True
    for old, new in pairs:
        src = src.replace(old, new)
    bak = path + ".bak_preslotsess_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)
    print("[OK  ] %s 已打补丁" % tag)
    return True


def main():
    check = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print("用法: apply_slotsess.py <uapi.c> [--check]")
        return 2
    ok = do(args[0], [(DECL_OLD, DECL_NEW), (RR_OLD, RR_NEW)], "uapi.c", check)
    if check:
        print("[CHECK] 可打补丁" if ok else "[CHECK] 有问题")
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())

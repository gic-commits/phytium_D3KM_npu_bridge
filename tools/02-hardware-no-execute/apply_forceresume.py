#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-FORCERESUME：每次提交前强制走一次真正的 resume（硬件重新初始化）。

实测依据（同一 worker 连跑，严格隔次失败）：
    submit1 ✓   submit2 ✗   submit3 ✓   submit4 ✗
  且 MMUDBG 显示**同一个会话**也是"一次成功一次失败"⇒ 与"哪个会话"无关。

机制（phytium_npu_common.c:247）：
    void phytium_npu_try_resume_work(npudev)
    {
        if (power_status == NPU_STATE_ON)       cancel_delayed_work_sync(...);  /* 只取消挂起 */
        else if (power_status == NPU_STATE_OFF) { phytium_npu_resume(npudev);  /* ★真正重新初始化 */
                                                  power_status = NPU_STATE_ON; }
    }
  厂商节律：完成后 schedule_suspend(NPU_AUTO_SUSPEND_TIMEOUT=5000) → 5s 内无新提交才真挂起。
  我们连续提交间隔 << 5s ⇒ 永不挂起 ⇒ 第 2 次提交用的是"没重新初始化"的硬件 ⇒ 不执行；
  而它超时等满 5s ⇒ 期间挂起生效 ⇒ 第 3 次提交 resume 后又能跑 ⇒ 表现为"隔次失败"。

修法：提交前把 power_status 置 OFF 再调 try_resume_work，强制走 resume 路径。
vha_force_resume_each_submit=0 退回旧行为。

用法: apply_forceresume.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """			phytium_npu_try_resume_work(npu);"""

NEW = """			/* HERMES-FORCERESUME: 连续提交时硬件不会重新初始化（挂起是 5s 延时触发），
			 * 导致第 2 次提交不执行。此处强制走一次 resume 路径。 */
			if (vha_force_resume_each_submit) {
				int ps_old = npu->power_status;

				npu->power_status = NPU_STATE_OFF;
				phytium_npu_try_resume_work(npu);
				dev_info(npu->dev,
					 "[VHA-FORCERESUME] power_status %d -> %d\\n",
					 ps_old, npu->power_status);
			} else {
				phytium_npu_try_resume_work(npu);
			}"""

PARAM_ANCHOR = "static int vha_clr_status_before_start = 1;"
PARAM_NEW = """/* HERMES-FORCERESUME (2026-10-05): 每轮提交前强制 resume（硬件重新初始化） */
static int vha_force_resume_each_submit = 1;
module_param(vha_force_resume_each_submit, int, 0644);
MODULE_PARM_DESC(vha_force_resume_each_submit, "force phytium_npu_resume() before every submit");

static int vha_clr_status_before_start = 1;"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_forceresume.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-FORCERESUME" in src:
        print("[SKIP] 已打过 HERMES-FORCERESUME")
        return 0
    n1 = src.count(OLD)
    n2 = src.count(PARAM_ANCHOR)
    print("[INFO] 锚点: try_resume_work=%d param=%d (期望 1/1)" % (n1, n2))
    if n1 != 1 or n2 != 1:
        print("[FAIL] 锚点不唯一，中止（注意 try_resume_work 可能有多处调用）")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preforceresume_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD, NEW).replace(PARAM_ANCHOR, PARAM_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-FORCERESUME")
    return 0


if __name__ == "__main__":
    sys.exit(main())

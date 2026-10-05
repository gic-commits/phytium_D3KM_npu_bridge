#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-SUSPENDAFTER：每次提交完成后调 phytium_npu_schedule_suspend（厂商节律）。

依据：
  * 厂商 phytium_npu_inference_complete()（common.c:586）在推送响应后调
    phytium_npu_schedule_suspend(npudev, NPU_AUTO_SUSPEND_TIMEOUT)；
  * 厂商 phytium_npu_submit_stream() 开头调 phytium_npu_try_resume_work()。
    ⇒ 每轮"挂起 → 下轮 resume 重新初始化"。
  * 我们的 uapi.c 里 grep 不到任何 schedule_suspend ⇒ 核一直停在上一轮状态，
    下轮 try_resume_work 是空操作 ⇒ 实测第 2 次提交 done=0（硬件不执行）。
  * 写 NPU_CH0_STATUS 清位无效（实测 0x1->0x1、且值单调递增 1,3,5,7 ⇒ 非 W1C）。

用法: apply_suspendafter.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """\t\t\t\t\tvha_push_response(sess, psid, 0);"""

NEW = """\t\t\t\t\tvha_push_response(sess, psid, 0);
					/* HERMES-SUSPENDAFTER: 按厂商节律，完成后挂起，
					 * 让下一轮 try_resume_work 做真正的重新初始化。 */
					if (vha_suspend_after_run)
						phytium_npu_schedule_suspend(npu,
							NPU_AUTO_SUSPEND_TIMEOUT);"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_suspendafter.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-SUSPENDAFTER" in src:
        print("[SKIP] 已打过 HERMES-SUSPENDAFTER")
        return 0
    n = src.count(OLD)
    print("[INFO] 锚点 vha_push_response(sess, psid, 0)=%d (期望 1)" % n)
    if n != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_presusp_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src.replace(OLD, NEW))
    print("[OK  ] 已打补丁：HERMES-SUSPENDAFTER")
    return 0


if __name__ == "__main__":
    sys.exit(main())

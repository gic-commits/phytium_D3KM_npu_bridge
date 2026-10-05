#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-CLRSTATUS：启动前清 NPU_CH0_STATUS，完成后按厂商做法 schedule_suspend。

实测依据（mobilenet 连跑两次）：
  1st: [VHA-TD-A] before: STATUS=0x0 CTRL=0x0    -> done=1 after 7~11ms
  2nd: [VHA-TD-A] before: STATUS=0x1 CTRL=0x307e -> done=0 after 5003ms
  两次的提交参数逐字节相同（同 fd/iova/size/CONTROL=0x307f/stream_size/cmd_words），
  启动前 CMDREQ_RD / CMDREQ_RD_WORD / OUTSTANDING / MDBG_IDLE 也完全相同
  ⇒ 唯一差别是 NPU 核残留的 NPU_CH0_STATUS=0x1 ⇒ 硬件忽略本次启动。
厂商 phytium_npu_submit_stream() 每轮做 clear_irq_status + config_event，
完成路径 phytium_npu_inference_complete() 末尾调 schedule_suspend；
我们的提交路径两者都没做。

用法: apply_clrstatus.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

# 启动前插入（锚点：CONTROL 打印之后、REGWRITE32(NPU_CH0_CONTROL) 之前）
OLD_START = """			wmb();
			REGWRITE32(npu, NPU_CH0_CONTROL, ctrl);"""

NEW_START = """			/* HERMES-CLRSTATUS: 上一轮的完成状态会留在 NPU_CH0_STATUS，
			 * 不清掉则本次 CONTROL 启动被硬件忽略（实测第 2 轮 done=0、EVENT_STATUS=0）。
			 */
			if (vha_clr_status_before_start) {
				u32 st0 = REGREAD32(npu, NPU_CH0_STATUS);

				if (st0 & 0x1) {
					REGWRITE32(npu, NPU_CH0_STATUS, 0x1);
					wmb();
					dev_info(npu->dev,
						 "[VHA-CLRSTATUS] STATUS %#x -> %#x\\n",
						 st0, REGREAD32(npu, NPU_CH0_STATUS));
				}
			}
			wmb();
			REGWRITE32(npu, NPU_CH0_CONTROL, ctrl);"""

PARAM_ANCHOR = "static int vha_reset_each_run;"
PARAM_NEW = """/* HERMES-CLRSTATUS (2026-10-05): 启动前清 NPU_CH0_STATUS / 完成后挂起 */
static int vha_clr_status_before_start = 1;
module_param(vha_clr_status_before_start, int, 0644);
MODULE_PARM_DESC(vha_clr_status_before_start, "clear NPU_CH0_STATUS before start (fix 2nd-run no-execute)");

static int vha_suspend_after_run = 1;
module_param(vha_suspend_after_run, int, 0644);
MODULE_PARM_DESC(vha_suspend_after_run, "call phytium_npu_schedule_suspend after a completed run (vendor behaviour)");

static int vha_reset_each_run;"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_clrstatus.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-CLRSTATUS" in src:
        print("[SKIP] 已打过 HERMES-CLRSTATUS")
        return 0
    n1 = src.count(OLD_START)
    n2 = src.count(PARAM_ANCHOR)
    print("[INFO] 锚点: start=%d param=%d (期望 1/1)" % (n1, n2))
    if n1 != 1 or n2 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preclrstatus_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD_START, NEW_START).replace(PARAM_ANCHOR, PARAM_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-CLRSTATUS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

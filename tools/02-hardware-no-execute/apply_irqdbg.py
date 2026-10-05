#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-IRQDBG：在中断上下半部打印事件位，判定"失败那次到底有没有中断"。

背景：phytium_npu_handle_thread_irq() 的 NPU_INFERENCE_COMPLETE_EVENT 分支
      只调 inference_complete + try_excute_queued_stream，**不推响应**；
      推响应的路径（response_stream）只在错误分支里。
      
所以"失败那次 done=0 且无响应"存在两种可能：
  (a) 硬件压根没发中断（静默停住）
  (b) 中断来了但事件位不是 INFERENCE_COMPLETE（例如 MMU/AXI/WDT 错误）

本补丁把两者区分开：打印每次进入下半部的 status/err/事件归属 + 计数。

用法: apply_irqdbg.py <phytium_npu_common.c> [--check]
"""
import sys, shutil, time

OLD = """	mutex_lock(&npu_dev->mutex_lock);
	spin_lock(&npu_dev->spin_irq_lock);
	status = npu_dev->irq_status;
	spin_unlock(&npu_dev->spin_irq_lock);"""

NEW = """	mutex_lock(&npu_dev->mutex_lock);
	spin_lock(&npu_dev->spin_irq_lock);
	status = npu_dev->irq_status;
	spin_unlock(&npu_dev->spin_irq_lock);
	/* HERMES-IRQDBG: 记录每次下半部的事件位，区分"没有中断"与"中断但不是完成事件" */
	{
		static atomic_t vha_irqth_cnt = ATOMIC_INIT(0);
		int n = atomic_inc_return(&vha_irqth_cnt);

		dev_info(npu_dev->dev,
			 "[VHA-IRQTH] #%d status=%#x COMPLETE=%d AXI=%d ERR=%d MMU=%d WDT=%d INFERR=%d MEMWDT=%d\\n",
			 n, status,
			 !!(status & NPU_INFERENCE_COMPLETE_EVENT),
			 !!(status & NPU_AXI_EVENT), !!(status & NPU_ERR_EVENT),
			 !!(status & NPU_MMU_EVENT), !!(status & NPU_WDT_EVENT),
			 !!(status & NPU_INFERENCT_ERR_EVENT), !!(status & NPU_MEM_WDT_EVENT));
	}"""

OLD2 = """	status = phytium_npu_get_irq_status(npu_dev);
	if (!status) {
		pr_debug(\"No irq here.\");
		return IRQ_NONE;
	}"""

NEW2 = """	status = phytium_npu_get_irq_status(npu_dev);
	if (!status) {
		pr_debug(\"No irq here.\");
		return IRQ_NONE;
	}
	/* HERMES-IRQDBG: 中断上半部命中（含未通过 mask 的情况） */
	{
		static atomic_t vha_irqtop_cnt = ATOMIC_INIT(0);

		dev_info(npu_dev->dev, \"[VHA-IRQTOP] #%d status=%#x mask=%#x\\n\",
			 atomic_inc_return(&vha_irqtop_cnt), status, irq_mask);
	}"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_irqdbg.py <phytium_npu_common.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-IRQDBG" in src:
        print("[SKIP] 已打过 HERMES-IRQDBG")
        return 0
    n1, n2 = src.count(OLD), src.count(OLD2)
    print("[INFO] 锚点: thread_irq=%d top_irq=%d (期望 1/1)" % (n1, n2))
    if n1 != 1 or n2 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_preirqdbg_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD, NEW).replace(OLD2, NEW2)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-IRQDBG")
    return 0


if __name__ == "__main__":
    sys.exit(main())

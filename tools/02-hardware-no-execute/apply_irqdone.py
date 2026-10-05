#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-IRQDONE：用"完成中断已到"作为提交完成的判据（取代 CRC 轮询猜）。

★★ 根因（2026-10-05 深夜，IRQDBG 实测）★★
  mobilenet 连跑 4 次，每次都收到完成中断：
      [VHA-IRQTH] #1..4 status=0x1 COMPLETE=1 AXI=0 ERR=0 MMU=0 WDT=0 INFERR=0
      IRQTOP=4 IRQTH=4 COMPLETE=1 次数=4
  ⇒ 硬件每次都执行完并发了中断，"硬件隔次不执行"是**误判**。

  但我们的 `vha_real_submit` 等待循环只用两个判据：
      (a) vha_rsp_served 增加（= 库已消费过一条响应）
      (b) 输出缓冲 CRC 变化
  失败那两次两者都不成立 ⇒ done=0 ⇒ `if (done && !vha_sim_mode)` **不推响应**
  ⇒ 库的 HandleResponse 永远等不到 ⇒ worker 挂死 30s 被击杀 ⇒ -3 SERVER。

  ⇒ 正解：中断里的 NPU_INFERENCE_COMPLETE_EVENT 才是权威完成信号。
     本补丁在中断下半部的完成分支递增一个计数器，提交等待循环以它为准。

改动：
  phytium_npu_common.c: 完成分支 atomic_inc(&vha_irq_complete_cnt)（非 static，供 uapi 用）
  phytium_npu_uapi.c  : extern 声明 + 等待循环改用该计数器

用法: apply_irqdone.py <phytium_npu_common.c> <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

# ---- common.c：在 INFERENCE_COMPLETE 分支计数 ----
C_OLD = """	if (status & NPU_INFERENCE_COMPLETE_EVENT) {
		pr_debug(\"DEBUG:NPU infers complete here %#x\", npu_dev->irq_status);
		phytium_npu_inference_complete(npu_dev);
		phytium_npu_try_excute_queued_stream(npu_dev);
	}"""

C_NEW = """	if (status & NPU_INFERENCE_COMPLETE_EVENT) {
		pr_debug(\"DEBUG:NPU infers complete here %#x\", npu_dev->irq_status);
		/* HERMES-IRQDONE: 完成中断 = 权威完成信号，供提交路径判定 */
		atomic_inc(&vha_irq_complete_cnt);
		phytium_npu_inference_complete(npu_dev);
		phytium_npu_try_excute_queued_stream(npu_dev);
	}"""

# 计数器定义放在 handle_irq 前
C_DEF_OLD = """int phytium_npu_handle_irq(struct device *dev)
{"""
C_DEF_NEW = """/* HERMES-IRQDONE: 完成中断累计计数（跨文件可见） */
atomic_t vha_irq_complete_cnt = ATOMIC_INIT(0);
EXPORT_SYMBOL(vha_irq_complete_cnt);

int phytium_npu_handle_irq(struct device *dev)
{"""

# ---- uapi.c：等待循环改用计数器 ----
U_DECL_OLD = """static atomic_t vha_rsp_served = ATOMIC_INIT(0);"""
U_DECL_NEW = """static atomic_t vha_rsp_served = ATOMIC_INIT(0);
/* HERMES-IRQDONE: 来自 phytium_npu_common.c 的完成中断计数 */
extern atomic_t vha_irq_complete_cnt;"""

U_OLD = """				int served_before = atomic_read(&vha_rsp_served);
				int src = 0;"""
U_NEW = """				int served_before = atomic_read(&vha_rsp_served);
				int irq_before = atomic_read(&vha_irq_complete_cnt);
				int src = 0;"""

U_LOOP_OLD = """					if (atomic_read(&vha_rsp_served) > served_before) {
						done = 1;
						src = 1;
						vha_sync_signal();
						break;
					}"""
U_LOOP_NEW = """					if (vha_use_irq_done &&
					    atomic_read(&vha_irq_complete_cnt) > irq_before) {
						done = 1;
						src = 3;
						vha_sync_signal();
						break;
					}
					if (atomic_read(&vha_rsp_served) > served_before) {
						done = 1;
						src = 1;
						vha_sync_signal();
						break;
					}"""

U_PARAM_OLD = "static int vha_clr_status_before_start = 1;"
U_PARAM_NEW = """/* HERMES-IRQDONE: 以完成中断为提交完成判据（默认开） */
static int vha_use_irq_done = 1;
module_param(vha_use_irq_done, int, 0644);
MODULE_PARM_DESC(vha_use_irq_done, "use NPU_INFERENCE_COMPLETE interrupt as submit-done signal");

static int vha_clr_status_before_start = 1;"""

U_LABEL_OLD = """src == 3 ? \"硬件进度\" : \"超时/其他\""""
U_LABEL_NEW = """src == 3 ? \"完成中断\" : \"超时/其他\""""


def do(path, pairs, tag, check):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-IRQDONE" in src:
        print("[SKIP] %s 已打过" % tag)
        return True
    for old, new in pairs:
        n = src.count(old)
        print("[INFO] %s 锚点 %r -> %d (期望 1)" % (tag, old.strip().splitlines()[0][:44], n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一，中止" % tag)
            return False
        if not check:
            src = src.replace(old, new)
    if check:
        return True
    bak = path + ".bak_preirqdone_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)
    print("[OK  ] %s 已打补丁" % tag)
    return True


def main():
    check = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        print("用法: apply_irqdone.py <common.c> <uapi.c> [--check]")
        return 2
    ok1 = do(args[0], [(C_DEF_OLD, C_DEF_NEW), (C_OLD, C_NEW)], "common.c", check)
    ok2 = ok1 and do(args[1], [
        (U_DECL_OLD, U_DECL_NEW),
        (U_PARAM_OLD, U_PARAM_NEW),
        (U_OLD, U_NEW),
        (U_LOOP_OLD, U_LOOP_NEW),
        (U_LABEL_OLD, U_LABEL_NEW),
    ], "uapi.c", check)
    if check:
        print("[CHECK] 可以打补丁" if ok2 else "[CHECK] 有问题")
    return 0 if ok2 else 3


if __name__ == "__main__":
    sys.exit(main())

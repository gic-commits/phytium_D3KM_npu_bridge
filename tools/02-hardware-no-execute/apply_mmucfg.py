#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-MMUCFG：提交前对本次会话做 MMU/DMA 配置（厂商提交路径每轮都做，我们没做）。

依据：
  * 严格"隔次失败"（同一 worker 内 1✓2✗3✓4✗5✓6✗，完全确定）。
  * 对比成功/失败两次提交的现场，发现**会话不同**：
      成功: [VHA-IOCTL-ENTRY] ... sess=00000000319eef7c
      失败: [VHA-IOCTL-ENTRY] ... sess=00000000cb9d41fb
    ⇒ 库交替使用两个 session（乒乓）。
  * 厂商 phytium_npu_submit_stream() 每轮做：
      phytium_npu_mmu_config_dev_mmu(sess)
      phytium_npu_config_dma_address(sess, nstream)
    我们的 vha_real_submit 两者都没有 ⇒ 第二个 session 从未配置过 MMU/DMA。

用法: apply_mmucfg.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """			/* HERMES-CLRSTATUS: 上一轮的完成状态会留在 NPU_CH0_STATUS，"""

NEW = """			/* HERMES-MMUCFG: 厂商每轮提交都对本次会话做 MMU/DMA 配置，
			 * 我们此前只在 LOAD 阶段配过一次 ⇒ 交替使用的第二个 session
			 * 没有配置 ⇒ 硬件不执行（实测严格隔次失败）。
			 */
			if (vha_mmu_cfg_each_submit) {
				int mrc = phytium_npu_mmu_config_dev_mmu(sess);

				dev_info(npu->dev,
					 "[VHA-MMUCFG] sess=%p rc=%d ctxid=%u sid=%#x\\n",
					 (void *)sess, mrc,
					 sess->mmu_ctx[NPU_MMU_CONTEXT_MODULE_ID].context_id,
					 sid);
			}
			/* HERMES-CLRSTATUS: 上一轮的完成状态会留在 NPU_CH0_STATUS，"""

PARAM_ANCHOR = "static int vha_clr_status_before_start = 1;"
PARAM_NEW = """/* HERMES-MMUCFG (2026-10-05): 每轮提交前重配本次会话的 MMU */
static int vha_mmu_cfg_each_submit = 1;
module_param(vha_mmu_cfg_each_submit, int, 0644);
MODULE_PARM_DESC(vha_mmu_cfg_each_submit, "re-config MMU/DMA for this session on every submit");

static int vha_clr_status_before_start = 1;"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_mmucfg.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-MMUCFG" in src:
        print("[SKIP] 已打过 HERMES-MMUCFG")
        return 0
    n1 = src.count(OLD)
    n2 = src.count(PARAM_ANCHOR)
    print("[INFO] 锚点: clrstatus=%d param=%d (期望 1/1)" % (n1, n2))
    if n1 != 1 or n2 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_premmucfg_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD, NEW).replace(PARAM_ANCHOR, PARAM_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-MMUCFG")
    return 0


if __name__ == "__main__":
    sys.exit(main())

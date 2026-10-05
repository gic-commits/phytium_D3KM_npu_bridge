#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-MMUDBG：提交时打印本会话的 MMU 上下文/页表基址 与设备当前的映射寄存器。

目的（定位"隔次失败"）：
  设备侧 NPU_CH0_MMU_MAPPING_CONTEXT / MMU_MAPPING_ADDR 是**全局单组**寄存器；
  phytium_npu_mmu_config_dev_mmu(sess) 会把它们指向"本次会话"的页面目录。
  若失败会话的 pc_base_phys_addr 为 0，或与寄存器当前值不符 ⇒ 直接坐实 MMU 映射问题。

用法: apply_mmudbg.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """			wmb();
			REGWRITE32(npu, NPU_CH0_CONTROL, ctrl);"""

NEW = """			/* HERMES-MMUDBG: 对照本会话页表基址与设备当前映射 */
			dev_info(npu->dev,
				 "[VHA-MMUDBG] sess=%p id=%u ctx0=%u pc0=%#x ctx1=%u pc1=%#x | REG map_ctx=%#x map_addr=%#x ctrl_bs=%#x\\n",
				 (void *)sess, sess->id,
				 sess->mmu_ctx[0].context_id,
				 sess->mmu_ctx[0].pc_base_phys_addr,
				 sess->mmu_ctx[1].context_id,
				 sess->mmu_ctx[1].pc_base_phys_addr,
				 REGREAD32(npu, NPU_CH0_MMU_MAPPING_CONTEXT),
				 REGREAD32(npu, NPU_CH0_MMU_MAPPING_ADDR),
				 REGREAD32(npu, NPU_CH0_MMU_CTRL_BS));
			wmb();
			REGWRITE32(npu, NPU_CH0_CONTROL, ctrl);"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_mmudbg.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-MMUDBG" in src:
        print("[SKIP] 已打过 HERMES-MMUDBG")
        return 0
    n = src.count(OLD)
    print("[INFO] 锚点 CONTROL 写入=%d (期望 1)" % n)
    if n != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_premmudbg_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src.replace(OLD, NEW))
    print("[OK  ] 已打补丁：HERMES-MMUDBG")
    return 0


if __name__ == "__main__":
    sys.exit(main())

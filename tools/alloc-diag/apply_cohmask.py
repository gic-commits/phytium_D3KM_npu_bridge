#!/usr/bin/env python3
# 修复：设置 coherent_dma_mask（dma_alloc_coherent 用的是这个）
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
F = T + "phytium_npu_platform.c"
src = open(F, encoding="utf-8", errors="replace").read()
if "HERMES-COH-MASK" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(F, F + ".bak31_precohmask")

old = """\tret = dma_set_mask(dev, dma_mask);
\tif (ret) {
\t\tdev_err(dev, "%s failed to set dma mask\\n", __func__);
\t\treturn ret;
\t}"""
new = """\tret = dma_set_mask(dev, dma_mask);
\tif (ret) {
\t\tdev_err(dev, "%s failed to set dma mask\\n", __func__);
\t\treturn ret;
\t}
\t/* HERMES-COH-MASK: dma_alloc_coherent() 用的是 coherent_dma_mask，
\t * 原代码只设了 dma_mask => coherent_dma_mask 仍是默认(可能 32bit)，
\t * 导致大块 CMA 分配被拒。这里显式设成同一个掩码。 */
\tret = dma_set_coherent_mask(dev, dma_mask);
\tif (ret) {
\t\tdev_err(dev, "%s failed to set coherent dma mask\\n", __func__);
\t\treturn ret;
\t}
\tdev_info(dev, "%s coherent_dma_mask set to %#llx\\n", __func__, dma_mask);"""
if old not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(old, new, 1)
open(F, "w", encoding="utf-8").write(src)
print("已插入 HERMES-COH-MASK")
print("  dma_set_coherent_mask 出现:", src.count("dma_set_coherent_mask"))

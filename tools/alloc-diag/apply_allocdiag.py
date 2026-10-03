#!/usr/bin/env python3
# 加诊断：打印 dma_alloc_coherent 的详细结果
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-ALLOC-DIAG" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak32_prediag")

old = """\t\t\te->kvaddr = dma_alloc_coherent(npu->dev, vha_alloc_ask,
\t\t\t\t\t\t       &e->dma_handle, g);
\t\t}"""
new = """\t\t\t/* HERMES-ALLOC-DIAG: 打印分配前后的详细信息 */
\t\t\tdev_info(npu->dev,
\t\t\t\t "[VHA-ALLOC-DIAG] try size=%zu gfp=%#x dev=%s dma_mask=%#llx coh_mask=%#llx\\n",
\t\t\t\t vha_alloc_ask, g, dev_name(npu->dev),
\t\t\t\t (unsigned long long)dma_get_mask(npu->dev),
\t\t\t\t (unsigned long long)npu->dev->coherent_dma_mask);
\t\t\te->kvaddr = dma_alloc_coherent(npu->dev, vha_alloc_ask,
\t\t\t\t\t\t       &e->dma_handle, g);
\t\t\tdev_info(npu->dev,
\t\t\t\t "[VHA-ALLOC-DIAG] ret=%p phys=%pad\\n",
\t\t\t\t e->kvaddr, &e->dma_handle);
\t\t}"""
if old not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(old, new, 1)
open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-ALLOC-DIAG")

#!/usr/bin/env python3
# 用 pr_err（级别 3，必输出）替换 VHA_ALLOC_MEM 分支的 dev_info，验证是否执行
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-ALLOC-ERR" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak33_preerr")

old = """\t\tdev_info(npu->dev, "%s: alloc size=%llu name=%.8s\\n",
\t\t\t __func__, req.size, req.name);"""
new = """\t\t/* HERMES-ALLOC-ERR: 用 pr_err 确保输出（验证分支是否执行） */
\t\tpr_err("[VHA-ALLOC-ERR] %s: alloc size=%llu name=%.8s\\n",
\t\t       __func__, req.size, req.name);"""
if old not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(old, new, 1)
open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-ALLOC-ERR")

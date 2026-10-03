#!/usr/bin/env python3
# 修复：给 npu_info 的 l1_size/l3_size/l3_percore_size 填合理值
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-INFO-FIX" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak35_preinfofix")

old = """\tinfo->l1_size = 0;
\tinfo->l3_size = 0;
\tinfo->l3_percore_size = 0;"""
new = """\t/* HERMES-INFO-FIX: 原来全填 0 => 库认为"没有可用内存" =>
\t * 大块(27MB)分配在【发起之前】就被库自己拒绝
\t * (FATAL: failed to allocate 28459008 bytes, 但驱动侧从未收到该请求)。
\t * 填成实际可用量（CMA 1GB，留余量）。 */
\tinfo->l1_size = 0;
\tinfo->l3_size = vha_info_l3_size;
\tinfo->l3_percore_size = vha_info_l3_size;"""
if old not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(old, new, 1)

# 加参数
anchor = "static int vha_gfp_tune;"
if anchor not in src:
    print("锚点2未找到"); sys.exit(1)
src = src.replace(anchor, anchor + """
/* HERMES-INFO-FIX: 报告给库的 L3 大小（字节）。默认 512MB。 */
static unsigned int vha_info_l3_size = 512u << 20;
module_param(vha_info_l3_size, uint, 0644);
MODULE_PARM_DESC(vha_info_l3_size, "VHA: l3_size reported via NPU_INFO (bytes)");
""", 1)

open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-INFO-FIX")
print("  vha_info_l3_size 出现:", src.count("vha_info_l3_size"))

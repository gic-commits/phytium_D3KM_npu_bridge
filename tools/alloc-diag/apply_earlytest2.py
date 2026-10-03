#!/usr/bin/env python3
# 在模块 init 里加"早期分配测试"：加载时立刻试分配指定尺寸
import shutil, sys, re
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-EARLYTEST" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak30_preearly")

anchor = "static int vha_gfp_tune;"
if anchor not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(anchor, anchor + """
/* HERMES-EARLYTEST: 模块加载时立刻尝试分配指定尺寸的 CMA，验证碎片情况。
 * 0=关闭。分配后立即释放（只测可行性）。 */
static unsigned long long vha_earlytest;
module_param(vha_earlytest, ullong, 0644);
MODULE_PARM_DESC(vha_earlytest, "VHA: at load time, try alloc+free this many bytes");
""", 1)

# 找 init 入口（可能在别的文件）
m = re.search(r'module_init\((\w+)\)', src)
if not m:
    print("本文件无 module_init，改用 platform driver probe")
    # 找 probe 函数
    pm = re.search(r'static int (\w*probe\w*)\(struct platform_device', src)
    if pm:
        fn = pm.group(1)
        pat = re.compile(r'(static int ' + fn + r'\(struct platform_device[^)]*\)\s*\{)')
        mm = pat.search(src)
        if mm:
            ins = mm.group(1) + """
\t/* HERMES-EARLYTEST */
\tif (vha_earlytest) {
\t\tdma_addr_t h = 0;
\t\tvoid *p = dma_alloc_coherent(&pdev->dev, vha_earlytest, &h, GFP_KERNEL);
\t\tpr_info("[VHA-EARLYTEST] alloc %llu bytes => %s (phys=%pad)\\n",
\t\t\tvha_earlytest, p ? "OK" : "FAIL", &h);
\t\tif (p)
\t\t\tdma_free_coherent(&pdev->dev, vha_earlytest, p, h);
\t}"""
            src = src[:mm.start(1)] + ins + src[mm.end(1):]
            print(f"  已插入到 probe: {fn}")
        else:
            print("probe 函数体未找到"); sys.exit(1)
    else:
        print("未找到 probe"); sys.exit(1)
else:
    fn = m.group(1)
    pat = re.compile(r'(static int __init ' + fn + r'\(void\)\s*\{)')
    mm = pat.search(src)
    if not mm:
        print("init 函数体未找到"); sys.exit(1)
    ins = mm.group(1) + """
\t/* HERMES-EARLYTEST */
\tif (vha_earlytest) {
\t\tdma_addr_t h = 0;
\t\tvoid *p = dma_alloc_coherent(NULL, vha_earlytest, &h, GFP_KERNEL);
\t\tpr_info("[VHA-EARLYTEST] alloc %llu bytes => %s (phys=%pad)\\n",
\t\t\tvha_earlytest, p ? "OK" : "FAIL", &h);
\t\tif (p)
\t\t\tdma_free_coherent(NULL, vha_earlytest, p, h);
\t}"""
    src = src[:mm.start(1)] + ins + src[mm.end(1):]
    print(f"  已插入到 init: {fn}")

open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-EARLYTEST")

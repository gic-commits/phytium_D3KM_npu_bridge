#!/usr/bin/env python3
# 方向1 精修：只放大"指定的请求尺寸"那块（默认 448000 = sensevoice 的 x 输入）
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()

if "HERMES-OVERALLOC-EXACT" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak25_preexact")

# 1) 新增"精确匹配尺寸"参数（逗号分隔的列表，或单个值）
a1 = "static int vha_overalloc_min = 65536;"
if a1 not in src:
    print("锚点1未找到"); sys.exit(1)
src = src.replace(a1, a1 + """
/* HERMES-OVERALLOC-EXACT: 只放大【请求尺寸恰好等于 vha_overalloc_exact】的那块缓冲。
 * 动机：sensevoice 的 x 输入(x[1,200,560] f32 = 448000)被段 IO 按 913920 校验，
 * 而全序列里 448000 只出现 1 次 => 只放大它，多花 0.46MB，CMA 完全够。
 * 0=关闭。 */
static unsigned long long vha_overalloc_exact;
module_param(vha_overalloc_exact, ullong, 0644);
MODULE_PARM_DESC(vha_overalloc_exact, "VHA: only overalloc buffers whose req.size == this");
""", 1)

# 2) 放大条件：加上"精确匹配"分支
old2 = """\t\t\tif (vha_overalloc_mul > 1 &&
\t\t\t    req.size >= (u64)vha_overalloc_min) {
\t\t\t\task = PAGE_ALIGN(req.size * (size_t)vha_overalloc_mul);
\t\t\t\tdev_info(npu->dev,
\t\t\t\t\t "[VHA-OVERALLOC] req=%llu -> ask=%zu (x%d) name=%.8s\\n",
\t\t\t\t\t req.size, ask, vha_overalloc_mul, req.name);
\t\t\t}"""
new2 = """\t\t\tif (vha_overalloc_mul > 1 &&
\t\t\t    req.size >= (u64)vha_overalloc_min) {
\t\t\t\task = PAGE_ALIGN(req.size * (size_t)vha_overalloc_mul);
\t\t\t\tdev_info(npu->dev,
\t\t\t\t\t "[VHA-OVERALLOC] req=%llu -> ask=%zu (x%d) name=%.8s\\n",
\t\t\t\t\t req.size, ask, vha_overalloc_mul, req.name);
\t\t\t}
\t\t\t/* HERMES-OVERALLOC-EXACT: 只放大精确匹配的那块 */
\t\t\tif (vha_overalloc_exact &&
\t\t\t    req.size == (u64)vha_overalloc_exact) {
\t\t\t\task = PAGE_ALIGN(req.size * (size_t)(vha_overalloc_mul > 1 ? vha_overalloc_mul : 3));
\t\t\t\tdev_info(npu->dev,
\t\t\t\t\t "[VHA-OVERALLOC-EXACT] req=%llu -> ask=%zu name=%.8s\\n",
\t\t\t\t\t req.size, ask, req.name);
\t\t\t}"""
if old2 not in src:
    print("锚点2未找到"); sys.exit(1)
src = src.replace(old2, new2, 1)

open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-OVERALLOC-EXACT")
print("  vha_overalloc_exact 出现:", src.count("vha_overalloc_exact"))

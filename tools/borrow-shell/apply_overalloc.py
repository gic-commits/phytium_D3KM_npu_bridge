#!/usr/bin/env python3
# 方向1：内部按放大尺寸分配、回报尺寸保持原值（解耦）
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-OVERALLOC" in src:
    print("已打过补丁"); sys.exit(0)

shutil.copy2(U, T + "phytium_npu_uapi.c.bak24_preoveralloc")

# 1) 模块参数
a1 = "static unsigned long vha_next_page;"
if a1 not in src:
    print("锚点1未找到"); sys.exit(1)
src = src.replace(a1, a1 + """
/* HERMES-OVERALLOC: 内部按放大尺寸分配，但【回报给库的尺寸保持原值】。
 * 动机：厂商库在"建网络对象"阶段会用【段 IO 声明的尺寸】校验缓冲容量
 * (实测 sensevoice: 申请 457776 但校验要 913920)，而库自己申请时用的是较小值。
 * 解耦后：库的记账不变(不会触发 parser 错误)，实际容量变大(能过校验)。
 * 0=关闭(默认)；N=按 N 倍放大(仅当请求 >= vha_overalloc_min 时生效)。 */
static int vha_overalloc_mul;
module_param(vha_overalloc_mul, int, 0644);
MODULE_PARM_DESC(vha_overalloc_mul, "VHA: internal alloc = req.size * N (report size unchanged)");
static int vha_overalloc_min = 65536;
module_param(vha_overalloc_min, int, 0644);
MODULE_PARM_DESC(vha_overalloc_min, "VHA: apply overalloc only when req.size >= this");
""", 1)

# 2) 分配处改为放大尺寸
old2 = """\t\tif (vha_sim_mode) {
\t\t\te->kvaddr = vmalloc_user(req.size);
\t\t\te->dma_handle = 0;
\t\t} else {
\t\t\t/* B1: NPU-visible coherent memory */
\t\t\te->kvaddr = dma_alloc_coherent(npu->dev, PAGE_ALIGN(req.size),
\t\t\t\t\t\t       &e->dma_handle, GFP_KERNEL);
\t\t}"""
new2 = """\t\t/* HERMES-OVERALLOC: 计算实际分配尺寸(内部)，回报尺寸仍用 req.size */
\t\t{
\t\t\tsize_t ask = PAGE_ALIGN(req.size);

\t\t\tif (vha_overalloc_mul > 1 &&
\t\t\t    req.size >= (u64)vha_overalloc_min) {
\t\t\t\task = PAGE_ALIGN(req.size * (size_t)vha_overalloc_mul);
\t\t\t\tdev_info(npu->dev,
\t\t\t\t\t "[VHA-OVERALLOC] req=%llu -> ask=%zu (x%d) name=%.8s\\n",
\t\t\t\t\t req.size, ask, vha_overalloc_mul, req.name);
\t\t\t}
\t\t\tvha_alloc_ask = ask;
\t\t}
\t\tif (vha_sim_mode) {
\t\t\te->kvaddr = vmalloc_user(vha_alloc_ask);
\t\t\te->dma_handle = 0;
\t\t} else {
\t\t\t/* B1: NPU-visible coherent memory */
\t\t\te->kvaddr = dma_alloc_coherent(npu->dev, vha_alloc_ask,
\t\t\t\t\t\t       &e->dma_handle, GFP_KERNEL);
\t\t}"""
if old2 not in src:
    print("锚点2未找到"); sys.exit(1)
src = src.replace(old2, new2, 1)

# 3) e->size / pages 用实际分配尺寸
old3 = """\t\te->size = req.size;
\t\tpages = (req.size + PAGE_SIZE - 1) >> PAGE_SHIFT;"""
new3 = """\t\te->req_size = req.size;        /* 逻辑尺寸(库请求的) */
\t\te->size = vha_alloc_ask;       /* 实际分配尺寸(可能放大) */
\t\tpages = (vha_alloc_ask + PAGE_SIZE - 1) >> PAGE_SHIFT;"""
if old3 not in src:
    print("锚点3未找到"); sys.exit(1)
src = src.replace(old3, new3, 1)

# 4) 需要 vha_alloc_ask 与 e->req_size 字段
if "static size_t vha_alloc_ask;" not in src:
    src = src.replace("static unsigned long vha_next_page;",
                      "static size_t vha_alloc_ask;   /* HERMES-OVERALLOC */\nstatic unsigned long vha_next_page;", 1)
if "size_t req_size;" not in src:
    # 在 struct vha_alloc_entry 里加字段
    old4 = "\tsize_t size;"
    if old4 in src:
        src = src.replace(old4, "\tsize_t size;\n\tsize_t req_size;   /* HERMES-OVERALLOC: 库请求的逻辑尺寸 */", 1)
    else:
        print("!! struct 字段锚点未找到")

open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-OVERALLOC")
print("  vha_overalloc_mul 出现:", src.count("vha_overalloc_mul"))
print("  vha_alloc_ask 出现:", src.count("vha_alloc_ask"))
print("  req_size 出现:", src.count("req_size"))

#!/bin/bash
echo "=== 1. 关键验证：CMA 能否分配 27MB（写个内核测试不合适，用现有手段） ==="
echo "  当前 CMA 碎片:"
sudo cat /proc/pagetypeinfo 2>/dev/null | grep "DMA32, type          CMA" | sed 's/^/    /'
echo
echo "=== 2. 分析：27MB 需要多少连续 order-10 块 ==="
python3 -c "
need = 28459008
block = 4*1024*1024   # order-10 = 4MB
import math
print(f'  需要 {need} B = {need/1048576:.1f} MB')
print(f'  需连续 order-10 块: {math.ceil(need/block)} 个')
print(f'  当前 order-10 块数: 148 个')
print(f'  => 数量够，但需【连续】')
"
echo
echo "=== 3. 关键：库的分配顺序（大块在第几次） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'[#=]' '{print $2, $4}' | awk '$2 > 1000000 {print "  第"$1"次: "$2" ("$2/1048576" MB)"}' | head -10
echo
echo "=== 4. 失败点前后 ==="
sudo dmesg | grep -aE "alloc#[0-9]+ size=|cma_alloc.*failed" | tail -6 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 关键洞察：库先分配小缓冲，把 CMA 切碎后才要 27MB ==="
echo "  => 若能让大块【先】分配，就能成功"
echo
echo "=== 6. 驱动侧可行的最小改动 ==="
echo "  A. 预分配大池：模块加载时预留一大块 CMA，分配时从池里切"
echo "  B. 分配顺序优化：大请求优先（但库控制顺序）"
echo "  C. 用 SG 映射（驱动已有 map_sg）"
echo
echo "=== 7. 检查模块加载时是否有预留 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "reserve\|prealloc\|pool" $T/phytium_npu_uapi.c | head -10 | sed 's/^/  /'

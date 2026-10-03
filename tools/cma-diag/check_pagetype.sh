#!/bin/bash
echo "=== 1. CMA 碎片分析（通过 /proc/pagetypeinfo 看 CMA 类型） ==="
sudo cat /proc/pagetypeinfo 2>/dev/null | head -20 | sed 's/^/  /'
echo
echo "=== 2. 关键：CMA 区域的页类型分布 ==="
sudo cat /proc/pagetypeinfo 2>/dev/null | grep -A5 "Unmovable\|Movable" | head -20 | sed 's/^/  /'
echo
echo "=== 3. 我们的驱动占用（按分配记录算） ==="
echo "  本次 ALLOC: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=') 次"
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{s+=$2} END {printf "  合计: %.1f MB\n", s/1048576}'
echo "  REALFREE: $(sudo dmesg | grep -ac 'VHA-REALFREE') 次"
echo
echo "=== 4. 关键洞察：失败的是【第几次】分配 ==="
sudo dmesg | grep -aE "alloc#[0-9]+ size=|cma_alloc.*failed" | tail -8 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 尝试：先跑小模型（占用少量 CMA）再跑 sensevoice ==="
echo "  (验证 CMA 是否被小模型切碎)"
echo
echo "=== 6. CMA 区域起始与大小 ==="
sudo cat /proc/iomem 2>/dev/null | grep -i "cma\|reserved" | head -8 | sed 's/^/  /'
echo
echo "=== 7. 当前所有 NPU 相关进程 ==="
pgrep -a "npu|phydnn" | head -5 | sed 's/^/  /'

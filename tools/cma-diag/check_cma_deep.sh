#!/bin/bash
echo "=== 1. CMA 区域详情（/proc/meminfo + cmdline） ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo "  内核 cmdline:"
cat /proc/cmdline | tr ' ' '\n' | grep -i cma | sed 's/^/    /'
echo
echo "=== 2. CMA 分配失败的确切记录 ==="
sudo dmesg -T | grep -ai "cma" | tail -5 | sed 's/^/  /'
echo
echo "=== 3. 关键：CMA 区域是否被【其他驱动/子系统】占用 ==="
sudo dmesg | grep -aiE "cma|reserved|memblock" | head -15 | sed 's/^/  /'
echo
echo "=== 4. 尝试手动分配大块 CMA（用 dma-heap 或测试） ==="
ls /dev/dma_heap/ 2>/dev/null | sed 's/^/  /'
echo "  (空=无 dma_heap)"
echo
echo "=== 5. 关键：我们的驱动分配的总量 vs CMA 总量 ==="
echo "  本次 ALLOC 次数: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{s+=$2} END {printf "  合计: %.1f MB\n", s/1048576}'
echo "  CMA 总量: 1024 MB"
echo "  CmaFree: $(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
echo
echo "=== 6. 最大单次分配 vs 可用 CMA ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{print $2}' | sort -rn | head -3 | sed 's/^/  最大: /'
echo "  失败的是: 28459008 (27.1 MB)"
echo
echo "=== 7. 检查 CMA 是否真的连续（buddyinfo 看 CMA 区） ==="
cat /proc/buddyinfo | sed 's/^/  /'
echo
echo "=== 8. 关键：内核启动时 CMA 预留 ==="
sudo dmesg | grep -aiE "Reserved memory|CMA:|cma: Reserved" | head -10 | sed 's/^/  /'

#!/bin/bash
O=/home/greatwall/step9.txt
{
echo "=== 1. 关键：驱动传给 dma_alloc_coherent 的实际尺寸 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1330 && NR<=1372 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 2. 当前模块参数（看是否被 overalloc 影响） ==="
for p in vha_overalloc_mul vha_overalloc_exact vha_overalloc_min vha_overalloc_report vha_gfp_tune; do
  echo "  $p = $(cat /sys/module/phytium_npu/parameters/$p 2>/dev/null)"
done
echo
echo "=== 3. 关键：27MB 请求前后的完整驱动日志 ==="
sudo dmesg | grep -aE "VHA-ALLOC|VHA-OVERALLOC|alloc#" | tail -12 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 4. 是否有 ENOMEM 或其它错误 ==="
sudo dmesg | grep -aiE "phytium|vha" | grep -aiE "fail|error|ENOMEM|null" | tail -10 | sed 's/^/  /'
echo
echo "=== 5. 关键：内核 dma_alloc_coherent 的路径（看是否用 CMA） ==="
echo "  检查 dev->cma_area:"
sudo cat /sys/kernel/debug/dma-api/* 2>/dev/null | head -5 | sed 's/^/    /'
echo
echo "=== 6. 直接验证：内核能否分配 27MB 连续物理页 ==="
echo "  MemFree: $(awk '/MemFree/{print $2}' /proc/meminfo) kB"
echo "  buddyinfo (Normal 区 order>=8):"
awk '/Normal/ {for(i=9;i<=NF;i++) printf "    order%d=%s ", i-9, $i; print ""}' /proc/buddyinfo
echo
echo "=== 7. 关键：NPU 设备是否绑定了 CMA ==="
D=/sys/devices/platform/PHYT0050:00
ls $D/ 2>/dev/null | sed 's/^/  /'
echo "  --- of_node ---"
ls $D/of_node/ 2>/dev/null | head -15 | sed 's/^/    /'
} > $O 2>&1
cat $O

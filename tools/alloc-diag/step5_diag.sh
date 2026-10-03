#!/bin/bash
O=/home/greatwall/step5.txt
{
echo "=== 1. 完整 dmesg（分配失败前后 30 行） ==="
sudo dmesg | tail -40 | sed 's/^/  /'
echo
echo "=== 2. 是否有 dma/swiotlb/oom 报错 ==="
sudo dmesg | grep -aiE "swiotlb|dma|oom|out of memory|alloc.*fail" | tail -15 | sed 's/^/  /'
echo
echo "=== 3. 关键：驱动是否在分配前有【尺寸检查】 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1310 && NR<=1352 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 4. 内存现状 ==="
awk '/MemFree|MemAvailable|CmaFree|Slab/{print "  "$0}' /proc/meminfo
echo
echo "=== 5. 关键：dma_mask / coherent_dma_mask ==="
grep -n "dma_mask\|coherent_dma_mask\|dma_set_mask\|dma_set_coherent" $T/*.c | head -10 | sed 's/^/  /'
echo
echo "=== 6. NPU 设备的 dma_mask 实际值 ==="
for d in /sys/devices/platform/PHYT0050:00 /sys/bus/platform/devices/PHYT0050:00; do
  [ -e "$d" ] && echo "  $d 存在"
done
ls /sys/bus/platform/devices/ 2>/dev/null | grep -i phyt | sed 's/^/  /'
echo
echo "=== 7. 关键验证：分配失败时驱动返回什么错误 ==="
echo "  源码 1371-1375:"
awk 'NR>=1371 && NR<=1380 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
} > $O 2>&1
cat $O

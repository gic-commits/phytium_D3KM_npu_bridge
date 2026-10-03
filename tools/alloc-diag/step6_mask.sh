#!/bin/bash
O=/home/greatwall/step6.txt
{
echo "=== 1. NPU 设备的 dma_mask / coherent_dma_mask 实际值 ==="
D=/sys/devices/platform/PHYT0050:00
ls $D 2>/dev/null | head -20 | sed 's/^/  /'
echo
echo "  --- dma_mask 相关文件 ---"
for f in dma_mask coherent_dma_mask; do
  [ -e "$D/$f" ] && echo "  $f = $(cat $D/$f 2>/dev/null)" || echo "  $f 不存在"
done
echo
echo "=== 2. 驱动源码：platform.c 的 mask 设置 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=75 && NR<=100 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_platform.c | sed 's/^/  /'
echo
echo "=== 3. 关键：是否设置了 coherent_dma_mask ==="
grep -n "coherent_dma_mask\|dma_set_coherent_mask\|dma_set_mask_and_coherent" $T/*.c | sed 's/^/  /'
echo
echo "=== 4. dmesg 里的 mask 日志 ==="
sudo dmesg | grep -aiE "dma_mask|dma_set_mask|mask from DT" | sed 's/^/  /'
echo
echo "=== 5. 关键：NPU 设备树里的 dma-mask ==="
sudo find /proc/device-tree -name "*dma*" 2>/dev/null | head -5 | sed 's/^/  /'
for p in /proc/device-tree/soc*/npu* /proc/device-tree/npu*; do
  [ -e "$p" ] && echo "  $p:" && ls $p 2>/dev/null | head -10 | sed 's/^/    /'
done
echo
echo "=== 6. 直接测：能否分配 27MB（用 /proc/sys/vm 或其它手段） ==="
echo "  MemFree: $(awk '/MemFree/{print $2}' /proc/meminfo) kB"
echo "  CmaFree: $(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
} > $O 2>&1
cat $O

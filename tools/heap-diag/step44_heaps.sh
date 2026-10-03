#!/bin/bash
O=/home/greatwall/step44.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. 关键：VHA_GET_MEM_HEAPS 的实现（1296 行起） ==="
awk 'NR>=1296 && NR<=1310 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 2. 关键：堆描述符的定义与填充 ==="
grep -n -B5 -A25 "VHA_GET_MEM_HEAPS" $T/phytium_npu_uapi.c | head -50 | sed 's/^/  /'
echo
echo "=== 3. 关键：struct vha_heap_desc ==="
awk '/struct vha_heap_desc \{/,/^\};/' $T/include/phytium_npu_uapi.h | sed 's/^/  /'
echo
echo "=== 4. 关键：库读堆信息后怎么用 ==="
L=/usr/local/lib/libnpusession.so
strings -t x $L | grep -iE "heap|Heap" | head -20 | sed 's/^/  /'
echo
echo "=== 5. 关键：库的 GetMemHeaps 调用 ==="
nm -DC $L 2>/dev/null | grep -iE "Heap|heap" | head -15 | sed 's/^/  /'
echo
echo "=== 6. 关键：驱动返回的堆信息（dmesg 或直接调用） ==="
sudo dmesg | grep -aiE "heap" | tail -10 | sed 's/^/  /'
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step43.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. 关键：vha_next_page 的当前值（IOVA 空间使用量） ==="
sudo dmesg | grep -ao "page=[0-9]*" | awk -F= '{print $2}' | sort -rn | head -3 | sed 's/^/  最大 page: /'
echo "  page 单位: 4KB"
sudo dmesg | grep -ao "page=[0-9]*" | awk -F= '{print $2}' | sort -rn | head -1 | awk '{printf "  最大 IOVA: %.1f MB\n", $1*4096/1048576}'
echo
echo "=== 2. 关键：IOVA 空间上限（驱动里的定义） ==="
grep -n "vha_next_page\|VHA_IOVA\|iova_max\|MAX_IOVA" $T/phytium_npu_uapi.c | head -15 | sed 's/^/  /'
echo
echo "=== 3. 关键：驱动是否检查 IOVA 上限 ==="
grep -n -A5 "vha_next_page +=" $T/phytium_npu_uapi.c | head -20 | sed 's/^/  /'
echo
echo "=== 4. 关键：VhaVaaHeapAlloc 的实现（库侧 IOVA 分配） ==="
L=/usr/local/lib/libnpusession.so
objdump -d --start-address=0x3fda8 --stop-address=0x40050 $L 2>/dev/null | head -40 | sed 's/^/  /'
echo
echo "=== 5. 关键：库的 IOVA 空间大小 ==="
strings -t x $L | grep -iE "virtual address|vaa|heap" | head -10 | sed 's/^/  /'
echo
echo "=== 6. 关键：ioctl 返回的 IOVA 地址范围 ==="
sudo dmesg | grep -ao "iova=0x[0-9a-f]*" | sed 's/iova=0x//' | sort -u | tail -5 | sed 's/^/  /'
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step36.txt
{
echo "=== 1. 关键：本次加载的分配总量 ==="
sudo dmesg | grep -ao "alloc size=[0-9]*" | awk -F= '{s+=$2; n++} END {printf "  %d 次, 合计 %.1f MB\n", n, s/1048576}'
echo
echo "=== 2. 关键：库报错的确切内容与时间 ==="
sudo grep -a "FATAL\|failed to allocate\|Cannot allocate" /var/log/npuworker.log 2>/dev/null | tail -10 | sed 's/^/  /'
echo
echo "=== 3. 关键：报错前后库的日志 ==="
sudo grep -a -B5 -A10 "failed to allocate" /var/log/npuworker.log 2>/dev/null | tail -30 | sed 's/^/  /'
echo
echo "=== 4. 关键：库是否查询了【可用内存】 ==="
sudo dmesg | grep -a "VHA-INFO\|VHA-HEAPS\|l1_size\|l3_size" | tail -10 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 关键：INFO_COMPAT 返回的内存信息 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1200 && NR<=1232 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 6. 关键：本次加载是否成功 ==="
sudo tail -5 /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
} > $O 2>&1
cat $O

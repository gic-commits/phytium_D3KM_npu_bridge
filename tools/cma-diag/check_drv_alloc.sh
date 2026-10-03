#!/bin/bash
echo "=== 1. 驱动侧本次分配记录（含 31252480） ==="
sudo dmesg | grep -aE "alloc#|VHA-ALLOC|VHA-OVERALLOC|31252480|failed" | tail -30 | sed 's/^/  /'
echo
echo "=== 2. 驱动侧是否有拒绝/错误 ==="
sudo dmesg | grep -aiE "phytium_npu|vha" | grep -aiE "fail|error|reject|deny|too large|exceed" | tail -15 | sed 's/^/  /'
echo
echo "=== 3. 本次 ALLOC 统计（含最大） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{print $2}' | sort -rn | head -8 | sed 's/^/  /'
echo "  总次数: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
echo
echo "=== 4. 驱动侧分配上限（模块参数/常量） ==="
for p in $(ls /sys/module/phytium_npu/parameters/ 2>/dev/null); do
  echo "  $p = $(cat /sys/module/phytium_npu/parameters/$p 2>/dev/null)"
done
echo
echo "=== 5. 源码里的分配上限检查 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "MAX\|max_size\|too large\|EINVAL\|ENOMEM" $T/phytium_npu_uapi.c | head -20 | sed 's/^/  /'
echo
echo "=== 6. 31252480 是否超过某个上限 ==="
python3 -c "
v=31252480
print(f'  31252480 = {v/1048576:.1f} MB')
print(f'  是否 > 32MB: {v > 32*1048576}')
print(f'  是否 > 16MB: {v > 16*1048576}')
print(f'  是否 > 8MB:  {v > 8*1048576}')
"

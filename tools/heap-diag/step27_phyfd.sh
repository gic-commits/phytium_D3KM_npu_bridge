#!/bin/bash
O=/home/greatwall/step27.txt
{
echo "=== 1. 关键：worker 打开 /dev/phy_npu* 的 fd 号 ==="
sudo grep -aE 'openat.*phy_npu' /tmp/w2.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 2. 关键：所有对 npu 设备的 openat（含返回值） ==="
sudo grep -aE 'openat.*npu0|openat.*phy_npu' /tmp/w2.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 3. 关键：ioctl 的 fd 分布 ==="
sudo grep -a "ioctl(" /tmp/w2.log 2>/dev/null | grep -oE "ioctl\([0-9]+," | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
echo "=== 4. 关键：fd=8 上所有操作（看它何时变成 npu） ==="
sudo grep -aE "= 8$|ioctl\(8" /tmp/w2.log 2>/dev/null | head -20 | sed 's/^/  /'
echo
echo "=== 5. 关键：驱动侧 VHA-CMD 是否只记录了部分 ==="
echo "  驱动 VHA-CMD 条数: $(sudo dmesg | grep -ac 'VHA-CMD')"
echo "  驱动 nr 统计:"
sudo dmesg | grep -aoE "nr=0x[0-9a-f]+" | sort | uniq -c | sed 's/^/    /'
echo
echo "=== 6. 关键：驱动 ioctl 入口是否有 early return ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1225 && NR<=1245 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 7. 关键：是否有【另一个】ioctl 入口（sync_fops） ==="
awk 'NR>=130 && NR<=150 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
} > $O 2>&1
cat $O

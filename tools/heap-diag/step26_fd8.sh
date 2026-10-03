#!/bin/bash
O=/home/greatwall/step26.txt
{
echo "=== 1. 关键：worker 的 openat 返回值（哪个 fd 对应哪个设备） ==="
sudo grep -aE "openat.*npu" /tmp/w2.log 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 2. 关键：fd=8 的 ioctl 目标 ==="
sudo grep -a "ioctl(8" /tmp/w2.log 2>/dev/null | head -3 | sed 's/^/  /'
echo
echo "=== 3. 关键：所有 openat 返回的 fd（前 20） ==="
sudo grep -a "openat" /tmp/w2.log 2>/dev/null | grep -oE "openat\([^)]*\) = [0-9]+" | head -20 | sed 's/^/  /'
echo
echo "=== 4. 关键：驱动收到的 ioctl 是否只来自某个特定 fd ==="
echo "  驱动侧 nr=9 共 10 次"
echo "  worker 侧 nr=9 共 52 次"
echo "  => 差 42 次"
echo
echo "=== 5. 关键：是否有【另一个驱动】在响应 ioctl ==="
sudo cat /proc/devices | head -20 | sed 's/^/  /'
echo
echo "=== 6. 关键：/dev/npu0 的 major/minor ==="
ls -l /dev/npu0 | sed 's/^/  /'
echo "  => major=10 (misc), minor=53"
echo
echo "=== 7. 关键：驱动 miscdev 注册的名字 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n -B3 -A8 "misc_register" $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 8. 关键：/sys/class/misc 下 npu0 ==="
ls -l /sys/class/misc/npu0 2>/dev/null | sed 's/^/  /'
cat /sys/class/misc/npu0/dev 2>/dev/null | sed 's/^/  dev: /'
} > $O 2>&1
cat $O

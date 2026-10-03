#!/bin/bash
O=/home/greatwall/step28.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. 关键：npu_dev_name 的值 ==="
grep -rn "npu_dev_name" $T/*.c | sed 's/^/  /'
echo
echo "=== 2. 关键：/sys/class/misc/npu0 属于哪个驱动 ==="
ls -l /sys/class/misc/npu0/ 2>/dev/null | sed 's/^/  /'
echo "  --- driver 链接 ---"
ls -l /sys/class/misc/npu0/device/driver 2>/dev/null | sed 's/^/  /'
readlink -f /sys/class/misc/npu0 2>/dev/null | sed 's/^/  real: /'
echo
echo "=== 3. 关键：我们的模块注册的 misc 设备名 ==="
sudo dmesg | grep -aiE "misc|npu.*register|npu_dev_name" | tail -10 | sed 's/^/  /'
echo
echo "=== 4. 关键：是否有【两个】模块都注册 npu0 ==="
lsmod | grep -iE "npu" | sed 's/^/  /'
echo
echo "=== 5. 关键：/dev/npu0 的创建时间 vs 模块加载时间 ==="
echo "  /dev/npu0: $(stat -c%y /dev/npu0 2>/dev/null)"
echo "  模块加载: $(lsmod | grep phytium_npu | head -1)"
sudo dmesg | grep -a "phytium_npu" | head -5 | sed 's/^/  /'
echo
echo "=== 6. 关键：驱动源码里 miscdev.name 的赋值 ==="
grep -n -B5 "miscdev.name" $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 7. 关键：是否有 vendor 的 npu 模块 ==="
find /lib/modules/$(uname -r) -name "*npu*" 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 8. 关键：/dev/npu0 的 owner/group ==="
ls -l /dev/npu0 | sed 's/^/  /'
echo "  => root:video, 说明是 udev 按规则创建的"
echo
echo "=== 9. udev 规则 ==="
grep -rl "npu" /etc/udev/rules.d/ 2>/dev/null | head -5 | sed 's/^/  /'
} > $O 2>&1
cat $O

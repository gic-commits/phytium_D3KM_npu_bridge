#!/bin/bash
O=/home/greatwall/step22.txt
{
echo "=== 1. 关键：npuworker 的 fd=8 是什么 ==="
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  worker: ${W:-无}"
if [ -n "$W" ]; then
  echo "  --- fd 列表 ---"
  sudo ls -l /proc/$W/fd 2>/dev/null | head -20 | sed 's/^/    /'
fi
echo
echo "=== 2. 关键：ioctl 的 fd 与设备对应 ==="
echo "  strace 显示 ioctl(8, ...) => fd=8"
echo "  需要确认 fd=8 是不是 /dev/npu0"
echo
echo "=== 3. 驱动侧 VHA-CMD 日志的完整内容 ==="
sudo dmesg | grep -a "VHA-CMD" | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 4. 关键：驱动 ioctl 入口的完整代码（1240-1260） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1235 && NR<=1262 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 5. 关键：驱动有几个 file_operations / 几个设备节点 ==="
grep -n "file_operations\|unlocked_ioctl\|misc_register\|cdev_add\|register_chrdev" $T/*.c | head -15 | sed 's/^/  /'
echo
echo "=== 6. /dev 下的 npu 设备 ==="
ls -l /dev/npu* /dev/vha* 2>/dev/null | sed 's/^/  /'
echo
echo "=== 7. 关键：库打开的到底是哪个设备 ==="
sudo grep -ao '"/dev/[^"]*"' /tmp/io2.log 2>/dev/null | sort | uniq -c | sed 's/^/  /'
} > $O 2>&1
cat $O

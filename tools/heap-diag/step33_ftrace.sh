#!/bin/bash
O=/home/greatwall/step33.txt
{
echo "=== 1. 关键：/dev/phy_npu0 的实际指向 ==="
ls -l /dev/phy_npu0 /dev/phy_npu /dev/npu0 2>/dev/null | sed 's/^/  /'
readlink -f /dev/phy_npu0 2>/dev/null | sed 's/^/  real: /'
stat -c "%n: inode=%i major=%t minor=%T" /dev/phy_npu0 /dev/npu0 2>/dev/null | sed 's/^/  /'
echo
echo "=== 2. 关键：是否有【另一个】npu 字符设备 ==="
sudo cat /proc/devices | grep -iE "npu|vha" | sed 's/^/  /'
sudo cat /proc/misc | grep -iE "npu|vha" | sed 's/^/  /'
echo
echo "=== 3. 关键：ftrace 抓 phytium_npu_ioctl 调用 ==="
sudo mount -t tracefs none /sys/kernel/debug/tracing 2>/dev/null || true
sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null
sudo sh -c 'echo > /sys/kernel/debug/tracing/trace' 2>/dev/null
sudo sh -c 'echo phytium_npu_ioctl > /sys/kernel/debug/tracing/set_ftrace_filter' 2>/dev/null
sudo sh -c 'echo function > /sys/kernel/debug/tracing/current_tracer' 2>/dev/null
sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 300 python3 /tmp/sv_pool.py > /dev/null 2>&1
sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on' 2>/dev/null
echo "  --- ftrace 结果 ---"
sudo cat /sys/kernel/debug/tracing/trace 2>/dev/null | grep -c "phytium_npu_ioctl" | sed 's/^/    调用次数: /'
sudo cat /sys/kernel/debug/tracing/trace 2>/dev/null | head -10 | sed 's/^/    /'
echo
echo "=== 4. 关键：驱动侧 VHA-IOCTL-ENTRY 条数 ==="
sudo dmesg | grep -ac "VHA-IOCTL-ENTRY" | sed 's/^/  /'
echo
echo "=== 5. 关键：库调 ioctl 的 fd 与设备对应（重新 strace） ==="
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  worker: ${W:-无}"
if [ -n "$W" ]; then
  sudo timeout 40 strace -f -p $W -e trace=openat,ioctl -s 60 -o /tmp/w3.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/sv_pool.py > /dev/null 2>&1
  sleep 3
  echo "  --- 打开 npu 设备（含 fd） ---"
  sudo grep -aE 'openat.*phy_npu|openat.*npu0' /tmp/w3.log 2>/dev/null | sed 's/^/    /'
  echo "  --- ioctl 的 fd 分布 ---"
  sudo grep -a "ioctl(" /tmp/w3.log 2>/dev/null | grep -oE "ioctl\([0-9]+," | sort | uniq -c | sed 's/^/    /'
fi
} > $O 2>&1
cat $O

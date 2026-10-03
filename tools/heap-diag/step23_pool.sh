#!/bin/bash
O=/home/greatwall/step23.txt
{
echo "=== 1. npusvc_pool 的 fd 列表 ==="
P=$(pgrep -f npusvc_pool | head -1)
echo "  npusvc_pool pid: ${P:-无}"
[ -n "$P" ] && sudo ls -l /proc/$P/fd 2>/dev/null | head -20 | sed 's/^/    /'
echo
echo "=== 2. 关键：谁打开了 /dev/npu0 ==="
sudo fuser -v /dev/npu0 2>&1 | head -10 | sed 's/^/  /'
echo
echo "=== 3. 所有打开 npu 设备的进程 ==="
for p in $(pgrep -f "npu"); do
  f=$(sudo ls -l /proc/$p/fd 2>/dev/null | grep -c "npu")
  [ "$f" -gt 0 ] && echo "  pid=$p ($(cat /proc/$p/comm 2>/dev/null)) 打开 npu 设备 $f 个"
done
echo
echo "=== 4. 关键：厂商服务进程 ==="
ps aux | grep -iE "npu" | grep -v grep | awk '{printf "  %-8s %-6s %s\n", $1, $2, substr($11,1,70)}' | head -10
echo
echo "=== 5. 关键：驱动收到的 ioctl 统计（按 nr） ==="
sudo dmesg | grep -aoE "nr=0x[0-9a-f]+" | sort | uniq -c | sed 's/^/  /'
echo
echo "=== 6. 关键：是否有【另一个】npu 设备节点 ==="
sudo find /dev -name "*npu*" -o -name "*vha*" 2>/dev/null | sed 's/^/  /'
echo
echo "=== 7. 驱动注册的设备 ==="
cat /proc/devices | grep -iE "npu|vha" | sed 's/^/  /'
sudo cat /proc/misc 2>/dev/null | grep -iE "npu|vha" | sed 's/^/  /'
} > $O 2>&1
cat $O

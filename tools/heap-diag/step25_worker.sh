#!/bin/bash
O=/home/greatwall/step25.txt
{
echo "=== 1. 关键：npuworker 打开的设备（含 npu） ==="
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  worker pid: ${W:-无}"
if [ -n "$W" ]; then
  sudo ls -l /proc/$W/fd 2>/dev/null | sed 's/^/    /'
fi
echo
echo "=== 2. 关键：跑一次，抓 worker 的 openat + ioctl ==="
if [ -n "$W" ]; then
  sudo timeout 40 strace -f -p $W -e trace=openat,ioctl -s 100 -o /tmp/w2.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/sv_pool.py > /dev/null 2>&1
  sleep 3
  echo "  --- worker 打开的 npu 设备 ---"
  sudo grep -ao '"/dev/[^"]*npu[^"]*"' /tmp/w2.log 2>/dev/null | sort | uniq -c | sed 's/^/    /'
  echo "  --- worker 的 ioctl 统计（按 nr） ---"
  sudo grep -aoE "_IOC\(_IOC_[A-Z|]*, 0x71, 0x[0-9a-f]+" /tmp/w2.log 2>/dev/null | sed 's/.*0x71, //' | sort | uniq -c | sort -rn | sed 's/^/    /'
  echo "  --- worker 的 ioctl 原始行（前 8） ---"
  sudo grep -a "ioctl" /tmp/w2.log 2>/dev/null | head -8 | sed 's/^/    /'
fi
echo
echo "=== 3. 关键：驱动侧收到的 nr 统计 ==="
sudo dmesg | grep -aoE "nr=0x[0-9a-f]+" | sort | uniq -c | sed 's/^/  /'
echo
echo "=== 4. 关键：驱动 default 分支是否打印 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk '/default:/{print NR": "$0}' $T/phytium_npu_uapi.c | head -3 | sed 's/^/  /'
grep -n "default:" $T/phytium_npu_uapi.c | head -3 | sed 's/^/  /'
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step19.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. 驱动 mmap 实现（1606-1660） ==="
awk 'NR>=1606 && NR<=1660 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 2. mmap 里的日志标签 ==="
grep -n "VHA-MMAP\|dev_info\|dev_warn" $T/phytium_npu_uapi.c | awk -F: '$1>=1606 && $1<=1680' | sed 's/^/  /'
echo
echo "=== 3. dmesg 里 VHA-MMAP 条数 ==="
sudo dmesg | grep -ac "VHA-MMAP" | sed 's/^/  /'
sudo dmesg | grep -a "VHA-MMAP" | tail -5 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 4. 关键：库的 ioctl 调用（用 strace 精确抓） ==="
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  worker: ${W:-无}"
if [ -n "$W" ]; then
  sudo timeout 40 strace -f -p $W -e trace=ioctl -s 200 -o /tmp/io2.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/sv_pool.py > /dev/null 2>&1
  sleep 3
  echo "  --- ioctl 调用（原始行，前 20） ---"
  sudo grep -a "ioctl" /tmp/io2.log 2>/dev/null | head -20 | sed 's/^/    /'
  echo "  --- ioctl 总数 ---"
  sudo grep -ac "ioctl" /tmp/io2.log 2>/dev/null | sed 's/^/    /'
  echo "  --- 含 0x40107109 的 ---"
  sudo grep -ac "0x40107109" /tmp/io2.log 2>/dev/null | sed 's/^/    /'
fi
echo
echo "=== 5. 关键：mmap 的目标 fd ==="
sudo grep -a "mmap" /tmp/io2.log 2>/dev/null | head -5 | sed 's/^/  /'
} > $O 2>&1
cat $O

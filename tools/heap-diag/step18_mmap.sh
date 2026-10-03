#!/bin/bash
O=/home/greatwall/step18.txt
{
echo "=== 1. VHA-CMD 全部 35 条的完整内容 ==="
sudo dmesg | grep -a "VHA-CMD" | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 2. 关键：库是否用了 mmap（看驱动 mmap 实现） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "\.mmap\|phytium_npu_mmap\|dma_mmap" $T/*.c | head -10 | sed 's/^/  /'
echo
echo "=== 3. 库打开的 fd 与 mmap 调用 ==="
echo "  (用 strace 抓 mmap/ioctl)"
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  worker: ${W:-无}"
if [ -n "$W" ]; then
  sudo timeout 30 strace -f -p $W -e trace=ioctl,mmap,openat -s 40 -o /tmp/io.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/sv_pool.py > /dev/null 2>&1
  sleep 3
  echo "  --- worker 的 ioctl 调用统计 ---"
  sudo grep -ao "ioctl([0-9]*, [A-Z0-9_]*, [0-9]*)" /tmp/io.log 2>/dev/null | sed 's/ioctl(\([0-9]*\), \([A-Z0-9_]*\).*/\2/' | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'
  echo "  --- mmap 调用 ---"
  sudo grep -ac "mmap" /tmp/io.log 2>/dev/null | sed 's/^/    条数: /'
  echo "  --- 打开的 npu 设备 ---"
  sudo grep -ao '"/dev/npu[^"]*"' /tmp/io.log 2>/dev/null | sort | uniq -c | sed 's/^/    /'
fi
echo
echo "=== 4. 关键：库是否通过 /dev/npu0 的 mmap 拿内存 ==="
ls -l /dev/npu* 2>/dev/null | sed 's/^/  /'
} > $O 2>&1
cat $O

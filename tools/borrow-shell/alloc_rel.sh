#!/bin/bash
echo "=== 1. 分配 vs 释放（本次 sensevoice 加载） ==="
echo "  ALLOC 次数:      $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
echo "  REALFREE 次数:   $(sudo dmesg | grep -ac 'VHA-REALFREE')"
echo "  REL5 次数:       $(sudo dmesg | grep -ac 'VHA-REL5')"
echo "  REL8 次数:       $(sudo dmesg | grep -ac 'VHA-REL8')"
echo
echo "=== 2. 释放类 ioctl 调用次数 ==="
for c in 0x40047105 0x40087108; do
  echo "  cmd=$c : $(sudo dmesg | grep -ac "cmd=$c")"
done
echo
echo "=== 3. 分配/释放的时间序列（看是否交替） ==="
sudo dmesg | grep -aE "alloc#[0-9]+ size=|VHA-REALFREE|VHA-REL[58]" | tail -30 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 4. 当前 alloc 链表残留（CMA 占用） ==="
awk '/CmaFree/{print "  CmaFree: "$2" kB"}' /proc/meminfo
echo
echo "=== 5. 库是否在段间复用缓冲？（看尺寸序列） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{print $2}' | head -40 | tr '\n' ' ' | fold -w 150 | sed 's/^/  /'

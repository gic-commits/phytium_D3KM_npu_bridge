#!/bin/bash
echo "=== 1. 分配 vs 释放 计数 ==="
echo "  ALLOC(alloc#) 次数: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
echo "  REL5 释放次数:      $(sudo dmesg | grep -ac 'VHA-REL5')"
echo "  REL8 释放次数:      $(sudo dmesg | grep -ac 'VHA-REL8')"
echo "  free_allocs 次数:   $(sudo dmesg | grep -ac 'free_allocs')"
echo
echo "=== 2. 释放类 ioctl 的调用统计 ==="
for c in 0x40047105 0x40087108; do
  echo "  cmd=$c 次数: $(sudo dmesg | grep -ac "cmd=$c")"
done
echo
echo "=== 3. 驱动里释放路径 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "VHA_REL\|vha_free_allocs\|case VHA_" $T/phytium_npu_uapi.c | head -20 | sed 's/^/  /'
echo
echo "=== 4. 最近一次会话的分配/释放序列（末尾 30 条） ==="
sudo dmesg | grep -aE "alloc#[0-9]+ size=|VHA-REL[58]|VHA-CMD] cmd=" | tail -30 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 当前进程/会话 ==="
echo "  npusvc=$(systemctl is-active npusvc)"
pgrep -a npuworker | head -3 | sed 's/^/  /'
echo "  打开 /dev/npu0 的进程:"
sudo fuser -v /dev/npu0 2>&1 | head -6 | sed 's/^/  /'

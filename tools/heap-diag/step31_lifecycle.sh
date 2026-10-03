#!/bin/bash
O=/home/greatwall/step31.txt
{
echo "=== 1. 关键：fd=8 的完整生命周期（open/close/ioctl 按序） ==="
sudo grep -aE "= 8$|= 8 |close\(8\)|ioctl\(8" /tmp/w2.log 2>/dev/null | head -40 | sed 's/^/  /'
echo
echo "=== 2. 关键：close(8) 出现次数 ==="
sudo grep -ac "close(8)" /tmp/w2.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 3. 关键：openat 返回 8 的所有文件 ==="
sudo grep -aE "\) = 8$" /tmp/w2.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 4. 关键：ioctl(8, nr=2) 前后的操作 ==="
sudo grep -an "ioctl(8" /tmp/w2.log 2>/dev/null | head -3 | cut -d: -f1 | while read ln; do
  echo "  --- 行 $ln 前后 5 行 ---"
  sudo sed -n "$((ln-5)),$((ln+2))p" /tmp/w2.log 2>/dev/null | sed 's/^/    /'
done
echo
echo "=== 5. 关键：驱动侧是否真的没收到 nr=2（用 ftrace 验证） ==="
echo "  改用：在驱动 ioctl 入口加 pr_err（无条件）"
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "pr_err.*ioctl\|VHA-IOCTL-ENTRY" $T/phytium_npu_uapi.c | head -3 | sed 's/^/  /'
} > $O 2>&1
cat $O

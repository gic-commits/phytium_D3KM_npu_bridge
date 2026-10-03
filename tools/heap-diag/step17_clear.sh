#!/bin/bash
O=/home/greatwall/step17.txt
{
echo "=== 1. dmesg 缓冲区状态 ==="
echo "  总行数: $(sudo dmesg | wc -l)"
echo "  最早时间戳: $(sudo dmesg | head -1 | sed 's/.*\[\s*\([0-9.]*\)\].*/\1/')"
echo "  最新时间戳: $(sudo dmesg | tail -1 | sed 's/.*\[\s*\([0-9.]*\)\].*/\1/')"
echo "  缓冲区大小: $(cat /proc/sys/kernel/dmesg_restrict 2>/dev/null) (restrict)"
echo
echo "=== 2. 关键：日志是否被环形缓冲冲掉 ==="
echo "  VHA-ALLOC (1962条) 每条约 100 字节 => 约 196 KB"
echo "  CRC 日志 (VHA-CRC-after) 条数: $(sudo dmesg | grep -ac 'VHA-CRC-after')"
echo "  日志缓冲大小: $(dmesg --help 2>/dev/null | head -1; cat /proc/sys/kernel/printk 2>/dev/null)"
echo
echo "=== 3. 关键验证：重新加载一次，立刻抓日志 ==="
echo "  (先清 dmesg，再跑，看 alloc size= 是否出现)"
sudo dmesg -C
sudo systemctl restart npusvc; sleep 8
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 300 python3 /tmp/sv_pool.py > /dev/null 2>&1
echo "  --- 清空后立即统计 ---"
echo "    alloc size= 条数: $(sudo dmesg | grep -ac 'alloc size=')"
echo "    VHA-ALLOC-RAW 条数: $(sudo dmesg | grep -ac 'VHA-ALLOC-RAW')"
echo "    VHA-ALLOC-DIAG 条数: $(sudo dmesg | grep -ac 'VHA-ALLOC-DIAG')"
echo "    VHA-ALLOC] 条数: $(sudo dmesg | grep -ac 'VHA-ALLOC\]')"
echo "    VHA-CMD 条数: $(sudo dmesg | grep -ac 'VHA-CMD')"
echo "    总行数: $(sudo dmesg | wc -l)"
echo
echo "  --- alloc size= 样例 ---"
sudo dmesg | grep -a "alloc size=" | head -5 | sed 's/.*\] //' | sed 's/^/    /'
echo
echo "  --- VHA-ALLOC-DIAG 样例（27MB 附近） ---"
sudo dmesg | grep -a "VHA-ALLOC-DIAG" | tail -8 | sed 's/.*\] //' | sed 's/^/    /'
echo
echo "  --- 报错 ---"
sudo tail -12 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'
} > $O 2>&1
cat $O

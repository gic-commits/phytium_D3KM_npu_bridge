#!/bin/bash
O=/home/greatwall/step40.txt
{
echo "=== 1. 本次是否新增 failed to allocate ==="
sudo grep -a "failed to allocate" /var/log/npuworker.log 2>/dev/null | tail -3 | sed 's/^/  /'
echo "  本次日志时间: $(date)"
echo
echo "=== 2. 关键：库 AllocateMemory 的失败分支（0x121e8 起，找 FATAL 串引用） ==="
L=/usr/local/lib/libnpusession.so
strings -t x $L | grep -i "failed to allocate" | sed 's/^/  /'
echo
echo "=== 3. 关键：库的 AllocateMemory 完整反汇编（0x121e8 - 0x12600） ==="
objdump -d --start-address=0x121e8 --stop-address=0x12600 $L 2>/dev/null > /tmp/am.asm
wc -l /tmp/am.asm | sed 's/^/  行数: /'
echo "  --- 关键指令（bl 调用、cmp、b.eq） ---"
grep -nE "bl\s|cbz|cbnz|cmp\s+w|b\.(eq|ne|hi|ls|cs|cc)" /tmp/am.asm | head -40 | sed 's/^/    /'
echo
echo "=== 4. 关键：库调用的分配函数 ==="
grep -oE "bl\s+[0-9a-f]+ <[^>]+>" /tmp/am.asm | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
echo
echo "=== 5. 关键：库是否调用了 ioctl ==="
grep -c "ioctl" /tmp/am.asm | sed 's/^/  /'
} > $O 2>&1
cat $O

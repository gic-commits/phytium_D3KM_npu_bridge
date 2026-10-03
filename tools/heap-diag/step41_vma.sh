#!/bin/bash
O=/home/greatwall/step41.txt
{
L=/usr/local/lib/libnpusession.so
echo "=== 1. VhaMemoryImp::Allocate 完整反汇编（0x14be8 - 0x15000） ==="
objdump -d --start-address=0x14be8 --stop-address=0x15000 $L 2>/dev/null > /tmp/vma.asm
wc -l /tmp/vma.asm | sed 's/^/  行数: /'
echo
echo "=== 2. 关键：它调用了什么 ==="
grep -oE "bl\s+[0-9a-f]+ <[^>]+>" /tmp/vma.asm | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
echo
echo "=== 3. 关键：是否有 ioctl ==="
grep -nE "ioctl|svc" /tmp/vma.asm | head -10 | sed 's/^/  /'
echo
echo "=== 4. 关键：失败分支（找 0x80338 串引用） ==="
grep -nE "adrp.*0x80000|add.*0x338" /tmp/vma.asm | head -10 | sed 's/^/  /'
echo
echo "=== 5. 关键：完整指令流（前 80 行） ==="
head -80 /tmp/vma.asm | sed 's/^/  /'
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step42.txt
{
L=/usr/local/lib/libnpusession.so
echo "=== 1. AllocateVhaMem 完整反汇编（0x77240 - 0x77ab0） ==="
objdump -d --start-address=0x77240 --stop-address=0x77ab0 $L 2>/dev/null > /tmp/avm.asm
wc -l /tmp/avm.asm | sed 's/^/  行数: /'
echo
echo "=== 2. 关键：它调用了什么 ==="
grep -oE "bl\s+[0-9a-f]+ <[^>]+>" /tmp/avm.asm | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
echo
echo "=== 3. 关键：是否有 ioctl / svc ==="
grep -nE "ioctl|svc\s+#0" /tmp/avm.asm | head -10 | sed 's/^/  /'
echo
echo "=== 4. 关键：失败分支与比较 ==="
grep -nE "cmp\s+w[0-9]+, #0x|cbz|cbnz|b\.(eq|ne|hi|ls|cs|cc|gt|lt)" /tmp/avm.asm | head -30 | sed 's/^/  /'
echo
echo "=== 5. 关键：完整指令流（前 100 行） ==="
head -100 /tmp/avm.asm | sed 's/^/  /'
} > $O 2>&1
cat $O

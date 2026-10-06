#!/bin/bash
# 找：谁对 WaitForCompletion 等待的 condvar (this+0x98) 发 notify
L=/usr/local/lib/libnpusession.so
echo "=== 1) notify 相关符号 ==="
nm -C "$L" 2>/dev/null | grep -aiE "notify_all|notify_one|VhaNotifyImp" | head -10
echo
echo "=== 2) 反汇编里所有 'add xN, xM, #0x98' 后紧跟 bl 的位置 ==="
objdump -d "$L" 2>/dev/null | grep -aB2 -aA3 "add\s*x[0-9]*, x[0-9]*, #0x98$" | grep -aE "^[0-9a-f]+ <|add\s+x[0-9]*, x[0-9]*, #0x98$|bl\s+[0-9a-f]+ <" | head -40

#!/bin/bash
L=/usr/local/lib/libnpusession.so
echo "=== Signal / Update 符号地址 ==="
nm -C "$L" 2>/dev/null | grep -aE "VhaNotifyImp(6Signal|6Update)|VhaNotifyImp::Signal|VhaNotifyImp::Update" | head -6
echo
echo "=== 谁调用 Signal (0x16568) ==="
objdump -d "$L" 2>/dev/null | grep -aB1 "bl\s*16568" | grep -aE "^[0-9a-f]+ <|bl\s*16568" | head -12
echo
echo "=== 谁调用 Update (0x16310) ==="
objdump -d "$L" 2>/dev/null | grep -aB1 "bl\s*16310" | grep -aE "^[0-9a-f]+ <|bl\s*16310" | head -12
echo
echo "=== 导出符号表里是否有 Signal/Update（供 phydnn 调用）==="
nm -D "$L" 2>/dev/null | grep -aiE "notify.*(signal|update)|WaitForCompletion" | head -6

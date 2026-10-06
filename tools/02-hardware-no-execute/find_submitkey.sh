#!/bin/bash
L=/usr/local/lib/libnpusession.so
echo "=== SetSubmitKey / GetSubmitKey 地址 ==="
nm -C "$L" 2>/dev/null | grep -aE "SubmitKey|SwProcKey" | head -6
echo
echo "=== 谁调用 GetSubmitKey (0x33680) ==="
objdump -d "$L" 2>/dev/null | grep -aB2 "bl\s*33680" | grep -aE "^[0-9a-f]+ <|bl\s*33680" | head -14
echo
echo "=== 谁调用 SetSubmitKey (0x337e0) ==="
objdump -d "$L" 2>/dev/null | grep -aB2 "bl\s*337e0" | grep -aE "^[0-9a-f]+ <|bl\s*337e0" | head -14

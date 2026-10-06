#!/bin/bash
L=/usr/local/lib/libnpusession.so
echo "=== 所有写 [xN, #2]（strh）的位置 ==="
objdump -d "$L" 2>/dev/null | grep -aE "strh\s+w[0-9]+, \[x[0-9]+, #2\]" | head -20
echo
echo "=== 带上所属函数（取每个匹配前的函数标签）==="
objdump -d "$L" 2>/dev/null | awk '
/^[0-9a-f]+ <.*>:$/ { fn=$0 }
/strh\s+w[0-9]+, \[x[0-9]+, #2\]/ { if (fn != "") { print fn; print "    " $0; fn="" } }
' | head -24

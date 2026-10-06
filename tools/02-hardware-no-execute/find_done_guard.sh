#!/bin/bash
L=/usr/local/lib/libnpusession.so
echo "=== VhaDnnTask::Done 相关符号 ==="
nm -C "$L" 2>/dev/null | grep -aE "VhaDnnTask.*Done" | head -10
echo
echo "=== Done 的构造函数地址（C1/C2）==="
nm "$L" 2>/dev/null | grep -aE "VhaDnnTask4DoneC" | head -4
echo
echo "=== 谁调用 Done 的 ctor/dtor ==="
for A in $(nm "$L" 2>/dev/null | grep -aE "VhaDnnTask4Done(C1|C2|D1|D2|D0)" | awk '{print $1}' | head -4); do
  echo "--- 目标 0x$A ---"
  objdump -d "$L" 2>/dev/null | grep -aB3 "bl\s*$A" | grep -aE "^[0-9a-f]+ <|bl\s*$A" | tail -8
done

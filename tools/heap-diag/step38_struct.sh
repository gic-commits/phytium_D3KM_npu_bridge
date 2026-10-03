#!/bin/bash
O=/home/greatwall/step38.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. struct npu_info 完整定义 ==="
grep -n -A20 "struct npu_info {" $T/include/phytium_npu_uapi.h | head -25 | sed 's/^/  /'
echo
echo "=== 2. 各字段偏移 ==="
python3 - <<'PYEOF'
import re
p = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/include/phytium_npu_uapi.h"
src = open(p, errors='replace').read()
m = re.search(r'struct npu_info \{(.*?)\};', src, re.S)
if m:
    body = m.group(1)
    off = 0
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith('/*') or line.startswith('*'):
            continue
        mm = re.match(r'(u\d+|char)\s+(\w+)(\[(\d+)\])?;', line)
        if mm:
            typ, name, _, arr = mm.groups()
            size = {'u8':1,'u16':2,'u32':4,'u64':8}.get(typ, 1)
            if arr: size *= int(arr)
            print(f"  偏移 {off:3d} (0x{off:02x}): {typ} {name}{'['+arr+']' if arr else ''}")
            off += size
    print(f"  总大小: {off} 字节")
else:
    print("  未找到 struct npu_info")
PYEOF
echo
echo "=== 3. 关键：库读 npu_info 的哪个字段 ==="
L=/usr/local/lib/libnpusession.so
echo "  找库里的 GetInfo 调用后读取偏移的代码"
nm -DC $L 2>/dev/null | grep -iE "GetInfo|Info" | head -10 | sed 's/^/  /'
echo
echo "=== 4. 关键：厂商驱动返回什么（从手册/材料） ==="
grep -rn "l1_size\|l3_size\|l3_percore" /home/greatwall/下载/kylin/D3000M_NPU/*.md 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 5. 关键：D3000M 的 L3 缓存大小（从调研报告） ==="
grep -iE "L3|缓存|OCM|SRAM" "/home/greatwall/下载/kylin/D3000M_NPU/2026-09-26-NPU调研报告-完整版.md" 2>/dev/null | head -15 | sed 's/^/  /'
} > $O 2>&1
cat $O

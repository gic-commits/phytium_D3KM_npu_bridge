#!/bin/bash
cd /tmp/mbsprobe/all
F=$(find . -name 'npu_mbs.oCCWLX' | head -1)
echo "=== 目标 MBS: $F ($(stat -c%s $F) B) ==="
python3 - "$F" <<'PYEOF'
import sys, struct
d = open(sys.argv[1],'rb').read()
print(f"  大小: {len(d)}")
print(f"  头 48 字节: {d[:48].hex(' ')}")
print()
print("=== 找 457776 / 913920 / 448000 的偏移与上下文 ===")
for v in (457776, 913920, 448000, 228480):
    p = d.find(struct.pack('<I', v))
    while p >= 0:
        # 上下文：前后 32 字节
        lo, hi = max(0,p-16), min(len(d), p+20)
        ctx = d[lo:hi]
        # 按 u32 解析上下文
        vals = []
        for i in range(0, len(ctx)-3, 4):
            vals.append(struct.unpack_from('<I', ctx, i)[0])
        print(f"  {v} @ 0x{p:x}:")
        print(f"    原始: {ctx.hex(' ')}")
        print(f"    u32 : {[hex(x) for x in vals]}")
        p = d.find(struct.pack('<I', v), p+1)
        if p > 0 and p < 0x10000:
            pass
        break
PYEOF
echo
echo "=== 全文件 u32 扫描：找所有"看起来像尺寸"的值（>=1000 且 < 10000000） ==="
python3 - "$F" <<'PYEOF'
import sys, struct
d = open(sys.argv[1],'rb').read()
print(f"  文件大小 {len(d)}")
# 扫描所有 u32，找 448000 附近的值
for off in range(0, min(len(d), 4096), 4):
    v = struct.unpack_from('<I', d, off)[0]
    if 200000 < v < 2000000:
        print(f"    0x{off:04x}: {v}  (x448000 = {v/448000:.4f}, x228480 = {v/228480:.4f})")
PYEOF

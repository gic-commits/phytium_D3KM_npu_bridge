#!/usr/bin/env python3
# 批量修正：把所有 MBS 里的"容量"字段改成"要求"字段的值
# 规律：容量 = 基准 x 2.0036(不精确)，要求 = 基准 x 4(精确)
# 做法：找 (a, type) 后面 16 字节处是 (b, type2) 且 b ≈ 2a 的，把 a 改成 b
import glob, struct, os, sys

DRY = os.environ.get('DRY', '1') == '1'
OUT = '/tmp/mbsprobe/fixed'
os.makedirs(OUT, exist_ok=True)

files = sorted(glob.glob('/tmp/mbsprobe/all/npu_mbs.*'))
total_fixes = 0
report = []
for f in files:
    d = bytearray(open(f,'rb').read())
    n = 0
    for off in range(0, len(d)-20, 4):
        a = struct.unpack_from('<I', d, off)[0]
        ta = struct.unpack_from('<I', d, off+4)[0]
        if a < 1000 or a > 50_000_000 or not (1 <= ta <= 8): continue
        b = struct.unpack_from('<I', d, off+16)[0]
        tb = struct.unpack_from('<I', d, off+20)[0]
        if not (1 <= tb <= 8): continue
        # b 应约等于 2a（允许 0.5% 误差，因为容量用了 2.0036 倍）
        if 1.99*a <= b <= 2.01*a and abs(b - 2*a) > 0:
            struct.pack_into('<I', d, off, b)
            n += 1
            if n <= 3:
                report.append(f"    {f.split('/')[-1]} @0x{off:04x}: {a} -> {b} (type {ta}->{tb})")
    if n:
        total_fixes += n
        if not DRY:
            open(os.path.join(OUT, os.path.basename(f)),'wb').write(bytes(d))

print(f"=== {'DRY RUN' if DRY else '实际写入'} ===")
print(f"  扫描 {len(files)} 个 MBS 文件")
print(f"  共修正 {total_fixes} 处")
print("  样例:")
for r in report[:15]:
    print(r)
if not DRY:
    print(f"  已写出到 {OUT}/")

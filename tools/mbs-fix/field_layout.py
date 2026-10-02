#!/usr/bin/env python3
import glob, struct
f = '/tmp/mbsprobe/all/npu_mbs.10PgI0'
d = open(f,'rb').read()
print(f"=== {f.split('/')[-1]} ({len(d)} B) ===")
print()
print("=== 0x340 - 0x390 完整 u32 视图 ===")
for off in range(0x340, 0x390, 16):
    vals = struct.unpack_from('<4I', d, off)
    marks = []
    for i,v in enumerate(vals):
        o = off+i*4
        if o == 0x358: marks.append("<-- 418608 容量")
        if o == 0x368: marks.append("<-- 835584 要求")
    print(f"  0x{off:04x}: " + "  ".join(f"{v:>10}" for v in vals) + ("  "+" ".join(marks) if marks else ""))
print()
print("=== 关键：0x358 与 0x368 之间有什么 ===")
for off in range(0x350, 0x378, 4):
    v = struct.unpack_from('<I', d, off)[0]
    tag = ""
    if off == 0x358: tag = "  <== 容量"
    if off == 0x368: tag = "  <== 要求"
    print(f"  0x{off:04x}: {v}{tag}")
print()
print("=== 全文件：找所有 (容量, 要求) 对（要求 = 2*容量） ===")
# 扫描所有 u32，找 a 与 2a 都在文件里且相隔 16 字节的
n = 0
for off in range(0, min(len(d), 0x2000)-4, 4):
    a = struct.unpack_from('<I', d, off)[0]
    if a < 1000 or a > 50_000_000: continue
    b = struct.unpack_from('<I', d, off+16)[0]
    if b == a*2:
        print(f"  0x{off:04x}: {a}  ->  0x{off+16:04x}: {b}   (2x)")
        n += 1
print(f"  共 {n} 对")

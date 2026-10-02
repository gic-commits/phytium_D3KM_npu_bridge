#!/usr/bin/env python3
# 实验：把 MBS 里 457776 改成 913920（让库分配时拿到正确容量）
# 只改 npu_mbs.oCCWLX 这一个文件，重打包 tar，验证是否越过报错
import shutil, struct, os, sys, subprocess

SRC = "/tmp/mbsprobe/all/npu_mbs.oCCWLX"
DST = "/tmp/mbsprobe/oCCWLX_fixed"
d = bytearray(open(SRC,'rb').read())
off = 0x2a8
old = struct.unpack_from('<I', d, off)[0]
print(f"  0x{off:04x}: {old} -> 913920")
if old != 457776:
    print("  !! 值不符，中止"); sys.exit(1)
struct.pack_into('<I', d, off, 913920)
open(DST,'wb').write(bytes(d))
print(f"  已写出 {DST} ({len(d)} B)")

# 校验：只改了这一个位置
a = open(SRC,'rb').read(); b = open(DST,'rb').read()
diffs = [i for i in range(len(a)) if a[i]!=b[i]]
print(f"  差异字节数: {len(diffs)} @ {[hex(x) for x in diffs]}")
print(f"  改后 0x2a8 = {struct.unpack_from('<I', b, 0x2a8)[0]}")
print(f"  改后 0x2e8 = {struct.unpack_from('<I', b, 0x2e8)[0]} (应仍为 913920)")

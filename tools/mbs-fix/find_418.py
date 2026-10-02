#!/usr/bin/env python3
import glob, struct
print("=== 找 418608 / 835584 在哪个 MBS ===")
for v in (418608, 835584, 457776, 913920):
    pat = struct.pack('<I', v)
    hits = []
    for f in sorted(glob.glob('/tmp/mbsprobe/all/npu_mbs.*')):
        d = open(f,'rb').read()
        p = d.find(pat)
        if p >= 0:
            hits.append((f.split('.')[-1], hex(p)))
    print(f"  {v}: {hits[:4]}")

print()
print("=== 在 oCCWLX 里找 418608 / 835584 ===")
d = open('/tmp/mbsprobe/all/npu_mbs.oCCWLX','rb').read()
for v in (418608, 835584):
    p = 0; offs = []
    while True:
        p = d.find(struct.pack('<I', v), p)
        if p < 0: break
        offs.append(p); p += 1
    print(f"  {v}: {[hex(x) for x in offs]}")
    for o in offs[:3]:
        prev = struct.unpack_from('<I', d, o-4)[0] if o>=4 else 0
        nxt = struct.unpack_from('<I', d, o+4)[0]
        print(f"    @0x{o:04x}: ({prev}, {v}, {nxt})")

print()
print("=== 全表配对：a 与 2a 同时存在 ===")
pairs = []
for off in range(0, min(len(d), 0x1000), 4):
    a, b = struct.unpack_from('<II', d, off)
    if 1000 <= a <= 100_000_000 and 1 <= b <= 8:
        pairs.append((off, a, b))
print(f"  共 {len(pairs)} 项")
vals = {a for _,a,_ in pairs}
n = 0
for off, a, b in pairs:
    if a*2 in vals:
        print(f"    0x{off:04x}: {a} (type={b})  -> 2x={a*2} 存在")
        n += 1
print(f"  共 {n} 对")

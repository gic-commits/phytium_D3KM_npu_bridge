#!/usr/bin/env python3
import glob, struct, os
D = '/tmp/mbsrebuild'
print("=== 在重建后的 tar 解包目录里搜 418608 ===")
pat = struct.pack('<I', 418608)
hits = []
for f in sorted(glob.glob(D+'/*')):
    if os.path.isdir(f): continue
    try:
        d = open(f,'rb').read()
    except Exception:
        continue
    p = 0
    offs = []
    while True:
        p = d.find(pat, p)
        if p < 0: break
        offs.append(p); p += 1
    if offs:
        hits.append((os.path.basename(f), offs))
print(f"  {len(hits)} 个文件命中:")
for f, offs in hits[:20]:
    print(f"    {f}: {[hex(x) for x in offs[:5]]}")

print()
print("=== 同时搜 457776 / 913920 / 835584 ===")
for v in (457776, 913920, 835584, 418608):
    p = struct.pack('<I', v)
    n = 0; files = []
    for f in sorted(glob.glob(D+'/*')):
        if os.path.isdir(f): continue
        try: d = open(f,'rb').read()
        except Exception: continue
        if p in d:
            n += d.count(p); files.append(os.path.basename(f))
    print(f"  {v}: {n} 处, {len(files)} 个文件 {files[:4]}")

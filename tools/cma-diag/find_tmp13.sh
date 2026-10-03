#!/bin/bash
echo "=== 1. TMP-13 在 MBS 里的位置 ==="
python3 - <<'PYEOF'
import glob, struct, os
pat = b'TMP-13'
for f in sorted(glob.glob('/tmp/scan3/npu_mbs.*')):
    try: d = open(f,'rb').read()
    except Exception: continue
    p = d.find(pat)
    if p >= 0:
        print(f"  {os.path.basename(f)}: @0x{p:x}")
        # 上下文
        lo = max(0, p-48)
        print(f"    上下文 0x{lo:04x}:")
        for off in range(lo, min(len(d), p+32), 4):
            v = struct.unpack_from('<I', d, off)[0]
            tag = ""
            if off == p: tag = " <== TMP-13"
            if v == 28459008: tag = " <== 27.1MB"
            if v == 31252480: tag = " <== 29.8MB"
            print(f"      0x{off:04x}: {v:>12}{tag}")
PYEOF
echo
echo "=== 2. 所有 TMP-* 缓冲 ==="
python3 - <<'PYEOF'
import glob, re, os
for f in sorted(glob.glob('/tmp/scan3/npu_mbs.*')):
    try: d = open(f,'rb').read()
    except Exception: continue
    for m in re.finditer(rb'TMP-\d+', d):
        print(f"  {os.path.basename(f)}: {m.group().decode()} @0x{m.start():x}")
PYEOF
echo
echo "=== 3. 关键：TMP-13 的尺寸字段 ==="
python3 - <<'PYEOF'
import glob, struct, os
for f in sorted(glob.glob('/tmp/scan3/npu_mbs.*')):
    try: d = open(f,'rb').read()
    except Exception: continue
    p = d.find(b'TMP-13')
    if p < 0: continue
    # 名字前 16 字节通常是 (size, flags)
    print(f"  {os.path.basename(f)} TMP-13 @0x{p:x}:")
    for off in range(max(0,p-32), p, 4):
        v = struct.unpack_from('<I', d, off)[0]
        print(f"    0x{off:04x}: {v} ({hex(v)})")
PYEOF

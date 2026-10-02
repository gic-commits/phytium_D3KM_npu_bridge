#!/bin/bash
cd /tmp/mbsprobe/all
F=$(find . -name 'npu_mbs.oCCWLX' | head -1)
python3 - "$F" <<'PYEOF'
import sys, struct
d = open(sys.argv[1],'rb').read()
print(f"=== {sys.argv[1]} ({len(d)} B) ===")
print()
print("=== 0x270 - 0x310 完整 u32 视图（含 457776 与 913920） ===")
for off in range(0x270, 0x310, 16):
    vals = struct.unpack_from('<4I', d, off)
    marks = []
    for i,v in enumerate(vals):
        o = off + i*4
        if o == 0x2a8: marks.append(f"<-- 457776 @0x{o:x}")
        if o == 0x2e8: marks.append(f"<-- 913920 @0x{o:x}")
    line = f"  0x{off:04x}: " + "  ".join(f"{v:>10}" for v in vals)
    print(line + ("  " + " ".join(marks) if marks else ""))
print()
print("=== 关键：这两个位置是否在同一个结构里 ===")
print("  0x2a8 与 0x2e8 相差", 0x2e8-0x2a8, "字节 =", (0x2e8-0x2a8)//4, "个 u32")
print()
print("=== 0x280 - 0x2f0 逐项解读（尺寸,类型 对） ===")
for off in range(0x280, 0x2f0, 8):
    a, b = struct.unpack_from('<II', d, off)
    tag = ""
    if a == 457776: tag = "  <== 库报的容量"
    if a == 913920: tag = "  <== 段IO要的尺寸"
    print(f"  0x{off:04x}: size={a:>10}  type={b}{tag}")
PYEOF
echo
echo "=== 对照：tarfix 里的同名文件（当初手工修过的） ==="
ls -l /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/ 2>/dev/null | grep -E "oCCWLX|P11mzB" | sed 's/^/  /'
echo
echo "=== 对比两个版本的 oCCWLX ==="
for f in /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/npu_mbs.oCCWLX /tmp/mbsprobe/all/npu_mbs.oCCWLX; do
  [ -f "$f" ] && echo "  $f: $(stat -c%s $f) B  md5=$(md5sum $f | cut -c1-16)"
done

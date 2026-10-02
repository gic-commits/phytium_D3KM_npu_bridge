#!/bin/bash
# 批量修正所有 MBS 的"容量"字段，重建 tar
set -e
cd /tmp/mbsrebuild

echo "=== 1. 批量修正（容量 -> 要求） ==="
python3 - <<'PYEOF'
import glob, struct, os
files = sorted(glob.glob('/tmp/mbsrebuild/npu_mbs.*'))
total = 0
detail = []
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
        if 1.99*a <= b <= 2.01*a and b != 2*a:
            struct.pack_into('<I', d, off, b)
            n += 1
            if len(detail) < 8:
                detail.append(f"    {os.path.basename(f)} @0x{off:04x}: {a} -> {b}")
    if n:
        open(f,'wb').write(bytes(d))
        total += n
print(f"  修正 {total} 处，涉及 {len([f for f in files])} 个文件")
for x in detail: print(x)
PYEOF

echo
echo "=== 2. 重建 tar ==="
sudo tar -cf /opt/npu/model/sensevoice.tar.new ./* 2>/dev/null
sudo mv /opt/npu/model/sensevoice.tar.new /opt/npu/model/sensevoice.tar
echo "  tar: $(stat -c%s /opt/npu/model/sensevoice.tar) B, $(sudo tar -tf /opt/npu/model/sensevoice.tar | wc -l) 文件"
echo "  校验:"
sudo tar -xf /opt/npu/model/sensevoice.tar -O ./npu_mbs.10PgI0 2>/dev/null | python3 -c "import sys,struct; d=sys.stdin.buffer.read(); print('    10PgI0 @0x358 =', struct.unpack_from('<I',d,0x358)[0])"
sudo tar -xf /opt/npu/model/sensevoice.tar -O ./npu_mbs.oCCWLX 2>/dev/null | python3 -c "import sys,struct; d=sys.stdin.buffer.read(); print('    oCCWLX @0x2a8 =', struct.unpack_from('<I',d,0x2a8)[0])"

echo
echo "=== 3. 跑 SenseVoice ==="
sudo systemctl restart npusvc; sleep 8
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo "  --- npuworker 日志尾 ---"
sudo tail -12 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'

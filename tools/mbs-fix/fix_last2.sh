#!/bin/bash
# 修正最后两个漏网的 418608，重建 tar，验证
set -e
cd /tmp/scan2
echo "=== 1. 修正最后两个文件 ==="
python3 - <<'PYEOF'
import struct
for f, off in [('npu_mbs.TxUPrL', 0x358), ('npu_mbs.tK3dsy', 0x240)]:
    d = bytearray(open(f,'rb').read())
    old = struct.unpack_from('<I', d, off)[0]
    if old != 418608:
        print(f"  {f} @0x{off:04x} = {old} (不是 418608，跳过)"); continue
    struct.pack_into('<I', d, off, 835584)
    open(f,'wb').write(bytes(d))
    print(f"  {f} @0x{off:04x}: {old} -> 835584")
PYEOF

echo
echo "=== 2. 确认全 tar 无残留 418608 ==="
python3 -c "
import glob,struct,os
n=0
for f in sorted(glob.glob('/tmp/scan2/*')):
    if os.path.isdir(f): continue
    try: d=open(f,'rb').read()
    except: continue
    c=d.count(struct.pack('<I',418608))
    if c: n+=c; print(f'  残留: {os.path.basename(f)} x{c}')
print(f'  418608 残留总数: {n}')
"

echo
echo "=== 3. 重建 tar ==="
sudo tar -cf /opt/npu/model/sensevoice.tar.new ./* 2>/dev/null
sudo mv /opt/npu/model/sensevoice.tar.new /opt/npu/model/sensevoice.tar
echo "  tar: $(stat -c%s /opt/npu/model/sensevoice.tar) B, $(sudo tar -tf /opt/npu/model/sensevoice.tar | wc -l) 文件"

echo
echo "=== 4. 跑 SenseVoice ==="
sudo systemctl restart npusvc; sleep 8
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo "  --- npuworker 日志尾 ---"
sudo tail -14 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'

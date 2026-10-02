#!/bin/bash
# 正确做法：重建整个 tar（不用 -uf 追加）
set -e
cd /tmp/mbsprobe/all

echo "=== 1. 恢复原 tar（清掉追加的重复项） ==="
sudo cp -f /opt/npu/model/sensevoice.tar.bak_mbsfix_* /opt/npu/model/sensevoice.tar 2>/dev/null || true
ls -l /opt/npu/model/sensevoice.tar* 2>/dev/null | sed 's/^/  /'
echo "  文件数: $(sudo tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | wc -l)"

echo
echo "=== 2. 确认本地文件已是修正版 ==="
python3 -c "
import struct
for f,off,exp in [('npu_mbs.oCCWLX',0x2a8,913920),('npu_mbs.10PgI0',0x358,835584)]:
    d=open(f,'rb').read()
    v=struct.unpack_from('<I',d,off)[0]
    print(f'  {f} @0x{off:04x} = {v}  {\"OK\" if v==exp else \"!! 不符\"}')
"

echo
echo "=== 3. 重建 tar（保留原文件顺序，替换目标文件） ==="
# 先解出全部文件到干净目录
rm -rf /tmp/mbsrebuild && mkdir -p /tmp/mbsrebuild
cd /tmp/mbsrebuild
sudo tar -xf /opt/npu/model/sensevoice.tar
echo "  解出 $(ls | wc -l) 个文件"
# 用修正版覆盖
sudo cp -f /tmp/mbsprobe/all/npu_mbs.oCCWLX ./npu_mbs.oCCWLX
sudo cp -f /tmp/mbsprobe/all/npu_mbs.10PgI0 ./npu_mbs.10PgI0
python3 -c "
import struct
d=open('npu_mbs.oCCWLX','rb').read()
print('  覆盖后 oCCWLX @0x2a8 =', struct.unpack_from('<I',d,0x2a8)[0])
"
# 重建
sudo tar -cf /opt/npu/model/sensevoice.tar.new ./* 2>/dev/null
sudo mv /opt/npu/model/sensevoice.tar.new /opt/npu/model/sensevoice.tar
echo "  新 tar: $(stat -c%s /opt/npu/model/sensevoice.tar) B, $(sudo tar -tf /opt/npu/model/sensevoice.tar | wc -l) 个文件"
echo "  校验 tar 内值:"
sudo tar -xf /opt/npu/model/sensevoice.tar -O ./npu_mbs.oCCWLX 2>/dev/null | python3 -c "
import sys,struct
d=sys.stdin.buffer.read()
print('    oCCWLX @0x2a8 =', struct.unpack_from('<I',d,0x2a8)[0])
"

echo
echo "=== 4. 跑 SenseVoice ==="
sudo systemctl restart npusvc; sleep 8
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo "  --- npuworker 日志尾 ---"
sudo tail -10 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'

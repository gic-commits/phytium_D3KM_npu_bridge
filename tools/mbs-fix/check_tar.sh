#!/bin/bash
echo "=== 1. tar 里 oCCWLX / 10PgI0 的实际内容（是否被替换） ==="
for f in npu_mbs.oCCWLX npu_mbs.10PgI0; do
  echo "  --- $f ---"
  echo "    tar 内 0x2a8/0x358 值:"
  sudo tar -xf /opt/npu/model/sensevoice.tar -O ./$f 2>/dev/null > /tmp/t_$f
  python3 -c "
import struct,sys
d=open('/tmp/t_$f','rb').read()
print('      size:',len(d))
for off in (0x2a8,0x358,0x2e8,0x368):
    if off+4<=len(d):
        print(f'      0x{off:04x}: {struct.unpack_from(\"<I\",d,off)[0]}')
"
  echo "    本地文件:"
  python3 -c "
import struct
d=open('/tmp/mbsprobe/all/$f','rb').read()
for off in (0x2a8,0x358,0x2e8,0x368):
    if off+4<=len(d):
        print(f'      0x{off:04x}: {struct.unpack_from(\"<I\",d,off)[0]}')
"
done
echo
echo "=== 2. tar 里文件数（-uf 是否追加了重复项） ==="
echo "  oCCWLX 出现次数: $(sudo tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | grep -c 'oCCWLX')"
echo "  10PgI0 出现次数: $(sudo tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | grep -c '10PgI0')"
echo "  总文件数: $(sudo tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | wc -l)"
echo
echo "=== 3. 库实际读的是哪个路径（看 worker 的打开文件） ==="
W=$(pgrep -f npuworker | head -1)
echo "  worker pid: ${W:-无}"
if [ -n "$W" ]; then
  sudo ls -l /proc/$W/cwd 2>/dev/null | sed 's/^/    cwd: /'
  sudo ls -l /proc/$W/fd 2>/dev/null | grep -v "socket\|pipe\|null\|urandom" | head -15 | sed 's/^/    /'
fi

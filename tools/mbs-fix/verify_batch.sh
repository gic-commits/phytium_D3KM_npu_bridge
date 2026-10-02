#!/bin/bash
echo "=== 1. tar 状态（只读） ==="
ls -l /opt/npu/model/sensevoice.tar | sed 's/^/  /'
echo "  文件数: $(sudo tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | wc -l)"
echo
echo "=== 2. tar 内关键值（只读） ==="
for f in npu_mbs.oCCWLX npu_mbs.10PgI0; do
  sudo tar -xf /opt/npu/model/sensevoice.tar -O ./$f 2>/dev/null | python3 -c "
import sys,struct
d=sys.stdin.buffer.read()
print(f'  $f: size={len(d)}')
for off in (0x2a8,0x358,0x2e8,0x368):
    if off+4<=len(d): print(f'    0x{off:04x}: {struct.unpack_from(\"<I\",d,off)[0]}')
"
done
echo
echo "=== 3. tar 里还剩多少 418608（只读） ==="
rm -rf /tmp/scan2 && mkdir -p /tmp/scan2 && cd /tmp/scan2
sudo tar -xf /opt/npu/model/sensevoice.tar 2>/dev/null
python3 -c "
import glob,struct,os
n=0; fs=[]
for f in sorted(glob.glob('/tmp/scan2/*')):
    if os.path.isdir(f): continue
    try: d=open(f,'rb').read()
    except: continue
    c=d.count(struct.pack('<I',418608))
    if c: n+=c; fs.append(os.path.basename(f))
print(f'  418608 剩余 {n} 处, {len(fs)} 个文件')
print('  样例:', fs[:6])
"
echo
echo "=== 4. 库真正读哪个文件：strace npuworker ==="
W=$(pgrep -f npuworker | head -1)
echo "  当前 worker: ${W:-无}"
sudo systemctl restart npusvc; sleep 6
W=$(pgrep -f npuworker | head -1)
echo "  重启后 worker: ${W:-无}"
if [ -n "$W" ]; then
  sudo timeout 20 strace -f -p $W -e trace=openat,read -o /tmp/w.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/sv_pool.py > /tmp/sv2.log 2>&1
  sleep 3
  echo "  --- worker 打开的文件（含 mbs/json/params） ---"
  sudo grep -aoE '"[^"]*(npu_mbs|sensevoice|__internal|\.json|\.params)[^"]*"' /tmp/w.log 2>/dev/null | sort | uniq -c | sort -rn | head -15 | sed 's/^/    /'
  echo "  --- 总 openat 数 ---"
  sudo grep -ac openat /tmp/w.log 2>/dev/null | sed 's/^/    /'
fi

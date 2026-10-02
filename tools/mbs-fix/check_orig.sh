#!/bin/bash
cd /tmp/scan2
echo "=== 1. 三个 io 文件的内容对比 ==="
for f in __internal_io_file__ __internal_io_file__.orig; do
  echo "  --- $f ($(stat -c%s $f 2>/dev/null) B) ---"
  cat "$f" 2>/dev/null | sed 's/^/    /'
  echo
done
echo "=== 2. 库读 .orig 的完整路径与次数 ==="
sudo grep -a "internal_io" /tmp/w.log 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 3. 库还读了哪些非 mbs 文件 ==="
sudo grep -aoE '"[^"]*"' /tmp/w.log 2>/dev/null | grep -v "npu_mbs" | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
echo
echo "=== 4. 报错涉及的 418608 在哪 ==="
python3 -c "
import glob,struct,os
for f in sorted(glob.glob('/tmp/scan2/*')):
    if os.path.isdir(f): continue
    try: d=open(f,'rb').read()
    except: continue
    p=d.find(struct.pack('<I',418608))
    if p>=0:
        print(f'  {os.path.basename(f)} @0x{p:x}')
        for off in range(max(0,p-16), min(len(d),p+32), 4):
            v=struct.unpack_from('<I',d,off)[0]
            tag=' <==' if off==p else ''
            print(f'    0x{off:04x}: {v}{tag}')
"

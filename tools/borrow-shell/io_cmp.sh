#!/bin/bash
cd /tmp && rm -rf io_cmp && mkdir io_cmp && cd io_cmp
echo "=== 三个版本的 __internal_io_file__ 逐字节对比 ==="
for tag in "现用:/opt/npu/model/sensevoice.tar" "new:/data/usershare/AI编码项目/faster-whisper-NPU/tarfix/sensevoice_new.tar" "bak_io:/opt/npu/model/sensevoice.tar.bak_io_20260929" "bak_orig:/opt/npu/model/sensevoice.tar.bak_20260929"; do
  name="${tag%%:*}"; path="${tag#*:}"
  echo "--- [$name] ---"
  tar -xf "$path" ./__internal_io_file__ -O 2>/dev/null > "io_$name.json"
  echo "  大小: $(wc -c < io_$name.json) 字节"
  python3 -c "
import json,sys
try:
    d=json.load(open('io_$name.json'))
    for it in d:
        print('    %-8s %-10s %s' % (it.get('type'), it.get('name','(无名)'), it.get('shape')))
except Exception as e:
    print('    解析失败:', e)
    print(open('io_$name.json').read()[:300])
"
done
echo
echo "=== 两两差异 ==="
for a in 现用 new bak_io bak_orig; do
  for b in 现用 new bak_io bak_orig; do
    if [ "$a" \< "$b" ]; then
      n=$(diff io_$a.json io_$b.json 2>/dev/null | grep -c "^[<>]")
      [ "$n" != "0" ] && echo "  $a vs $b : $n 行不同"
    fi
  done
done
echo "  (无输出=全同)"
echo
echo "=== __internal_io_file__.orig（tar 里有这个备份） ==="
tar -xf /opt/npu/model/sensevoice.tar ./__internal_io_file__.orig -O 2>/dev/null | head -30

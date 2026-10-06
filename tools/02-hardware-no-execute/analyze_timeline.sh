#!/bin/bash
# 打印驱动侧事件时间轴（内核 uptime 时基），与 gdb 的 UPTIME 行同一时基
echo "=== 驱动侧事件 ==="
sudo dmesg | grep -aE "VHA-PUSHRSP|VHA-READ|VHA-SUBMIT] done=" > /tmp/drv_ev.txt
python3 - <<'PY'
import re
out = []
for line in open('/tmp/drv_ev.txt', errors='surrogateescape'):
    m = re.match(r'\[\s*([0-9]+\.[0-9]+)\]', line)
    if not m:
        continue
    t = float(m.group(1))
    if 'PUSHRSP' in line:
        s = re.search(r'slot=(\d+)', line)
        if s:
            out.append((t, 'PUSH slot=%s' % s.group(1)))
        else:
            out.append((t, 'PUSH(log)'))
    elif 'VHA-READ' in line:
        out.append((t, 'READ by lib'))
    elif 'SUBMIT' in line:
        out.append((t, 'SUBMIT done'))
out.sort()
for t, s in out:
    print("%.3f  %s" % (t, s))
print("--- 合计 %d 条 ---" % len(out))
PY
echo
echo "=== 库侧 HR/SEG（同一时基）==="
grep -aE "★HR#|SEG#" /tmp/gdb_up.txt | sed 's/^UPTIME //' | head -20

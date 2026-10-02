#!/bin/bash
echo "=== 1. sensevoice.tar 里 npu_mbs 文件总数与总大小 ==="
tar -tvf /opt/npu/model/sensevoice.tar 2>/dev/null | grep -c "npu_mbs"
tar -tvf /opt/npu/model/sensevoice.tar 2>/dev/null | awk '{s+=$3} END {printf "  总大小: %.1f MB\n", s/1048576}'
echo
echo "=== 2. __internal_io_file__（输入输出定义） ==="
mkdir -p /tmp/svpkg && cd /tmp/svpkg
tar -xf /opt/npu/model/sensevoice.tar ./__internal_io_file__ ./__dependencies_info_file__ 2>/dev/null
echo "--- io file ---"; cat ./__internal_io_file__ 2>/dev/null | head -20
echo "--- deps 头 20 行 ---"; head -20 ./__dependencies_info_file__ 2>/dev/null
echo
echo "=== 3. sensevoice.json 里的 tvm_op 与 device_index 统计 ==="
python3 - <<'PYEOF'
import json
d = json.load(open('/opt/npu/model/sensevoice.json'))
nodes = d.get('nodes', [])
print("  节点总数:", len(nodes))
from collections import Counter
c = Counter(n.get('op') for n in nodes)
print("  op 分布(前10):", c.most_common(10))
tv = [n for n in nodes if n.get('op') == 'tvm_op']
print("  tvm_op 数量:", len(tv))
for n in tv[:6]:
    print("   -", n.get('name'), "| attrs keys:", list((n.get('attrs') or {}).keys())[:6])
# device_index
for k in ('attrs',):
    pass
di = []
for n in nodes:
    a = n.get('attrs') or {}
    if 'device_index' in a:
        v = a['device_index']
        di.append(v[1] if isinstance(v, list) and len(v)>1 else v)
print("  含 device_index 的节点数:", len(di))
if di:
    flat = []
    for v in di:
        flat.extend(v if isinstance(v, list) else [v])
    print("  device_index 取值分布:", Counter(flat).most_common())
print("  顶层键:", list(d.keys()))
PYEOF

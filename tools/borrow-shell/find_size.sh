#!/bin/bash
echo "=== 1. 在 sensevoice.json 里找 913920 / 457776 / 228480 ==="
for n in 913920 457776 228480 448000; do
  echo "  [$n] sensevoice.json: $(grep -c "$n" /opt/npu/model/sensevoice.json 2>/dev/null) 次"
done
echo
echo "=== 2. 在 sensevoice.params 里找（二进制，用 xxd 搜） ==="
for n in 913920 457776 228480; do
  hex=$(printf '%x' $n)
  # 小端 4 字节
  le=$(printf '%02x%02x%02x%02x' $((n&255)) $(((n>>8)&255)) $(((n>>16)&255)) $(((n>>24)&255)))
  cnt=$(xxd -p /opt/npu/model/sensevoice.params 2>/dev/null | tr -d '\n' | grep -o "$le" | wc -l)
  echo "  [$n] params(小端 $le): $cnt 次"
done
echo
echo "=== 3. 在某个 npu_mbs 里找（挑最大的那个） ==="
BIG=$(ls -S /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/npu_mbs.* 2>/dev/null | head -1)
echo "  样本: $BIG ($(stat -c%s "$BIG" 2>/dev/null) 字节)"
for n in 913920 457776 228480; do
  le=$(printf '%02x%02x%02x%02x' $((n&255)) $(((n>>8)&255)) $(((n>>16)&255)) $(((n>>24)&255)))
  cnt=$(xxd -p "$BIG" 2>/dev/null | tr -d '\n' | grep -o "$le" | wc -l)
  echo "  [$n] mbs(小端 $le): $cnt 次"
done
echo
echo "=== 4. sensevoice.json 里的 shape 声明（找 560/200/204/25055） ==="
python3 - <<'PYEOF'
import json
d = json.load(open('/opt/npu/model/sensevoice.json'))
nodes = d.get('nodes', [])
cnt = 0
for i, n in enumerate(nodes):
    a = n.get('attrs') or {}
    sh = a.get('shape')
    if sh:
        s = json.dumps(sh)
        if any(k in s for k in ('560', '25055', '204')):
            print("  [%d] %s shape=%s" % (i, str(a.get('func_name'))[:40], s[:160]))
            cnt += 1
            if cnt >= 8: break
print("  含相关 shape 的节点数(前8):", cnt)
print()
print("=== 顶层 attrs ===")
print(json.dumps(d.get('attrs'), ensure_ascii=False)[:600])
PYEOF

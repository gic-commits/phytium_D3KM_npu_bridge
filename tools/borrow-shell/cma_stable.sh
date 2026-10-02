#!/bin/bash
echo "=== 1. 基线 CMA（无任何 NPU 活动） ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 2. 我们的驱动当前占了多少（alloc 链表） ==="
echo "  最近 alloc 序号: $(sudo dmesg | grep -ao 'alloc#[0-9]*' | tail -1)"
echo "  REALFREE 次数:   $(sudo dmesg | grep -ac 'VHA-REALFREE')"
echo
echo "=== 3. 关键验证：连跑 3 次 sensevoice 加载，看 CMA 是否稳定（不再单调下降） ==="
cd /opt/npu/python
for i in 1 2 3; do
  BEFORE=$(awk '/CmaFree/{print $2}' /proc/meminfo)
  NPU_SOCK=/run/npu/npu.sock timeout 300 python3 -c "
import sys; sys.path.insert(0,'/opt/npu/python')
import npu_client as npu
c=npu.connect()
try:
    r=c.load('sensevoice'); print('  load ->', r)
except Exception as e:
    print('  load 异常:', str(e)[:120])
" 2>&1 | tail -2
  AFTER=$(awk '/CmaFree/{print $2}' /proc/meminfo)
  echo "  第 $i 次: CmaFree $BEFORE -> $AFTER kB  (差 $((BEFORE-AFTER)) kB)"
done
echo
echo "=== 4. 释放计数 ==="
echo "  REALFREE 次数: $(sudo dmesg | grep -ac 'VHA-REALFREE')"
echo
echo "=== 5. 最终 CMA ==="
awk '/CmaFree/{print "  "$0}' /proc/meminfo

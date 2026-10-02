#!/bin/bash
echo "=== 1. 当前 CMA 状态（上次 2 倍放大后只剩 2.3MB） ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 2. 重载模块（回收全部） ==="
K=$(uname -r)
sudo systemctl stop npusvc; sleep 3
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1 vha_overalloc_mul=0; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 4
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
awk '/CmaFree/{print "  重载后 CmaFree: "$2" kB"}' /proc/meminfo
echo
echo "=== 3. 估算 sensevoice 全部缓冲总量（从上次日志） ==="
python3 - <<'PYEOF'
# 上次 OVERALLOC 日志里的请求尺寸（未放大）
reqs = [448000, 665856, 417792, 417792, 417792, 665856, 665856, 448000]
print("  日志样本请求尺寸:", reqs)
print("  样本合计: %.2f MB" % (sum(reqs)/1048576))
# 141 段，每段约几块
print()
print("  若 141 段 × 每段约 4 块 × 平均 500KB = %.1f MB" % (141*4*500*1024/1048576))
print("  2.04 倍后: %.1f MB" % (141*4*500*1024*2.04/1048576))
print()
print("  可用 CMA: 658 MB（基线）")
print("  => 若总量 2.04 倍后 < 658MB 则可行")
PYEOF
echo
echo "=== 4. 精确统计：从驱动日志统计 sensevoice 一次加载的全部 ALLOC ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 600 python3 -c "
import sys; sys.path.insert(0,'/opt/npu/python')
import npu_client as npu
c=npu.connect()
try: print('load ->', c.load('sensevoice'))
except Exception as e: print('load 异常:', str(e)[:100])
" 2>&1 | tail -2
echo "  --- 本次 ALLOC 统计（未放大） ---"
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{s+=$2; n++} END {printf "    次数=%d 合计=%.1f MB\n", n, s/1048576}'
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{print $2}' | sort -n | uniq -c | sort -rn | head -8 | sed 's/^/    /'

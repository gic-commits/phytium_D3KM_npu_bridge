#!/bin/bash
K=$(uname -r)
echo "=== 1. 当前 CMA ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 2. 彻底回收：停服务 → 杀残留 worker → 卸载模块 ==="
sudo systemctl stop npusvc; sleep 3
echo "  --- 残留 worker ---"
pgrep -a npuworker | head -5 | sed 's/^/    /'
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
pgrep -a npuworker | head -3 | sed 's/^/    杀后残留: /'
echo "  --- 谁还持有 /dev/npu0 ---"
sudo fuser -v /dev/npu0 2>&1 | head -5
echo "  --- 卸载模块 ---"
sudo rmmod phytium_npu_platform 2>&1 | sed 's/^/    /'
sudo rmmod phytium_npu 2>&1 | sed 's/^/    /'
sleep 2
lsmod | grep -cE "^phytium_npu " | sed 's/^/    模块残留: /'
awk '/CmaFree/{print "  卸载后 CmaFree: "$2" kB"}' /proc/meminfo
echo
echo "=== 3. 若仍未回收，检查是否有其它进程持有 NPU 内存 ==="
sudo lsof /dev/npu0 2>/dev/null | head -5
echo "  (空=无进程持有)"
echo
echo "=== 4. 重新加载（exact=448000） ==="
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1 vha_overalloc_mul=0 vha_overalloc_exact=448000; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
awk '/CmaFree/{print "  重载后 CmaFree: "$2" kB"}' /proc/meminfo
echo "  exact=$(cat /sys/module/phytium_npu/parameters/vha_overalloc_exact)"
echo "  npusvc=$(systemctl is-active npusvc)"

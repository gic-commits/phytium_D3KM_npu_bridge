#!/bin/bash
echo "=== 1. CMA 现状 ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 2. 内核里 CMA 的持有者（debugfs） ==="
sudo ls /sys/kernel/debug/cma/ 2>/dev/null | head
for d in /sys/kernel/debug/cma/*/; do
  [ -e "$d" ] || continue
  echo "  --- $d ---"
  for f in count order free total; do
    [ -e "$d$f" ] && echo "    $f: $(sudo cat $d$f 2>/dev/null)"
  done
done
echo
echo "=== 3. 内核日志里的 NPU/dma 相关报错 ==="
sudo dmesg | grep -aiE "phytium_npu|cma|dma_alloc|iommu" | tail -15 | sed 's/^/  /'
echo
echo "=== 4. 当前模块状态 ==="
lsmod | grep -E "^phytium_npu" | awk '{print "  "$1" refcnt="$3}' || echo "  未加载"
ls -l /dev/npu0 2>&1 | sed 's/^/  /'
echo
echo "=== 5. 是否有 zombie/残留进程 ==="
ps aux | grep -iE "npu|phydnn" | grep -v grep | head -8 | awk '{printf "  %-8s %-6s %s\n", $1, $2, substr($11,1,50)}'
echo
echo "=== 6. 尝试：先加载模块再卸载（看能否触发回收） ==="
K=$(uname -r)
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1 2>&1 | sed 's/^/  insmod: /'
sleep 2
sudo rmmod phytium_npu 2>&1 | sed 's/^/  rmmod: /'
sleep 2
awk '/CmaFree/{print "  卸载后 CmaFree: "$2" kB"}' /proc/meminfo

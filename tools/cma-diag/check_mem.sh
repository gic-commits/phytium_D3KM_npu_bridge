#!/bin/bash
echo "=== 1. 内存去向（top 10 进程） ==="
ps aux --sort=-rss 2>/dev/null | head -11 | awk '{printf "  %-10s %-8s %8s KB  %s\n", $1, $2, $6, substr($11,1,40)}'
echo
echo "=== 2. 内核 slab / 其它占用 ==="
awk '/Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|Mapped|Shmem/{print "  "$0}' /proc/meminfo
echo
echo "=== 3. 驱动侧分配链表（未释放的） ==="
sudo dmesg | grep -ac "alloc#" | sed 's/^/  dmesg 里 alloc 记录: /'
echo "  当前模块参数:"
for p in vha_overalloc_mul vha_overalloc_exact vha_overalloc_report vha_sim_mode; do
  echo "    $p = $(cat /sys/module/phytium_npu/parameters/$p 2>/dev/null)"
done
echo
echo "=== 4. 是否有残留 worker 进程 ==="
pgrep -a npuworker | head -5 | sed 's/^/  /'
echo "  worker 数: $(pgrep -c -f npuworker 2>/dev/null)"
echo
echo "=== 5. CMA 区域能否通过 compact 恢复 ==="
echo "  compact_memory 前: CmaFree=$(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
sudo sh -c "echo 1 > /proc/sys/vm/compact_memory" 2>/dev/null && echo "  已触发 compact"
sleep 3
echo "  compact_memory 后: CmaFree=$(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
echo "  MemFree: $(awk '/MemFree/{print $2}' /proc/meminfo) kB"
echo
echo "=== 6. drop_caches 试试 ==="
sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null && echo "  已 drop_caches"
sleep 2
echo "  之后 MemFree: $(awk '/MemFree/{print $2}' /proc/meminfo) kB"
echo "  之后 CmaFree: $(awk '/CmaFree/{print $2}' /proc/meminfo) kB"

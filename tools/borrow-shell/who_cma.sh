#!/bin/bash
echo "=== 1. CMA 总量/空闲（卸载模块后仍被占） ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
python3 -c "
t=1048576; f=666188
print('  已占: %d kB = %.1f MB' % (t-f, (t-f)/1024))
"
echo
echo "=== 2. CMA 区域被谁映射（/proc/self/meminfo 不够，看 CMA 分配器） ==="
sudo cat /sys/kernel/debug/cma/*/ 2>/dev/null | head -20
ls /sys/kernel/debug/cma/ 2>/dev/null | head
echo
echo "=== 3. 内核里 CMA 相关（dma 分配统计） ==="
grep -i cma /proc/meminfo | sed 's/^/  /'
echo
echo "=== 4. 有没有别的进程锁了大块内存（phydnnMemoryLock 之类） ==="
sudo dmesg | grep -aiE "phydnnMemoryLock|memory lock|mlock|locked" | tail -10 | sed 's/^/  /'
echo
echo "=== 5. 当前所有进程的内存占用 top 10 ==="
ps aux --sort=-rss | head -11 | awk '{printf "  %-10s %8s KB  %s\n", $1, $6, substr($11,1,60)}'
echo
echo "=== 6. 设备侧是否有残留的 npu 相关进程 ==="
pgrep -a -f "npu" | head -10 | sed 's/^/  /'
echo
echo "=== 7. 内核 slab / vmalloc 大块 ==="
sudo cat /proc/vmallocinfo 2>/dev/null | awk '$2>1048576 {printf "  %s %s KB %s\n", $1, $2/1024, $3}' | head -10

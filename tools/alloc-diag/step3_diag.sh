#!/bin/bash
O=/home/greatwall/step3.txt
{
echo "=== 1. 关键：库报错前后驱动侧是否有 ioctl ==="
sudo dmesg | grep -aE "alloc#|VHA-ALLOC|ioctl" | tail -10 | sed 's/^/  /'
echo "  (空=驱动没收到请求)"
echo
echo "=== 2. 库的报错串定位 ==="
L=/usr/local/lib/libnpusession.so
strings -t x $L | grep -iE "Cannot allocate vha memory|TEMPORARY buffer" | sed 's/^/  /'
echo
echo "=== 3. 库侧相关符号 ==="
nm -DC $L 2>/dev/null | grep -iE "AllocateMemory|TEMPORARY|Temporary" | head -10 | sed 's/^/  /'
echo
echo "=== 4. 28459008 的来历 ==="
python3 -c "
v = 28459008
print(f'  28459008 = {v/1048576:.2f} MB')
print(f'  /4096 = {v/4096} 页')
print(f'  /208896 = {v/208896:.4f}')
print(f'  /228480 = {v/228480:.4f}')
print(f'  /448000 = {v/448000:.4f}')
print(f'  /417792 = {v/417792:.4f}')
print(f'  2^24 = {2**24}, 2^25 = {2**25}')
print(f'  是否 2 的幂: {v & (v-1) == 0}')
"
echo
echo "=== 5. 库是否先算【总需求】再判断 ==="
echo "  本次加载的分配序列（从之前日志）:"
echo "    小缓冲 1305 次 = 190 MB"
echo "    TMP-13 = 27.1 MB"
echo "  合计约 217 MB，CMA 有 1012 MB => 总量够"
echo
echo "=== 6. 关键：库的分配是否有【单次上限】 ==="
nm -DC $L 2>/dev/null | grep -iE "MaxAlloc|Limit|MAX_" | head -10 | sed 's/^/  /'
echo
echo "=== 7. 看库的 AllocateMemory 实现 ==="
nm -DC $L 2>/dev/null | grep -i "AllocateMemory" | sed 's/^/  /'
} > $O 2>&1
cat $O

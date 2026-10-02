#!/bin/bash
echo "=== 1. 内存现状 ==="
free -m | sed 's/^/  /'
awk '/CmaTotal|CmaFree|MemTotal|MemAvailable/{print "  "$0}' /proc/meminfo
echo
echo "=== 2. 谁在占 CMA（我们的驱动分配记录） ==="
sudo dmesg | grep -aE "alloc#[0-9]+ size=" | tail -12 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 3. 当前所有 alloc 的总和 ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{s+=$2} END {printf "  累计申请: %.1f MB\n", s/1048576}'
echo
echo "=== 4. 驱动里分配失败的位置 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "dma_alloc_coherent\|Cannot allocate\|ENOMEM" $T/phytium_npu_uapi.c | head -10 | sed 's/^/  /'
echo
echo "=== 5. 20444880 这个数从哪来（IO 定义推算） ==="
python3 -c "
print('  logits [1,204,25055] float32 =', 1*204*25055*4, 'bytes')
print('  20444880 / 4 =', 20444880//4, '个 float')
print('  20444880 / 1024 / 1024 = %.2f MB' % (20444880/1048576))
"
echo
echo "=== 6. 池服务进程与设备占用 ==="
pgrep -a npuworker | head -5 | sed 's/^/  /'
sudo fuser -v /dev/npu0 2>&1 | head -5 | sed 's/^/  /'

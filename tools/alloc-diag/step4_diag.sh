#!/bin/bash
O=/home/greatwall/step4.txt
{
echo "=== 1. 本次是否有 cma_alloc 报错 ==="
sudo dmesg | grep -ai "cma" | tail -5 | sed 's/^/  /'
echo "  cma 失败次数: $(sudo dmesg | grep -ac 'cma_alloc.*failed')"
echo
echo "=== 2. 驱动侧分配失败的确切位置 ==="
sudo dmesg | grep -aE "VHA-ALLOC|alloc#|failed|ENOMEM" | tail -15 | sed 's/^/  /'
echo
echo "=== 3. 关键：驱动分配代码（看失败后做什么） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1352 && NR<=1372 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 4. 关键：dev 参数是什么 ==="
grep -n "npu->dev\s*=" $T/*.c | head -5 | sed 's/^/  /'
echo
echo "=== 5. NPU 设备的 DMA 掩码/范围 ==="
sudo dmesg | grep -aiE "phytium.*dma|dma.*mask|coherent" | head -10 | sed 's/^/  /'
echo
echo "=== 6. 关键：物理地址范围（NPU 能访问哪） ==="
sudo dmesg | grep -ao "phys=0x[0-9a-f]*" | sed 's/phys=0x//' | sort -u | tail -5 | while read a; do
  echo "    phys 0x$a"
done
echo "  CMA 区: 0x9c400000-0xdc3fffff"
echo
echo "=== 7. 尝试：单独分配 27MB（用驱动参数） ==="
echo "  (需 EARLYTEST，但补丁没插进去)"
echo
echo "=== 8. 库的 AllocateMemory 反汇编（看它怎么判断） ==="
L=/usr/local/lib/libnpusession.so
objdump -d --start-address=0x121e8 --stop-address=0x12400 $L 2>/dev/null | head -50 | sed 's/^/  /'
} > $O 2>&1
cat $O

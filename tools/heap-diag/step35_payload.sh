#!/bin/bash
O=/home/greatwall/step35.txt
{
echo "=== 1. 关键：nr=2 (ALLOC_MEM) 的 payload（size 字段） ==="
sudo dmesg | grep -a "VHA-ALLOC-RAW" | head -20 | sed 's/.*\] //' | sed 's/^/  /'
echo "  RAW 条数: $(sudo dmesg | grep -ac 'VHA-ALLOC-RAW')"
echo
echo "=== 2. 关键：VHA-ALLOC-ERR 条数 ==="
sudo dmesg | grep -ac "VHA-ALLOC-ERR" | sed 's/^/  /'
sudo dmesg | grep -a "VHA-ALLOC-ERR" | head -10 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 3. 关键：27MB 的 ALLOC 记录 ==="
sudo dmesg | grep -a "VHA-ALLOC-ERR" | grep -a "28459008\|31252480\|27852800" | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 4. 关键：VHA-ALLOC-DIAG（dma_alloc_coherent 前后） ==="
sudo dmesg | grep -ac "VHA-ALLOC-DIAG" | sed 's/^/  /'
sudo dmesg | grep -a "VHA-ALLOC-DIAG" | tail -10 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 关键：报错信息 ==="
sudo tail -15 /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 6. 关键：本次 ALLOC 的最大尺寸 ==="
sudo dmesg | grep -ao "alloc size=[0-9]*" | awk -F= '{print $2}' | sort -rn | head -5 | sed 's/^/  /'
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step2.txt
{
echo "=== 1. CMA 现状（干净） ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
sudo cat /proc/pagetypeinfo 2>/dev/null | grep "DMA32, type          CMA" | sed 's/^/  /'
echo
echo "=== 2. 直接跑 SenseVoice（CMA 干净状态下） ==="
sudo systemctl restart npusvc; sleep 8
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -8
echo "  --- npuworker 日志尾 ---"
sudo tail -16 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'
echo
echo "=== 3. 分配统计 ==="
echo "  ALLOC: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
echo "  cma 失败: $(sudo dmesg | grep -ac 'cma_alloc.*failed')"
sudo dmesg | grep -a "cma_alloc.*failed" | tail -3 | sed 's/.*\] //' | sed 's/^/    /'
awk '/CmaFree/{print "  CmaFree: "$2" kB"}' /proc/meminfo
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step8.txt
{
echo "=== 0. 当前状态 ==="
date
echo "  coherent_dma_mask 日志: $(sudo dmesg | grep -ac 'coherent_dma_mask set')"
echo "  npusvc=$(systemctl is-active npusvc)"
awk '/CmaFree/{print "  CmaFree: "$2" kB"}' /proc/meminfo
echo
echo "=== 1. 重启服务 ==="
sudo systemctl restart npusvc; sleep 8
echo "  npusvc=$(systemctl is-active npusvc)"
echo
echo "=== 2. 跑 SenseVoice ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -8
echo
echo "=== 3. npuworker 日志（最近 20 行） ==="
sudo tail -20 /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 4. 驱动侧分配统计 ==="
echo "  ALLOC 条数: $(sudo dmesg | grep -ac 'VHA-ALLOC')"
echo "  cma 失败: $(sudo dmesg | grep -ac 'cma_alloc.*failed')"
sudo dmesg | grep -a "VHA-ALLOC" | tail -5 | sed 's/.*\] //' | sed 's/^/    /'
awk '/CmaFree/{print "  CmaFree: "$2" kB"}' /proc/meminfo
} > $O 2>&1
cat $O

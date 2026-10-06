#!/bin/bash
# 试：内存规整 + 释放缓存 ⇒ 造出连续块 ⇒ 再跑 sensevoice
O=/home/greatwall/compact.txt
{
echo "########## COMPACT $(date +%H:%M:%S) ##########"
echo "=== 规整前 buddyinfo ==="
sudo cat /proc/buddyinfo | sed 's/^/  /'
echo "=== 释放缓存 + 规整 ==="
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo sh -c 'echo 1 > /proc/sys/vm/compact_memory'
sleep 3
echo "=== 规整后 buddyinfo ==="
sudo cat /proc/buddyinfo | sed 's/^/  /'
echo "=== CMA ==="
grep -E "Cma(Total|Free)" /proc/meminfo | sed 's/^/  /'
echo "=== 跑 sensevoice ==="
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 130 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|infer" | head -3
cd /
echo "  TEMPORARY失败=$(sudo grep -ac 'Cannot allocate vha memory for TEMPORARY' /var/log/npuworker.log)"
echo "  cma_alloc失败=$(sudo dmesg | grep -ac 'cma_alloc: alloc failed')"
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')"
echo "=== 规整后再看一次 buddyinfo ==="
sudo cat /proc/buddyinfo | sed 's/^/  /'
} > $O 2>&1
cat $O

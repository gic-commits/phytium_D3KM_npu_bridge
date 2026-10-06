#!/bin/bash
# 干净模块 + 干净 CMA，第一次跑 sensevoice
O=/home/greatwall/clean_cma.txt
{
echo "########## CLEAN-CMA $(date +%H:%M:%S) ##########"
sudo systemctl stop npusvc 2>/dev/null; sleep 2
sudo pkill -x npuworker 2>/dev/null; sleep 2
sudo modprobe -r phytium_npu_platform 2>/dev/null; sleep 2
sudo modprobe -r phytium_npu 2>/dev/null; sleep 2
lsmod | grep -q "^phytium_npu " && { echo "  ✗ 未卸掉"; exit 6; }
echo "  卸载后 CMA: $(grep CmaFree /proc/meminfo | tr -d ' ')"
sudo modprobe phytium_npu_platform; sleep 3
echo "  加载后 CMA: $(grep CmaFree /proc/meminfo | tr -d ' ')"
P=/sys/module/phytium_npu/parameters
echo 1 | sudo tee $P/vha_heap_type >/dev/null
echo 1 | sudo tee $P/vha_heap_flags >/dev/null
echo 0 | sudo tee $P/vha_overalloc_mul >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
echo "--- 第一次跑 sensevoice（CMA 全新）---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 130 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|infer" | head -3
cd /
echo "  跑完后 CMA: $(grep CmaFree /proc/meminfo | tr -d ' ')"
echo "  ALLOC次数=$(sudo dmesg | grep -ac 'cmd=0xc0207102')"
echo "  TEMPORARY失败=$(sudo grep -ac 'Cannot allocate vha memory for TEMPORARY' /var/log/npuworker.log)"
echo "  FATAL尺寸: $(sudo grep -ao 'failed to allocate [0-9]* bytes' /var/log/npuworker.log | head -3 | tr '\n' ' ')"
echo "  最大单次申请(MB): $(sudo dmesg | grep -aoE 'alloc size=[0-9]+' | sed 's/alloc size=//' | sort -n | tail -1 | awk '{printf "%.1f", $1/1048576}')"
} > $O 2>&1
cat $O

#!/bin/bash
# 复核 type=6 flags=33
O=/home/greatwall/heap633.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## HEAP 6/33 $(date +%H:%M:%S) ##########"
echo 6  | sudo tee $P/vha_heap_type >/dev/null
echo 33 | sudo tee $P/vha_heap_flags >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
echo "--- mobilenet 2 次（回归）---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=2 NPU_SOCK=/run/npu/npu.sock timeout 90 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败"
echo "--- sensevoice ---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock timeout 140 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -4
cd /
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:') 推送=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "=== worker 日志（本次全部关键行）==="
sudo grep -aE "ERROR|FATAL|WARN|unable|ok:|infers" /var/log/npuworker.log | tail -20 | sed 's/^/  /'
echo "=== 各错误计数 ==="
echo "  TEMPORARY失败=$(sudo grep -ac 'Cannot allocate vha memory for TEMPORARY' /var/log/npuworker.log)"
echo "  FATAL=$(sudo grep -ac 'FATAL' /var/log/npuworker.log)"
echo "  LOCAL失败=$(sudo grep -ac 'Cannot allocate vha memory for LOCAL' /var/log/npuworker.log)"
echo "  SHARED失败=$(sudo grep -ac 'Cannot allocate vha memory for SHARED' /var/log/npuworker.log)"
} > $O 2>&1
cat $O

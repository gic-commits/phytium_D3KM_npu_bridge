#!/bin/bash
# 扫堆描述符 type/flags，看能否消除 "Cannot allocate vha memory for TEMPORARY buffer"
O=/home/greatwall/heapsweep.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## HEAPSWEEP $(date +%H:%M:%S) ##########"
echo 0 | sudo tee $P/vha_sim_mode >/dev/null   # 真硬件
for T in 1 5 6 2 3; do
  for F in 1 3 33; do
    echo "=========== type=$T flags=$F ==========="
    echo $T | sudo tee $P/vha_heap_type >/dev/null
    echo $F | sudo tee $P/vha_heap_flags >/dev/null
    sudo dmesg -n 1
    sudo systemctl restart npusvc; sleep 5
    sudo truncate -s 0 /var/log/npuworker.log 2>/dev/null || sudo sh -c ': > /var/log/npuworker.log'
    cd /opt/npu/python
    MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
        timeout 90 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -3
    cd /
    TM=$(sudo grep -ac "Cannot allocate vha memory for TEMPORARY" /var/log/npuworker.log)
    FA=$(sudo grep -ac "failed to allocate" /var/log/npuworker.log)
    echo "    TEMPORARY分配失败=$TM  FATAL=$FA"
    [ "$TM" = "0" ] && echo "    ★★ 该组合下没有临时缓冲失败！"
  done
done
} > $O 2>&1
cat $O

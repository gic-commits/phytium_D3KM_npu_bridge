#!/bin/bash
# 抓"库看到的段状态"（1/4=已完成，其余=未完成）
O=/home/greatwall/segstatus.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## SEG-STATUS $(date +%H:%M:%S) ##########"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 3 | sudo tee $P/vha_push_sid_mode >/dev/null 2>&1   # 关掉 sid 模式（恢复默认）
echo 0 | sudo tee $P/vha_push_sid_mode >/dev/null
echo 0 | sudo tee $P/vha_resp_fix >/dev/null
echo 1 | sudo tee $P/vha_rsp_slot >/dev/null
echo 0 | sudo tee $P/vha_rsp_slot_step >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 180 python3 -u /tmp/mb_client.py > /tmp/seg_out.txt 2>&1 &
for i in $(seq 1 100); do W=$(pgrep -x npuworker | tail -1); [ -n "$W" ] && break; sleep 0.2; done
echo "worker=$W"
sudo timeout 100 gdb -p $W -x /tmp/gdb_segstatus.py -batch > /tmp/seg_gdb.txt 2>&1
echo "=== 库看到的段状态 ==="
grep -aE "SETUP|段状态#|SUM" /tmp/seg_gdb.txt | head -40
echo "=== 驱动侧 ==="
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  推送=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "=== 客户端 ==="
tail -3 /tmp/seg_out.txt
} > $O 2>&1
cat $O

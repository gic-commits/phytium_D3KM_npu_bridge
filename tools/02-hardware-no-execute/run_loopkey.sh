#!/bin/bash
# 抓失败那次库侧到底在等哪个 key（mobilenet 连跑 4 次）
O=/home/greatwall/loopkey.txt
{
echo "########## LOOPKEY $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
echo 0 | sudo tee $P/vha_mmu_cfg_each_submit >/dev/null 2>&1
echo 0 | sudo tee $P/vha_force_resume_each_submit >/dev/null 2>&1
echo 0 | sudo tee $P/vha_clr_status_before_start >/dev/null 2>&1
echo 1 | sudo tee $P/vha_push_enable >/dev/null 2>&1
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=4 NPU_SOCK=/run/npu/npu.sock \
    timeout 220 python3 /tmp/loop_client.py > /tmp/loop_out.txt 2>&1 &
sleep 9
WP=$(pgrep -x npuworker | head -1)
echo "worker pid = $WP"
if [ -n "$WP" ]; then
  sudo timeout 70 gdb -p $WP -x /tmp/gdb_key.py -batch > /tmp/gdb_key_out.txt 2>&1
fi
echo "=== 客户端结果 ==="
cat /tmp/loop_out.txt | grep -aE "推理|失败|load" | head -8
echo "=== gdb：库侧 key / 等哪个 slot ==="
grep -aE "KEY#|HR-CALL|解出|丢弃|推的|SUM|GetSlot" /tmp/gdb_key_out.txt | head -30
echo "=== 提交与推响应 ==="
sudo dmesg | grep -a "VHA-SUBMIT] done=" | sed 's/.*\[VHA-SUBMIT\] /  [SUBMIT] /' | head -6
sudo dmesg | grep -a "VHA-PUSHRSP" | sed 's/.*\[VHA-PUSHRSP\] /  [PUSHRSP] /' | head -6
} > $O 2>&1
cat $O

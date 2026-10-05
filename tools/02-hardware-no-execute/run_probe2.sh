#!/bin/bash
# 干净的探针壳：参数与当前方案一致（step=2 / on_read=1 / reset=0 / gap=3000）
# 用法: bash run_probe2.sh <模型> <shape> <探针脚本>
O=/home/greatwall/probe2_out.txt
P=/sys/module/phytium_npu/parameters
MODEL=${1:-sensevoice}
SHAPE=${2:-1,200,560}
PROBE=${3:-/tmp/gdb_miss2.py}
{
echo "########## 探针 $MODEL $PROBE $(date +%H:%M:%S) ##########"
sudo systemctl stop npusvc 2>/dev/null; sleep 2
sudo pkill -x npuworker 2>/dev/null; sleep 1
set_p() { echo "$2" | sudo tee $P/$1 >/dev/null 2>&1; }
set_p vha_sim_mode 0; set_p vha_resp_fix 0; set_p vha_vrsp_skip 1; set_p vha_push_enable 1
set_p vha_rsp_slot 1; set_p vha_rsp_slot_step 2; set_p vha_rsp_slot_max 0
set_p vha_rsp_replay 0; set_p vha_rsp_delay_ms 0; set_p vha_settle_ms 0; set_p vha_vrsp_fix 0
set_p vha_slot_reset_on_sync 0; set_p vha_slot_gap_ms 3000; set_p vha_sync_beat_ms 0
set_p vha_rsp_on_read 1; set_p vha_rsp_on_read_ms 120
echo "  step=$(cat $P/vha_rsp_slot_step) on_read=$(cat $P/vha_rsp_on_read) gap=$(cat $P/vha_slot_gap_ms) reset=$(cat $P/vha_slot_reset_on_sync)"
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 7
sudo dmesg -C
sudo nohup dmesg -w > /tmp/dmesg_probe.log 2>&1 &
DW=$!
cd /opt/npu/python
MB_MODEL=$MODEL MB_SHAPE=$SHAPE MB_MODE=load MB_TAG=load NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | tail -2
W=$(pgrep -x npuworker | head -1)
echo "  worker=$W"
if [ -n "$W" ]; then
  sudo timeout -k 5 75 gdb -p $W -batch -x $PROBE -ex "continue" > /tmp/probe2_gdb.log 2>&1 &
  GP=$!
  sleep 7
  MB_MODEL=$MODEL MB_SHAPE=$SHAPE MB_MODE=infer MB_TAG=infer NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/mb_client.py 2>&1 | tail -2
  sleep 4
  kill $GP 2>/dev/null
fi
kill $DW 2>/dev/null
echo "=== 我们推的 slot ==="
grep -a "VHA-PUSHRSP" /tmp/dmesg_probe.log | grep -a "sess=" | sed 's/.*\[VHA/[VHA/' | head -12
echo "=== gdb 探针 ==="
grep -aE "KEY#|HR#|HR-CALL|MISS#|GetSlot#|SUM" /tmp/probe2_gdb.log | head -35
cd /
} > $O 2>&1
cat $O

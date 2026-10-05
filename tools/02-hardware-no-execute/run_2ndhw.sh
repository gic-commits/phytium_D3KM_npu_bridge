#!/bin/bash
# 第二轮失败的硬件侧取证（含 reset_each_run 开关对比）
O=/home/greatwall/2nd_hw.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## 第二轮硬件侧 $(date +%H:%M:%S) ##########"
for RST in 0 1; do
  echo "===== vha_reset_each_run=$RST ====="
  sudo systemctl stop npusvc 2>/dev/null; sleep 2
  sudo pkill -x npuworker 2>/dev/null; sleep 1
  set_p() { echo "$2" | sudo tee $P/$1 >/dev/null 2>&1; }
  set_p vha_sim_mode 0; set_p vha_resp_fix 0; set_p vha_vrsp_skip 1; set_p vha_push_enable 1
  set_p vha_rsp_slot 1; set_p vha_rsp_slot_step 0; set_p vha_rsp_slot_max 0
  set_p vha_rsp_replay 0; set_p vha_rsp_delay_ms 0; set_p vha_settle_ms 0; set_p vha_vrsp_fix 0
  set_p vha_slot_reset_on_sync 1; set_p vha_slot_gap_ms 0; set_p vha_rsp_on_read 0; set_p vha_rsp_cycle_ms 0
  set_p vha_reset_each_run $RST
  sudo dmesg -n 1
  sudo systemctl restart npusvc; sleep 6
  sudo dmesg -C
  sudo nohup dmesg -w > /tmp/dmesg_hw_$RST.log 2>&1 &
  DW=$!
  cd /opt/npu/python
  MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_MODE=both MB_TAG=r1 NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "推理 |infer 异常" | sed 's/^/  1st: /'
  MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_MODE=infer MB_TAG=r2 NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "推理 |infer 异常" | sed 's/^/  2nd: /'
  cd /
  sleep 1; kill $DW 2>/dev/null
  echo "  -- 该轮 VHA-TIME 里的 done 值 --"
  grep -a "VHA-TIME" /tmp/dmesg_hw_$RST.log | sed 's/.*\[VHA/[VHA/' | grep -a "ml" | head -6
  echo "  -- 该轮 SUBMIT 完成情况（时间戳+TIME）--"
  grep -a "VHA-TIME" /tmp/dmesg_hw_$RST.log | sed 's/.*等待完成/DONE/' | grep -aE "来源|wait" | head -0
  grep -a "等待完成" /tmp/dmesg_hw_$RST.log 2>/dev/null | head -3
  grep -a "done=0 after\|done=1 after" /tmp/dmesg_hw_$RST.log | head -4
  echo "  -- NODONE 次数: $(grep -ac NODONE /tmp/dmesg_hw_$RST.log)  PUSHRSP 次数: $(grep -ac 'sess=.*slot=' /tmp/dmesg_hw_$RST.log) --"
done
} > $O 2>&1
cat $O

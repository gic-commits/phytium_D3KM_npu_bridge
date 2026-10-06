#!/bin/bash
# 每次提交推多条 [2]=1（同一键）⇒ 让每个段都能被标为"已完成"
O=/home/greatwall/multidone.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## MULTI-DONE $(date +%H:%M:%S) ##########"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 1 | sudo tee $P/vha_rsp_slot >/dev/null        # [+2] = 1
echo 0 | sudo tee $P/vha_rsp_slot_step >/dev/null
echo 0 | sudo tee $P/vha_slot_reset_on_sync >/dev/null
echo 0 | sudo tee $P/vha_rsp_on_read >/dev/null
echo 0 | sudo tee $P/vha_resp_fix >/dev/null
echo 50 | sudo tee $P/vha_rsp_delay_ms >/dev/null    # 走延迟路径（replay 生效）
echo 1  | sudo tee $P/vha_replay_keep_slot >/dev/null # ★ 重放保持同一键
echo 0  | sudo tee $P/vha_push_sid_mode >/dev/null
for R in 30 80; do
  echo "-------------------- replay=$R (键恒为 1) --------------------"
  echo $R | sudo tee $P/vha_rsp_replay >/dev/null
  echo 2  | sudo tee $P/vha_rsp_replay_ms >/dev/null
  sudo systemctl restart npusvc; sleep 5
  sudo sh -c ': > /var/log/npuworker.log'
  sudo dmesg -C
  cd /opt/npu/python
  MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=2 NPU_SOCK=/run/npu/npu.sock timeout 100 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败" | head -2
  MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
      timeout 150 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -3
  cd /
  echo "    提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  推送=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')  库读=$(sudo dmesg | grep -ac 'VHA-READ')"
  echo "    worker错误=$(sudo grep -acE 'ERROR|FATAL' /var/log/npuworker.log)  成功=$(sudo grep -ac 'INFER sensevoice ok' /var/log/npuworker.log)"
done
} > $O 2>&1
cat $O

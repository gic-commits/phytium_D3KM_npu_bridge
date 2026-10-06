#!/bin/bash
# 试常量响应键 1 / 4（笔记："库只接受 1 或 4"）
O=/home/greatwall/constkey.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## CONST-KEY $(date +%H:%M:%S) ##########"
run_case () {
  echo "-------------------- key=$1 --------------------"
  echo "$1" | sudo tee $P/vha_rsp_slot >/dev/null
  echo 0   | sudo tee $P/vha_rsp_slot_step >/dev/null
  echo 0   | sudo tee $P/vha_slot_reset_on_sync >/dev/null
  echo 0   | sudo tee $P/vha_rsp_on_read >/dev/null
  echo 0   | sudo tee $P/vha_rsp_delay_ms >/dev/null
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
  sudo dmesg -n 1
  sudo systemctl restart npusvc; sleep 5
  sudo sh -c ': > /var/log/npuworker.log'
  sudo dmesg -C
  cd /opt/npu/python
  MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
      timeout 130 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -3
  cd /
  echo "    提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  推送=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')  库读=$(sudo dmesg | grep -ac 'VHA-READ')"
  echo "    键序列: $(sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -8 | tr '\n' ' ')"
  echo "    worker错误=$(sudo grep -acE 'ERROR|FATAL' /var/log/npuworker.log)  成功=$(sudo grep -ac 'INFER sensevoice ok' /var/log/npuworker.log)"
}
run_case 4
run_case 1
} > $O 2>&1
cat $O

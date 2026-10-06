#!/bin/bash
# 对照：成功(mobilenet) vs 失败(sensevoice) 的 write()/提交次数与库侧行为
O=/home/greatwall/wrcount.txt
{
echo "########## WRCOUNT $(date +%H:%M:%S) ##########"
sudo dmesg -n 1
for M in "mobilenet 1,3,224,224 1" "Restnet50 1,3,224,224 1" "sensevoice 1,200,560 1"; do
  set -- $M
  echo "==================== $1 ===================="
  sudo systemctl restart npusvc; sleep 6
  sudo dmesg -C
  cd /opt/npu/python
  MB_MODEL=$1 MB_SHAPE=$2 MB_N=$3 NPU_SOCK=/run/npu/npu.sock timeout 120 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "load ->|推理|失败" | head -3
  cd /
  echo "  提交(TD-A before:) = $(sudo dmesg | grep -ac 'VHA-TD-A] before:')"
  echo "  完成(SUBMIT done)  = $(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')"
  echo "  推送(PUSHRSP行)    = $(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
  echo "  BUF_OP(nr=9)       = $(sudo dmesg | grep -ac 'cmd=0x40107109')"
  echo "  推送序列: $(sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -8 | tr '\n' ' ')"
  echo "  等待完成日志: $(sudo dmesg | grep -ao '来源=[^ ]* done=[01]' | sort | uniq -c | tr '\n' ' ')"
done
} > $O 2>&1
cat $O

#!/bin/bash
# 读阻塞帧的参数：任务线程在等哪个 slot / 通知对象在等什么
O=/home/greatwall/svargs.txt
{
echo "########## SVARGS $(date +%H:%M:%S) ##########"
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py > /tmp/sv_args_out.txt 2>&1 &
for i in $(seq 1 200); do WP=$(pgrep -x npuworker | tail -1); [ -n "$WP" ] && break; sleep 0.1; done
echo "worker=$WP，等 20s 让它卡住…"
sleep 20
echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "  推送序列: $(sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -10 | tr '\n' ' ')"
sudo timeout 90 gdb -p $WP -batch \
  -ex "set pagination off" \
  -ex "thread apply all bt 6" \
  > /tmp/sv_bt2.txt 2>&1
echo "=== 找卡在 HandleResponse 的线程号 ==="
TN=$(grep -aB2 "HandleResponse" /tmp/sv_bt2.txt | grep -aoE "^Thread [0-9]+" | head -1 | grep -oE "[0-9]+")
echo "  thread=$TN"
echo "=== 该线程的栈 + 参数 ==="
sudo timeout 90 gdb -p $WP -batch \
  -ex "set pagination off" \
  -ex "thread $TN" \
  -ex "frame 4" \
  -ex "info args" \
  -ex "info locals" \
  -ex "bt 8" \
  > /tmp/sv_args.txt 2>&1
grep -avE "^\[|warning|Reading|done\.|^$" /tmp/sv_args.txt | head -30
} > $O 2>&1
cat $O

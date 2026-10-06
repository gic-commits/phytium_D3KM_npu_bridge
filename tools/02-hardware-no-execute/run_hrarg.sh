#!/bin/bash
# 读出"卡在 HandleResponse 的任务线程"在等哪个 slot（参数 $w1）
O=/home/greatwall/hrarg.txt
{
echo "########## HR-ARG $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py > /tmp/hrar_out.txt 2>&1 &
for i in $(seq 1 100); do W=$(pgrep -x npuworker | tail -1); [ -n "$W" ] && break; sleep 0.2; done
echo "worker=$W"
sleep 12
echo "  submit=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "  推送键: $(sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -8 | tr '\n' ' ')"
# 1) 找线程号
sudo timeout 60 gdb -p $W -batch -ex "set pagination off" -ex "thread apply all bt 5" > /tmp/hr_bt.txt 2>&1
TN=$(grep -aB6 "HandleResponse" /tmp/hr_bt.txt | grep -aoE "^Thread [0-9]+" | head -1 | grep -oE "[0-9]+")
echo "  卡在 HandleResponse 的线程号 = $TN"
if [ -n "$TN" ]; then
  sudo timeout 60 gdb -p $W -batch -ex "set pagination off" -ex "thread $TN" -ex "frame 4" -ex "info args" -ex "frame 5" -ex "info args" > /tmp/hr_args.txt 2>&1
  echo "=== 该线程参数 ==="
  grep -avE "^\[|warning|Reading|^$|done\." /tmp/hr_args.txt | head -24
fi
# 2) 主线程在等什么
sudo timeout 60 gdb -p $W -batch -ex "set pagination off" -ex "thread 1" -ex "bt 8" -ex "frame 4" -ex "info args" > /tmp/hr_main.txt 2>&1
echo "=== 主线程 ==="
grep -aE "^#[0-9]|=" /tmp/hr_main.txt | head -18
} > $O 2>&1
cat $O

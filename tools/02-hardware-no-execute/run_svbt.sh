#!/bin/bash
# 失败时刻抓 worker 全部线程栈（库到底停在哪）
O=/home/greatwall/svbt.txt
{
echo "########## SVBT $(date +%H:%M:%S) ##########"
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py > /tmp/sv_bt_out.txt 2>&1 &
# 等 worker 起来，再等它把 3 段提交完（卡住）
for i in $(seq 1 200); do WP=$(pgrep -x npuworker | tail -1); [ -n "$WP" ] && break; sleep 0.1; done
echo "worker=$WP，等 20s 让它跑完 3 段并卡住…"
sleep 20
echo "=== 此刻驱动侧 ==="
echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "=== ★全部线程栈 ==="
sudo timeout 90 gdb -p $WP -batch -ex "set pagination off" -ex "thread apply all bt" > /tmp/sv_bt.txt 2>&1
grep -aE "^Thread|^#[0-9]+ " /tmp/sv_bt.txt | head -70
echo "=== 客户端 ==="
tail -3 /tmp/sv_bt_out.txt
} > $O 2>&1
cat $O

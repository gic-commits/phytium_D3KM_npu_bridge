#!/bin/bash
# 抢在推理之前 attach：worker 一出现立刻挂 gdb
O=/home/greatwall/svslot.txt
{
echo "########## SVSLOT $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
echo 0 | sudo tee $P/vha_slot_gap_ms >/dev/null
echo 2 | sudo tee $P/vha_rsp_slot_step >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py > /tmp/sv_out.txt 2>&1 &
# 0.1s 粒度等 worker 出现，一出现立即 attach
WP=""
for i in $(seq 1 200); do
  WP=$(pgrep -x npuworker | tail -1)
  [ -n "$WP" ] && break
  sleep 0.1
done
echo "worker=$WP (等 ${i}00ms)"
[ -z "$WP" ] && { echo "worker 未出现"; exit 8; }
sudo timeout 150 gdb -p $WP -x /tmp/gdb_slotsym.py -batch > /tmp/gdb_slot_sym2.txt 2>&1 &
GP=$!
sleep 50
echo "=== 50s 时驱动侧 ==="
echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "=== gdb 至今 ==="
grep -aE "SETUP|SLOT#|HR#|SEG#|SUM" /tmp/gdb_slot_sym2.txt | head -30
wait $GP 2>/dev/null
echo "=== 客户端 ==="
tail -4 /tmp/sv_out.txt
echo "=== gdb 最终 ==="
grep -aE "SLOT#|HR#|SEG#|SUM" /tmp/gdb_slot_sym2.txt | head -40
echo "=== 推送序列 ==="
sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -20 | tr '\n' ' '
echo
} > $O 2>&1
cat $O

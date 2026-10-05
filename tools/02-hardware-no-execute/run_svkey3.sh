#!/bin/bash
# 干净时序：先起客户端 → 等 load 完 → attach 最新 worker → 跑满 → 抓全部
O=/home/greatwall/svkey3.txt
{
echo "########## SVKEY3 $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
echo 500 | sudo tee $P/vha_slot_gap_ms >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 240 python3 /tmp/mb_client.py > /tmp/sv_out.txt 2>&1 &
echo "客户端已启动，等 10s 让 worker 起来并 load 完…"
sleep 10
WP=$(pgrep -x npuworker | tail -1)
echo "最新 worker pid = $WP ($(pgrep -x npuworker | wc -l) 个 worker)"
if [ -n "$WP" ]; then
  sudo timeout 150 gdb -p $WP -x /tmp/gdb_key.py -batch > /tmp/gdb_key_sv3.txt 2>&1 &
  GP=$!
  sleep 40
  echo "=== 40s 时驱动侧状态 ==="
  echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
  sudo dmesg | grep -a "VHA-PUSHRSP" | sed 's/.*\[VHA-PUSHRSP\] //' | grep -a "slot=" | head -6
  echo "=== gdb 至今输出 ==="
  head -40 /tmp/gdb_key_sv3.txt
  wait $GP 2>/dev/null
fi
echo "=== 客户端最终结果 ==="
tail -4 /tmp/sv_out.txt
echo "=== gdb 最终 ==="
grep -aE "SETUP|KEY#|DROP|HR-CALL|SUM" /tmp/gdb_key_sv3.txt | head -30
} > $O 2>&1
cat $O

#!/bin/bash
# 鲁棒探针：等 worker 且 libnpusession.so 已映射后再 attach
# 目标：抓"段指针"，并对照我们驱动 MAP_BUF 的 IOVA 区间
O=/home/greatwall/segptr2.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## SEG-PTR2 $(date +%H:%M:%S) ##########"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 0 | sudo tee $P/vha_rsp_delay_ms >/dev/null
echo 0 | sudo tee $P/vha_rsp_replay >/dev/null
echo 1 | sudo tee $P/vha_rsp_slot >/dev/null
echo 0 | sudo tee $P/vha_resp_fix >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo dmesg -C

cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 180 python3 -u /tmp/mb_client.py > /tmp/seg2_out.txt 2>&1 &

# ★ 等 worker 出现「且」libnpusession.so 已映射
W=""
for i in $(seq 1 200); do
  for C in $(pgrep -x npuworker); do
    if sudo grep -qa "libnpusession.so" /proc/$C/maps 2>/dev/null; then W=$C; break; fi
  done
  [ -n "$W" ] && break
  sleep 0.2
done
echo "worker=$W (等 ${i}00ms，已确认库已加载)"
[ -z "$W" ] && { echo "未找到就绪 worker"; exit 8; }

sudo timeout 90 gdb -p $W -x /tmp/gdb_segptr2.py -batch > /tmp/seg2_gdb.txt 2>&1
echo "=== gdb（段指针 / inner[+2]）==="
sudo grep -avE "^\[New LWP|^\[New Thread|libthread_db|^\[Inferior|^\[Switching|exited\]" /tmp/seg2_gdb.txt | head -16
echo "=== 驱动侧 IOVA 区间（前 6 / 后 6）==="
sudo dmesg | grep -oE "iova=0x[0-9a-f]+ size=[0-9]+" | head -6 | sed 's/^/  /'
sudo dmesg | grep -oE "iova=0x[0-9a-f]+ size=[0-9]+" | tail -6 | sed 's/^/  /'
echo "=== 提交/推送 ==="
echo "  submit=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
echo "=== 客户端 ==="
tail -3 /tmp/seg2_out.txt
} > $O 2>&1
cat $O

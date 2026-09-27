#!/bin/bash
# gdb 断点：看库用什么 id 匹配响应（yunet 通 / yolov5s 挂 对照）
cd /dev/shm/nputest/svc || exit 1
pkill -x npusvc; pkill -x npu_cli; pkill -x gdb; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log /tmp/w.log
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
P=$(pgrep -x npusvc); echo "== 服务 pid=$P"
sudo gdb -p $P -batch -x /dev/shm/nputest/svc/w.gdb > /tmp/w.log 2>&1 &
sleep 3
echo "== A) yunet:"
timeout 40 ./npu_cli infer yunet_npu /dev/shm/nputest/20210828122250_3b289.jpg 112 112 0 /tmp/w1 2>&1 | tail -1
echo "== B) yolov5s(预期挂):"
( timeout 30 ./npu_cli infer yolov5s /dev/shm/nputest/2.jpg 640 640 1 /tmp/w5 > /tmp/w5.log 2>&1 & )
sleep 14
sudo pkill -INT gdb; sleep 1
echo "== gdb 抓到的匹配事件(前 60 行):"
grep -E "WAIT|RESP|TASK|0x" /tmp/w.log | head -60
pkill -x npu_cli; pkill -x npusvc; sleep 1
echo "== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

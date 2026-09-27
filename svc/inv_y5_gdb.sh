#!/bin/bash
# 抓挂死现场：yunet(通) -> yolov5s(挂)，然后 gdb 全线程栈 + /proc 状态
cd /dev/shm/nputest/svc || exit 1
pkill -x npusvc; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log /tmp/g5.log
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
P=$(pgrep -x npusvc); echo "== 服务 pid=$P"
echo "== A) yunet:"
timeout 30 ./npu_cli infer yunet_npu /dev/shm/nputest/20210828122250_3b289.jpg 112 112 0 /tmp/g1 2>&1 | tail -1
echo "== B) yolov5s(预期挂):"
( timeout 30 ./npu_cli infer yolov5s /dev/shm/nputest/2.jpg 640 640 1 /tmp/g5 > /tmp/g5.log 2>&1 & )
sleep 12
echo "== 线程状态 tid state wchan syscall:"
for t in /proc/$P/task/*; do tid=${t##*/}; \
  printf "  %s %s %s %s\n" "$tid" "$(awk '{print $3}' $t/stat 2>/dev/null)" \
  "$(cat $t/wchan 2>/dev/null)" "$(cut -d' ' -f1,2 $t/syscall 2>/dev/null)"; done
echo "== gdb 栈(截取库内帧):"
sudo gdb -p $P -batch -ex 'thread apply all bt 12' 2>&1 \
  | grep -vE "^\[New|^warning|Downloading|Reading symbols|no debugging|^0x" | head -60
pkill -x npu_cli; pkill -x npusvc; sleep 1
echo "== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

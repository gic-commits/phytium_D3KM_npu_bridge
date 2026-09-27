#!/bin/bash
# 用 LD_PRELOAD 探针抓两次请求(不同图)的 ioctl 序列 + 响应字节
cd /dev/shm/nputest/svc || exit 1
gcc -shared -fPIC -O1 -o libvha_tap.so libvha_tap.c -ldl 2>&1 | head -5
[ -f libvha_tap.so ] || { echo "!! 探针编译失败"; exit 1; }
pkill -x npusvc; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log /tmp/vha_tap.log
LD_PRELOAD=/dev/shm/nputest/svc/libvha_tap.so VHA_TAP_LOG=/tmp/vha_tap.log \
  nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
  --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
echo "== A) yunet:"
timeout 30 ./npu_cli infer yunet_npu /dev/shm/nputest/20210828122250_3b289.jpg 112 112 0 /tmp/t1 2>&1 | tail -1
echo "== 探针行数(yunet 后):"; wc -l < /tmp/vha_tap.log
cp /tmp/vha_tap.log /tmp/tap_yunet.log
echo "== B) yolov5s:"
( timeout 30 ./npu_cli infer yolov5s /dev/shm/nputest/2.jpg 640 640 1 /tmp/t5 > /tmp/t5.log 2>&1 & )
sleep 14
echo "== 探针行数(全部):"; wc -l < /tmp/vha_tap.log
echo "== 两次分界后的关键行（IOCTL nr=9/10 + READ/WRITE 32B）:"
grep -nE "IOCTL|READ" /tmp/vha_tap.log | tail -45 | cut -c1-150
pkill -x npu_cli; pkill -x npusvc; sleep 1
echo "== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

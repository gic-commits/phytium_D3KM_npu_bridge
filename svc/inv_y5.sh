#!/bin/bash
# 定位：服务内第 2 个模型(yolov5s) 卡在哪个系统调用（零内核改动）
cd /dev/shm/nputest/svc || exit 1
pkill -x npusvc; pkill -x npu_cli; sleep 1
rm -f /tmp/svc.strace /tmp/npusvc.log /tmp/o1 /tmp/o5
nohup strace -f -tt -o /tmp/svc.strace ./npusvc --sock /tmp/npu.sock \
      --models /dev/shm/nputest/model/ --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
echo "== 服务 pid=$(pgrep -x npusvc)"
echo "== A) yunet infer:"
timeout 30 ./npu_cli infer yunet_npu /dev/shm/nputest/20210828122250_3b289.jpg 112 112 0 /tmp/o1 2>&1 | tail -2
echo "== B) yolov5s infer:"
timeout 40 ./npu_cli infer yolov5s /dev/shm/nputest/2.jpg 640 640 1 /tmp/o5 2>&1 | tail -3
echo "== 服务日志(req/init/post):"
grep -E "req#|init_graph|post" /tmp/npusvc.log | tail -6 | cut -c1-120
echo "== strace 行数/各线程占比:"
wc -l < /tmp/svc.strace
awk '{print $1}' /tmp/svc.strace | sort | uniq -c | sort -rn | head -6
echo "== strace 最后 16 行:"
tail -16 /tmp/svc.strace | cut -c1-130
pkill -x npusvc; sleep 0.5
echo "== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

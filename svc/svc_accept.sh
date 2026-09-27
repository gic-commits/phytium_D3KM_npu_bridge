#!/bin/bash
# M1 验收：缓存引擎（不再每请求重建）+ 张量级/图像级/并发/连续/状态
cd /dev/shm/nputest/svc || exit 1
GOLD=/dev/shm/nputest/20210828122250_3b289.jpg
echo "===== 0) 构建（默认已改回用缓存引擎）"
bash build.sh 2>&1 | grep -E "error:|构建完成|npusvc" | head -4

echo "===== 1) 起服务"
pkill -x npusvc; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
[ -S /tmp/npu.sock ] && echo "  服务已监听" || { echo "!! 未起来"; tail -5 /tmp/npusvc.log; exit 1; }

echo "===== 2) 图像级 face（应 1 张脸 box~(24.6,21.0,62.2,77.9) score~0.955）"
timeout 60 ./npu_cli face yunet_npu $GOLD 112 112 0 2>&1 | sed 's/^/  /'

echo "===== 3) 张量级 infer（3 输出）"
timeout 60 ./npu_cli infer yunet_npu $GOLD 112 112 0 /tmp/ac 2>&1 | tail -6 | sed 's/^/  /'

echo "===== 4) 连续 10 次（缓存引擎，应 ~0.45s/次）"
timeout 200 ./npu_cli bench yunet_npu $GOLD 112 112 0 10 2>&1 | tail -2 | sed 's/^/  /'

echo "===== 5) 并发：yunet(prio0) 与 yolov5s(prio2) 同时"
( timeout 200 ./npu_cli infer yolov5s 2.jpg 640 640 1 /tmp/ac_y5 2 > /tmp/cc_y5.log 2>&1; echo "  yolov5s rc=$?" ) &
( timeout 200 ./npu_cli infer yunet_npu $GOLD 112 112 0 /tmp/ac_yn 0 > /tmp/cc_yn.log 2>&1; echo "  yunet   rc=$?" ) &
wait
grep -E "输出" /tmp/cc_y5.log | sed 's/^/  y5: /'; grep -E "输出" /tmp/cc_yn.log | sed 's/^/  yn: /'

echo "===== 6) STATUS"
timeout 20 ./npu_cli status 2>&1 | sed 's/^/  /'

echo "===== 7) 服务日志（缓存/后处理）"
grep -E "init_graph|post|req#" /tmp/npusvc.log | tail -10 | sed 's/^/  /'
echo "===== 8) oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')；停服务"
pkill -x npusvc

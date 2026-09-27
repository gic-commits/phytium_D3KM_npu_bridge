#!/bin/bash
# M1 验证：服务起来 + 张量级 + 图像级 + 并发 + 连续 + 状态统计
cd /dev/shm/nputest/svc || exit 1
GOLD=/dev/shm/nputest/20210828122250_3b289.jpg
echo "===== 0) 构建"
bash build.sh 2>&1 | tail -6 || { echo "!! 构建失败"; exit 1; }

echo "===== 1) 起服务（--models 指向模型目录，客户端用短名）"
pkill -f 'npusvc --sock /tmp/npu.sock' 2>/dev/null
rm -f /tmp/npu.sock /tmp/npusvc.log
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
[ -S /tmp/npu.sock ] && echo "  服务已监听 /tmp/npu.sock" || { echo "!! 服务没起来"; cat /tmp/npusvc.log; exit 1; }

echo "===== 2) STATUS"
./npu_cli status 2>&1 | sed 's/^/  /'

echo "===== 3) 张量级 infer（yunet 金标图，dump 输出）"
./npu_cli infer yunet_npu $GOLD 112 112 0 /tmp/sv 2>&1 | sed 's/^/  /'

echo "===== 4) 图像级 face（应 1 张脸，box~(24.6,21.0,62.2,77.9) score~0.955）"
./npu_cli face yunet_npu $GOLD 112 112 0 2>&1 | sed 's/^/  /'

echo "===== 5) 并发：yunet(prio0) 与 yolov5s(prio2) 同时跑"
( ./npu_cli infer yolov5s 2.jpg 640 640 1 /tmp/sv_y5 2 > /tmp/conc_y5.log 2>&1; echo "  yolov5s rc=$?" ) &
( ./npu_cli infer yunet_npu $GOLD 112 112 0 /tmp/sv_yn 0 > /tmp/conc_yn.log 2>&1; echo "  yunet   rc=$?" ) &
wait
grep -E "输出|失败" /tmp/conc_y5.log | sed 's/^/  y5: /'
grep -E "输出|失败" /tmp/conc_yn.log | sed 's/^/  yn: /'

echo "===== 6) 连续 30 次"
./npu_cli bench yunet_npu $GOLD 112 112 0 30 2>&1 | sed 's/^/  /'

echo "===== 7) STATUS（累计）"
./npu_cli status 2>&1 | sed 's/^/  /'

echo "===== 8) 服务日志（后处理/缓存/请求）"
grep -E "post|init_graph|req#" /tmp/npusvc.log | tail -12 | sed 's/^/  /'

echo "===== 9) 收尾：停服务"
pkill -f 'npusvc --sock /tmp/npu.sock'; sleep 0.5
echo "  oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

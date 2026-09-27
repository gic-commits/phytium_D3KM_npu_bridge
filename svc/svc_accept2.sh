#!/bin/bash
# M1 验收 v2：多模型轮换（同一服务进程）+ 同模型连跑 + 并发 + 状态
cd /dev/shm/nputest/svc || exit 1
G=/dev/shm/nputest/20210828122250_3b289.jpg
I2=/dev/shm/nputest/2.jpg
pkill -x npusvc; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log /tmp/acc2_*
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --max-models 1 --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
[ -S /tmp/npu.sock ] || { echo "!! 服务未起来"; tail -5 /tmp/npusvc.log; exit 1; }
echo "===== 1) 模型轮换（同一服务进程内，每次切图）"
run() {
  timeout 60 ./npu_cli infer "$1" "$2" "$3" "$4" "$5" "/tmp/acc2_$6" > /tmp/acc2_run.log 2>&1
  local rc=$?
  printf "  %-13s rc=%d | %s\n" "$1" "$rc" \
    "$(grep -E '输出|失败' /tmp/acc2_run.log | tail -2 | tr '\n' ' ' | cut -c1-105)"
}
run yunet_npu $G  112 112 0 yn1
run yolov5s   $I2 640 640 1 y5a
run yunet_npu $G  112 112 0 yn2
run scrfd     $G  640 640 2 sc1
run Restnet50 $I2 224 224 1 rn1
CH=$(python3 /dev/shm/shape_of.py /dev/shm/nputest/model/ppocrv3_cls.json 2>/dev/null)
run ppocrv3_cls $I2 "$(echo $CH | awk '{print $2}')" "$(echo $CH | awk '{print $1}')" 1 pc1
run yunet_npu $G  112 112 0 yn3
echo "===== 2) 同模型连跑 10 次（应 ~0.42s/次，且不再 init）"
timeout 200 ./npu_cli bench yunet_npu $G 112 112 0 10 2>&1 | tail -2 | sed 's/^/  /'
echo "===== 3) 并发：yolov5s(prio2) + yunet(prio0)"
( timeout 120 ./npu_cli infer yolov5s $I2 640 640 1 /tmp/acc2_cy5 2 > /tmp/acc2_y5.log 2>&1; echo "  y5 rc=$?" ) &
( timeout 120 ./npu_cli infer yunet_npu $G 112 112 0 /tmp/acc2_cyn 0 > /tmp/acc2_yn.log 2>&1; echo "  yn rc=$?" ) &
wait
grep -E "输出|失败" /tmp/acc2_y5.log | sed 's/^/  y5: /'
grep -E "输出|失败" /tmp/acc2_yn.log | sed 's/^/  yn: /'
echo "===== 4) STATUS"
timeout 20 ./npu_cli status 2>&1 | sed 's/^/  /'
echo "===== 5) 服务日志"
printf "  init_graph 次数=%s\n" "$(grep -cE 'init_graph' /tmp/npusvc.log)"
grep -E "req#|cache|post" /tmp/npusvc.log | tail -14 | cut -c1-130 | sed 's/^/  /'
echo "===== 6) oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')；停服务"
pkill -x npusvc

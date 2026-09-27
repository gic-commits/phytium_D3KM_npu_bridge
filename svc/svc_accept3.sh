#!/bin/bash
# M1.5 验收（进程池版）：多模型轮换 / 同模型连跑 / 并发 / worker 生命周期 / 统计 / oops
# 用法: bash svc_accept3.sh [worker-timeout-ms]   默认 20000
cd /dev/shm/nputest/svc || exit 1
WTO=${1:-20000}
G=/dev/shm/nputest/20210828122250_3b289.jpg
I2=/dev/shm/nputest/2.jpg
pkill -x npusvc; pkill -x npusvc_pool; pkill -x npuworker; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npool.log /tmp/npuworker.log
nohup ./npusvc_pool --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --worker /dev/shm/nputest/svc/npuworker --worker-timeout-ms $WTO \
      > /tmp/npool.log 2>&1 </dev/null &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
[ -S /tmp/npu.sock ] || { echo "!! supervisor 未起来"; tail -5 /tmp/npool.log; exit 1; }
echo "===== 0) 启动参数"; head -1 /tmp/npool.log | cut -c1-160

run() {   # name img W H norm 标签
  timeout 60 ./npu_cli infer "$1" "$2" "$3" "$4" "$5" "/tmp/ac3_$6" > /tmp/ac3_run.log 2>&1
  local rc=$?
  printf "  %-13s rc=%d | %s\n" "$1" "$rc" \
    "$(grep -E '输出|失败' /tmp/ac3_run.log | tail -1 | cut -c1-95)"
}
echo "===== 1) 模型轮换（yunet↔yolov5s↔scrfd↔Restnet50↔ppocrv3_cls，共 7 次请求）"
run yunet_npu  $G  112 112 0 yn1
run yolov5s    $I2 640 640 1 y5a
run yunet_npu  $G  112 112 0 yn2
run scrfd      $G  640 640 2 sc1
run Restnet50  $I2 224 224 1 rn1
CH=$(python3 /dev/shm/shape_of.py /dev/shm/nputest/model/ppocrv3_cls.json 2>/dev/null)
run ppocrv3_cls $I2 "$(echo $CH | awk '{print $2}')" "$(echo $CH | awk '{print $1}')" 1 pc1
run yunet_npu  $G  112 112 0 yn3
echo "===== 2) 图像级 face（应 1 张脸 box~(24.6,21.0,62.2,77.9) score~0.9553）"
timeout 60 ./npu_cli face yunet_npu $G 112 112 0 2>&1 | tail -2 | sed 's/^/  /'
echo "===== 3) 同模型连跑 10 次（不应产生额外模型切换）"
SW0=$(grep -c "模型切换" /tmp/npool.log)
timeout 200 ./npu_cli bench yunet_npu $G 112 112 0 10 2>&1 | tail -2 | sed 's/^/  /'
SW1=$(grep -c "模型切换" /tmp/npool.log)
printf "  模型切换次数: bench 前=%s → 后=%s（应相等）\n" "$SW0" "$SW1"
echo "===== 4) 并发：yolov5s(prio2) + yunet(prio0) 同时"
( timeout 120 ./npu_cli infer yolov5s $I2 640 640 1 /tmp/ac3_cy5 2 > /tmp/ac3_y5.log 2>&1; echo "  y5 rc=$?" ) &
( timeout 120 ./npu_cli infer yunet_npu $G 112 112 0 /tmp/ac3_cyn 0 > /tmp/ac3_yn.log 2>&1; echo "  yn rc=$?" ) &
wait
grep -E "输出|失败" /tmp/ac3_y5.log | sed 's/^/  y5: /'
grep -E "输出|失败" /tmp/ac3_yn.log | sed 's/^/  yn: /'
echo "===== 5) STATUS（累计）"
timeout 20 ./npu_cli status 2>&1 | grep -E "MODE|MODELS|REQS|ERRS|TIMEOUTS|WORKER|SWITCHES" | sed 's/^/  /'
echo "===== 6) worker 生命周期日志（切换/回收/失败）"
grep -E "worker|失败|超时" /tmp/npool.log | tail -14 | cut -c1-135 | sed 's/^/  /'
echo "===== 7) worker 侧日志尾（后处理是否生效）"
grep -E "post|init_graph|INFER" /tmp/npuworker.log 2>/dev/null | tail -6 | sed 's/^/  /'
echo "===== 8) oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')；收尾停服务"
pkill -x npusvc_pool; pkill -x npuworker; sleep 1
echo "  残留: svc=$(pgrep -x npusvc_pool|wc -l) worker=$(pgrep -x npuworker|wc -l)"

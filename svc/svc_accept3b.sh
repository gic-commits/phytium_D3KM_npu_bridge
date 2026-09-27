#!/bin/bash
# 补测：A) 并发  B) worker 超时击杀 + 自愈（用"模型耗时 > worker 超时"来稳定触发击杀）
cd /dev/shm/nputest/svc || exit 1
G=/dev/shm/nputest/20210828122250_3b289.jpg
I2=/dev/shm/nputest/2.jpg
CH=$(python3 /dev/shm/shape_of.py /dev/shm/nputest/model/ppocrv3_cls.json 2>/dev/null)
CW=$(echo $CH | awk '{print $2}'); CHh=$(echo $CH | awk '{print $1}')
echo "(ppocrv3_cls 输入 ${CW}x${CHh})"

echo "===== A) 并发：yolov5s(prio2) + yunet(prio0)"
pkill -x npusvc_pool; pkill -x npuworker; pkill -x npu_cli; sleep 1
rm -f /tmp/npu.sock /tmp/npool.log /tmp/npuworker.log /tmp/c_*.log
nohup ./npusvc_pool --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --worker /dev/shm/nputest/svc/npuworker --worker-timeout-ms 20000 > /tmp/npool.log 2>&1 </dev/null &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
( timeout 90 ./npu_cli infer yolov5s   $I2 640 640 1 /tmp/c_y5 2 > /tmp/c_y5.log 2>&1 ) &
( timeout 90 ./npu_cli infer yunet_npu $G  112 112 0 /tmp/c_yn 0 > /tmp/c_yn.log 2>&1 ) &
wait
grep -E "输出|失败" /tmp/c_y5.log /tmp/c_yn.log | cut -c1-105 | sed 's/^/  /'
timeout 20 ./npu_cli status 2>&1 | grep -E "REQS|ERRS|TIMEOUTS|SWITCHES|WORKER_TIMEOUTS" | sed 's/^/  /'
pkill -x npusvc_pool; pkill -x npuworker; sleep 1

echo "===== B) worker 超时击杀 + 自愈（worker 超时=600ms）"
rm -f /tmp/npu.sock /tmp/npool2.log
nohup ./npusvc_pool --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --worker /dev/shm/nputest/svc/npuworker --worker-timeout-ms 600 > /tmp/npool2.log 2>&1 </dev/null &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
echo "  B1) yolov5s（~670ms > 600ms，预期被击杀 → 失败）："
timeout 40 ./npu_cli infer yolov5s $I2 640 640 1 /tmp/b1 2>&1 | tail -1 | sed 's/^/    /'
echo "  B2) ppocrv3_cls（~480ms < 600ms，预期成功 = 自愈）："
timeout 40 ./npu_cli infer ppocrv3_cls $I2 $CW $CHh 1 /tmp/b2 2>&1 | tail -1 | sed 's/^/    /'
echo "  B3) STATUS："
timeout 20 ./npu_cli status 2>&1 | grep -E "REQS|ERRS|WORKER_TIMEOUTS|SWITCHES|WORKER_PID" | sed 's/^/    /'
echo "  B4) 击杀/重生日志："
grep -E "击杀|已起|已停" /tmp/npool2.log | tail -6 | cut -c1-130 | sed 's/^/    /'
pkill -x npusvc_pool; pkill -x npuworker
echo "===== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')；残留 svc=$(pgrep -x npusvc_pool|wc -l) worker=$(pgrep -x npuworker|wc -l)"

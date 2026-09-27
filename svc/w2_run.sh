#!/bin/bash
# gdb(mangled 符号)：看库用什么 id/键匹配响应
cd /dev/shm/nputest/svc || exit 1
L=/usr/local/lib/libnpusession.so
W=$(nm $L | awk '/17WaitForCompletionEi/{print $3; exit}')
H=$(nm $L | awk '/HandleResponse/{print $3; exit}')
K=$(nm $L | awk '/12SetSubmitKeyEjj/{print $3; exit}')
echo "符号: W=$W H=$H K=$K"
cat > /tmp/w2.gdb <<EOF
set pagination off
set width 0
set confirm off
set breakpoint pending on
break $W
commands
  silent
  printf "WAIT id=%d this=%p\n", \$x1, \$x0
  x/10xw \$x0
  continue
end
break $H
commands
  silent
  printf "RESP a1=%d a2=%p a3=%d\n", \$x1, \$x2, \$x3
  if \$x2 != 0
    x/8xw \$x2
  end
  continue
end
break $K
commands
  silent
  printf "SETKEY seg=%d key=%d\n", \$x1, \$x2
  continue
end
continue
EOF
pkill -x npusvc; pkill -x npu_cli; sudo pkill -x gdb; sleep 1
rm -f /tmp/npu.sock /tmp/npusvc.log /tmp/w2.log
nohup ./npusvc --sock /tmp/npu.sock --models /dev/shm/nputest/model/ \
      --timeout-ms 20000 > /tmp/npusvc.log 2>&1 &
for i in $(seq 1 30); do [ -S /tmp/npu.sock ] && break; sleep 0.3; done
P=$(pgrep -x npusvc); echo "服务 pid=$P"
sudo gdb -p $P -batch -x /tmp/w2.gdb > /tmp/w2.log 2>&1 &
sleep 3
echo "== A) yunet:"
timeout 40 ./npu_cli infer yunet_npu /dev/shm/nputest/20210828122250_3b289.jpg 112 112 0 /tmp/x1 2>&1 | tail -1
echo "== B) yolov5s(预期挂):"
( timeout 30 ./npu_cli infer yolov5s /dev/shm/nputest/2.jpg 640 640 1 /tmp/x5 > /tmp/x5.log 2>&1 & )
sleep 12
sudo pkill -INT gdb; sleep 1
echo "== gdb 事件:"
grep -E "WAIT|RESP|SETKEY|^0x" /tmp/w2.log | head -46
pkill -x npu_cli; pkill -x npusvc
echo "== oops=$(dmesg | grep -ciE 'oops|BUG:|general protection')"

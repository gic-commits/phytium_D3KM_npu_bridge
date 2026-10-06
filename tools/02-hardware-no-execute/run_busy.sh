#!/bin/bash
# 诊断：worker 在"提交 3 次之后"是 CPU 忙还是阻塞
O=/home/greatwall/busy.txt
{
echo "########## BUSY? $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo dmesg -C
cd /opt/npu/python
nohup env MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py > /tmp/busy_out.txt 2>&1 &
for i in $(seq 1 100); do W=$(pgrep -x npuworker | tail -1); [ -n "$W" ] && break; sleep 0.2; done
echo "worker=$W"
for T in 3 6 10 15; do
  sleep 3
  if [ -d /proc/$W ]; then
    ST=$(sudo awk '{print "utime="$14" stime="$15}' /proc/$W/stat 2>/dev/null)
    SUB=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')
    echo "  t=${T}s  $ST  提交数=$SUB  总CPUticks=$(sudo awk '{print $14+$15}' /proc/$W/stat 2>/dev/null)"
  else
    echo "  t=${T}s  worker 已退出"
    break
  fi
done
echo "=== 最后时刻线程栈（看是否阻塞）==="
if [ -d /proc/$W ]; then
  sudo timeout 40 gdb -p $W -batch -ex "thread apply all bt 6" 2>&1 | grep -aE "^Thread|#[0-9]+ " | head -24
fi
echo "=== 客户端 ==="
tail -3 /tmp/busy_out.txt
echo "=== 提交/推送 ==="
echo "  submit=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
} > $O 2>&1
cat $O

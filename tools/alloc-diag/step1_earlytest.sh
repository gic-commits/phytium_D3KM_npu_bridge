#!/bin/bash
O=/home/greatwall/step1.txt
{
echo "=== 0. 重启后状态 ==="
uptime
echo
echo "=== 1. CMA 干净基线 ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo "  CMA 碎片基线:"
sudo cat /proc/pagetypeinfo 2>/dev/null | grep "DMA32, type          CMA" | sed 's/^/    /'
echo
echo "=== 2. 驱动/服务状态 ==="
lsmod | grep phytium_npu | awk '{print "  "$1" refcnt="$3}'
echo "  npusvc: $(systemctl is-active npusvc)"
echo "  已加载 srcversion: $(cat /sys/module/phytium_npu/srcversion 2>/dev/null)"
echo "  磁盘 srcversion:   $(modinfo /lib/modules/$(uname -r)/extra/phytium_npu.ko 2>/dev/null | awk '/srcversion/{print $2}')"
echo
echo "=== 3. 构建带 EARLYTEST 的模块 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_earlytest2.py || exit 1
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb14.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb14.log | head -10; exit 1; }
[ -f $T/phytium_npu.ko ] || { echo "  !! .ko 未生成"; exit 1; }
echo "  构建成功 $(ls -l --time-style=+%H:%M $T/phytium_npu.ko | awk '{print $6, $5"B"}')"
sudo cp -f $T/phytium_npu.ko /lib/modules/$K/extra/phytium_npu.ko
echo
echo "=== 4. 关键测试：模块加载时能否分配各种尺寸 ==="
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
for sz in 28459008 16777216 8388608 4194304 2097152; do
  sudo dmesg -C
  sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_earlytest=$sz 2>/dev/null
  sleep 1
  R=$(sudo dmesg | grep -a "VHA-EARLYTEST" | tail -1 | sed 's/.*\] //')
  echo "  $((sz/1048576)) MB: $R"
  sudo rmmod phytium_npu 2>/dev/null
  sleep 1
done
echo
echo "=== 5. 测试后 CMA 状态 ==="
awk '/CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 6. 恢复：加载正式模块（不带 earlytest） ==="
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
echo "  npusvc=$(systemctl is-active npusvc)"
echo "  srcversion=$(cat /sys/module/phytium_npu/srcversion)"
} > $O 2>&1
cat $O

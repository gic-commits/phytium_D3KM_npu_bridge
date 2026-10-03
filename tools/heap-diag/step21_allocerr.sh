#!/bin/bash
O=/home/greatwall/step21.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_allocerr.py || exit 1
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb17.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb17.log | head -10; exit 1; }
[ -f $T/phytium_npu.ko ] || { echo "  !! .ko 未生成"; exit 1; }
echo "  构建成功"
sudo cp -f $T/phytium_npu.ko /lib/modules/$K/extra/phytium_npu.ko
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
echo
echo "=== 跑 SenseVoice ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 600 python3 /tmp/sv_pool.py 2>&1 | tail -4
echo
echo "=== 关键：VHA-ALLOC-ERR 条数（验证分支是否执行） ==="
sudo dmesg | grep -ac "VHA-ALLOC-ERR" | sed 's/^/  /'
sudo dmesg | grep -a "VHA-ALLOC-ERR" | head -8 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 27MB 附近的 ERR ==="
sudo dmesg | grep -a "VHA-ALLOC-ERR" | grep -a "28459008\|31252480" | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 其它日志统计 ==="
for t in "VHA-ALLOC-RAW" "VHA-ALLOC-DIAG" "VHA-ALLOC]" "VHA-CMD"; do
  echo "  $t: $(sudo dmesg | grep -ac "$t")"
done
echo
echo "=== 报错 ==="
sudo tail -10 /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
} > $O 2>&1
cat $O

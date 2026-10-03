#!/bin/bash
O=/home/greatwall/step10.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_allocdiag.py || exit 1
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb16.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb16.log | head -10; exit 1; }
[ -f $T/phytium_npu.ko ] || { echo "  !! .ko 未生成"; exit 1; }
echo "  构建成功"
sudo cp -f $T/phytium_npu.ko /lib/modules/$K/extra/phytium_npu.ko
echo
echo "=== 重载 ==="
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
echo "=== 跑 SenseVoice（带 ALLOC-DIAG） ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -4
echo
echo "=== 关键：27MB 附近的 DIAG 日志 ==="
sudo dmesg | grep -a "VHA-ALLOC-DIAG" | tail -20 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 27MB 请求前后的 ALLOC ==="
sudo dmesg | grep -aE "VHA-ALLOC\]|VHA-ALLOC-DIAG" | tail -10 | sed 's/.*\] //' | sed 's/^/  /'
} > $O 2>&1
cat $O

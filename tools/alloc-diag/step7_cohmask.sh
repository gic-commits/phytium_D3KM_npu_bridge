#!/bin/bash
O=/home/greatwall/step7.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_cohmask.py || exit 1
echo "=== 构建 ==="
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko $T/phytium_npu_platform.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb15.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb15.log | head -10; exit 1; }
[ -f $T/phytium_npu.ko ] && [ -f $T/phytium_npu_platform.ko ] || { echo "  !! .ko 未生成"; exit 1; }
echo "  构建成功"
sudo cp -f $T/phytium_npu.ko /lib/modules/$K/extra/phytium_npu.ko
sudo cp -f $T/phytium_npu_platform.ko /lib/modules/$K/extra/phytium_npu_platform.ko
echo
echo "=== 重载 ==="
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
sudo dmesg -C
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
echo "  --- coherent_dma_mask 日志 ---"
sudo dmesg | grep -aiE "coherent_dma_mask|dma mask" | sed 's/^/    /'
echo "  npusvc=$(systemctl is-active npusvc)"
echo
echo "=== 回归 ==="
cd /home/greatwall/npu_harness
timeout 300 python3 verify_npu.py > /tmp/coh_v.log 2>&1
grep -aE "NPU run" /tmp/coh_v.log | tail -2 | sed 's/^/  /'
echo
echo "=== 关键：SenseVoice ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo "  --- npuworker 日志尾 ---"
sudo tail -14 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'
echo "  --- cma 失败 ---"
sudo dmesg | grep -ac "cma_alloc.*failed" | sed 's/^/    /'
} > $O 2>&1
cat $O

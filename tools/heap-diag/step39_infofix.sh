#!/bin/bash
O=/home/greatwall/step39.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_infofix.py || exit 1
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb19.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb19.log | head -10; exit 1; }
[ -f $T/phytium_npu.ko ] || { echo "  !! .ko 未生成"; exit 1; }
echo "  构建成功"
sudo cp -f $T/phytium_npu.ko /lib/modules/$K/extra/phytium_npu.ko
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu.ko vha_reset_each_run=1 vha_info_l3_size=536870912; sleep 2
sudo insmod /lib/modules/$K/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
echo "  l3_size=$(cat /sys/module/phytium_npu/parameters/vha_info_l3_size)"
echo
echo "=== 回归 ==="
cd /home/greatwall/npu_harness
sudo dmesg -C
timeout 300 python3 verify_npu.py > /tmp/info_v.log 2>&1
grep -aE "NPU run" /tmp/info_v.log | tail -2 | sed 's/^/  /'
echo
echo "=== 关键：SenseVoice ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo "  --- npuworker 日志尾 ---"
sudo tail -14 /var/log/npuworker.log 2>/dev/null | sed 's/^/    /'
echo "  --- 关键：是否还有 failed to allocate ---"
sudo grep -ac "failed to allocate" /var/log/npuworker.log 2>/dev/null | sed 's/^/    历史总数: /'
} > $O 2>&1
cat $O

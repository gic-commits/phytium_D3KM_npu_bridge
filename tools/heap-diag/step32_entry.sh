#!/bin/bash
O=/home/greatwall/step32.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu; K=$(uname -r)
python3 /tmp/apply_ioctlentry.py || exit 1
cd $T && make -C /lib/modules/$K/build M=$PWD clean > /dev/null 2>&1
rm -f $T/phytium_npu.ko
cd $T && make -C /lib/modules/$K/build M=$PWD CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules > /tmp/bb18.log 2>&1 || { echo "  !! 构建失败"; grep -E "ERROR|error:" /tmp/bb18.log | head -10; exit 1; }
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
echo "=== 关键：VHA-IOCTL-ENTRY 统计（按 nr） ==="
sudo dmesg | grep -aoE "nr=[0-9]+" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
echo "=== 总条数 ==="
sudo dmesg | grep -ac "VHA-IOCTL-ENTRY" | sed 's/^/  /'
echo
echo "=== 前 15 条 ==="
sudo dmesg | grep -a "VHA-IOCTL-ENTRY" | head -15 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 报错 ==="
sudo tail -8 /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
} > $O 2>&1
cat $O

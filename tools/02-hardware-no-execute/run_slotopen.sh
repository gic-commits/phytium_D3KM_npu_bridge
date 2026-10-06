#!/bin/bash
# SLOTOPEN：open() 复位序号 → 重建 → 验证 sensevoice（键应从 1 开始）
O=/home/greatwall/slotopen.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## SLOTOPEN $(date +%H:%M:%S) ##########"
python3 /tmp/apply_slotopen2.py $T/phytium_npu_uapi.c || exit 4
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | grep -aE "error|Error" | head -8
NEW_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
[ "$OLD_MD5" = "$NEW_MD5" ] && { echo "  ✗ 构建失败"; exit 5; }
echo "  ✓ .ko 更新"
sudo systemctl stop npusvc 2>/dev/null; sleep 2
sudo pkill -x npuworker 2>/dev/null; sleep 2
sudo modprobe -r phytium_npu_platform; sleep 2; sudo modprobe -r phytium_npu; sleep 2
lsmod | grep -q "^phytium_npu " && { echo "  ✗ 未卸掉"; exit 6; }
sudo cp -f $T/phytium_npu.ko $EXTRA/phytium_npu.ko
sudo cp -f $T/phytium_npu_platform.ko $EXTRA/phytium_npu_platform.ko 2>/dev/null
sudo depmod -a; sudo modprobe phytium_npu_platform; sleep 3
lsmod | grep "^phytium_npu " >/dev/null || { echo "  ✗ 未加载"; exit 7; }
echo "  ✓ srcversion=$(cat /sys/module/phytium_npu/srcversion)"
echo "  reset_on_open=$(cat $P/vha_slot_reset_on_open 2>/dev/null || echo 无)"

# 内存预防 + 键序列配置
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 1  | sudo tee $P/vha_rsp_slot >/dev/null
echo 1  | sudo tee $P/vha_rsp_slot_step >/dev/null
echo 0  | sudo tee $P/vha_slot_reset_on_sync >/dev/null
echo 0  | sudo tee $P/vha_slot_gap_ms >/dev/null
echo 0  | sudo tee $P/vha_rsp_on_read >/dev/null
echo 0  | sudo tee $P/vha_rsp_delay_ms >/dev/null
echo 1  | sudo tee $P/vha_use_irq_done >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
echo "--- sensevoice（step=1，open 复位）---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 140 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -4
echo "--- mobilenet 回归 3 次 ---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=3 NPU_SOCK=/run/npu/npu.sock timeout 120 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败"
cd /
echo "=== SLOTOPEN 命中 ==="
sudo dmesg | grep -ac "VHA-SLOTOPEN"
echo "=== slot 分配（起点）==="
sudo dmesg | grep -a "caller=" | sed 's/.*\[VHA-ALLOC\] //' | head -6 | sed 's/ \[phytium_npu\]//'
echo "=== 推送键序列 ==="
sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/  slot=/' | grep -a '^  slot=' | head -12 | tr '\n' ' '
echo
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  worker错误=$(sudo grep -acE 'ERROR|FATAL' /var/log/npuworker.log)  成功=$(sudo grep -ac 'INFER sensevoice ok' /var/log/npuworker.log)"
} > $O 2>&1
cat $O

#!/bin/bash
# SLOTSESS2：把会话复位加进 vha_push_response → 重建 → 验证
O=/home/greatwall/slotsess2.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## SLOTSESS2 $(date +%H:%M:%S) ##########"
python3 /tmp/apply_slotsess2.py $T/phytium_npu_uapi.c || exit 4
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | grep -aE "error|Error" | head -6
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
echo 1 | sudo tee $P/vha_rsp_slot_step >/dev/null
echo 0 | sudo tee $P/vha_slot_gap_ms >/dev/null
echo 1 | sudo tee $P/vha_slot_reset_on_session >/dev/null
echo 1 | sudo tee $P/vha_use_irq_done >/dev/null

sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
echo "--- mobilenet 连跑 6 次 ---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=6 NPU_SOCK=/run/npu/npu.sock timeout 200 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败"
echo "--- sensevoice ---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock timeout 150 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer"
cd /
echo "=== 推送入口（会话 + 进入时序号）==="
sudo dmesg | grep -a "PUSH-ENTER" | sed 's/.*\[VHA-PUSH-ENTER\] /  /' | head -14
echo "=== 会话切换复位 ==="
sudo dmesg | grep -a "SLOTSESS" | sed 's/.*\[VHA-SLOTSESS\] //' | head -10
echo "=== 推送序号序列 ==="
sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -24 | tr '\n' ' '
echo
echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
} > $O 2>&1
cat $O

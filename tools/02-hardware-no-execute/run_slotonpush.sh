#!/bin/bash
# ★ HERMES-SLOTONPUSH 构建+测试：让第一次真正推送 = 1，之后 +2
O=/home/greatwall/slotonpush.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## SLOT-ON-PUSH $(date +%H:%M:%S) ##########"
python3 /tmp/apply_slotonpush.py $T/phytium_npu_uapi.c || exit 4
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | grep -aE "error|Error|warning: .*slotonpush" | head -8
NEW_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
[ "$OLD_MD5" = "$NEW_MD5" ] && { echo "  ✗ .ko 未更新"; exit 5; }
echo "  ✓ 构建通过"
sudo systemctl stop npusvc 2>/dev/null; sleep 2
sudo pkill -x npuworker 2>/dev/null; sleep 2
sudo modprobe -r phytium_npu_platform; sleep 2; sudo modprobe -r phytium_npu; sleep 2
lsmod | grep -q "^phytium_npu " && { echo "  ✗ 未卸掉"; exit 6; }
sudo cp -f $T/phytium_npu.ko $EXTRA/phytium_npu.ko
sudo cp -f $T/phytium_npu_platform.ko $EXTRA/phytium_npu_platform.ko 2>/dev/null
sudo depmod -a; sudo modprobe phytium_npu_platform; sleep 3
lsmod | grep "^phytium_npu " >/dev/null || { echo "  ✗ 未加载"; exit 7; }
echo "  ✓ srcversion=$(cat /sys/module/phytium_npu/srcversion)"
grep -q "vha_slot_on_push" /proc/modules && echo "" || ls $P/vha_slot_on_push && echo "  ✓ 新参数已存在"

echo 1 | sudo tee $P/vha_use_irq_done >/dev/null
echo 0 | sudo tee $P/vha_resp_fix >/dev/null
echo 0 | sudo tee $P/vha_rsp_delay_ms >/dev/null
echo 0 | sudo tee $P/vha_rsp_replay >/dev/null
echo 0 | sudo tee $P/vha_rsp_on_read >/dev/null
echo 1 | sudo tee $P/vha_slot_reset_on_sync >/dev/null
echo 1 | sudo tee $P/vha_slot_reset_on_open >/dev/null
echo 1 | sudo tee $P/vha_slot_on_push >/dev/null
echo 1 | sudo tee $P/vha_rsp_slot >/dev/null
echo 2 | sudo tee $P/vha_rsp_slot_step >/dev/null
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -n 1; sudo dmesg -C
cd /opt/npu/python
echo "--- mobilenet 3 次 ---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=3 NPU_SOCK=/run/npu/npu.sock timeout 120 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败"
echo "--- sensevoice ---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 170 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer"
cd /
echo -n "  ★推送键: "
sudo dmesg | grep -a 'VHA-PUSHRSP' | grep -aoE 'slot=[0-9]+' | head -12 | tr '\n' ' '
echo
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  推送=$(sudo dmesg | grep -ac VHA-PUSHRSP)"
echo "  成功=$(sudo grep -ac 'INFER sensevoice ok' /var/log/npuworker.log)  错误=$(sudo grep -acE 'ERROR|FATAL' /var/log/npuworker.log)"
} > $O 2>&1
tail -24 $O

#!/bin/bash
# SLOTSESS：会话切换复位序号 → 重建 → 验证
O=/home/greatwall/slotsess.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## SLOTSESS $(date +%H:%M:%S) ##########"
python3 /tmp/apply_slotsess.py $T/phytium_npu_uapi.c || exit 4
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

set_p() { echo "$2" | sudo tee $P/$1 >/dev/null 2>&1; }
set_p vha_sim_mode 0; set_p vha_resp_fix 0; set_p vha_vrsp_skip 1; set_p vha_push_enable 1
set_p vha_use_irq_done 1
set_p vha_rsp_slot 1; set_p vha_rsp_slot_step 1; set_p vha_rsp_slot_max 0
set_p vha_slot_gap_ms 0; set_p vha_slot_reset_on_sync 1
set_p vha_slot_reset_on_session 1
set_p vha_rsp_replay 0; set_p vha_rsp_delay_ms 0; set_p vha_settle_ms 0; set_p vha_rsp_on_read 0
set_p vha_reset_each_run 0; set_p vha_clr_status_before_start 0; set_p vha_suspend_after_run 0
set_p vha_mmu_cfg_each_submit 0; set_p vha_force_resume_each_submit 0
echo "  step=1 reset_on_session=$(cat $P/vha_slot_reset_on_session)"
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
echo "--- mobilenet 连跑 6 次 ---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=6 NPU_SOCK=/run/npu/npu.sock timeout 200 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败"
echo "--- sensevoice ---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock timeout 150 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer"
cd /
echo "=== 会话切换复位 ==="
sudo dmesg | grep -a "SLOTSESS" | sed 's/.*\[VHA-SLOTSESS\] //' | head -10
echo "=== 推送序列 ==="
sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -22 | tr '\n' ' '
echo
echo "  submit=$(sudo dmesg | grep -ac 'VHA-SUBMIT] done=')  push=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')"
} > $O 2>&1
cat $O

#!/bin/bash
# MMUDBG：重建 + 重载 + 连跑 4 次，对照两个会话的页表基址与设备映射寄存器
O=/home/greatwall/mmudbg.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## MMUDBG $(date +%H:%M:%S) ##########"
python3 /tmp/apply_mmudbg.py $T/phytium_npu_uapi.c || exit 4
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | grep -aE "error|Error" | head -6
NEW_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
[ "$OLD_MD5" = "$NEW_MD5" ] && { echo "  ✗ 构建失败"; exit 5; }
echo "  ✓ .ko 更新"

sudo systemctl stop npusvc 2>/dev/null; sleep 3
sudo pkill -x npuworker 2>/dev/null; sleep 2
sudo modprobe -r phytium_npu_platform 2>&1; sleep 2
sudo modprobe -r phytium_npu 2>&1; sleep 2
lsmod | grep -q "^phytium_npu " && { echo "  ✗ 未卸掉"; exit 6; }
sudo cp -f $T/phytium_npu.ko $EXTRA/phytium_npu.ko
sudo cp -f $T/phytium_npu_platform.ko $EXTRA/phytium_npu_platform.ko 2>/dev/null
sudo depmod -a
sudo modprobe phytium_npu_platform 2>&1; sleep 3
lsmod | grep "^phytium_npu " >/dev/null || { echo "  ✗ 未加载"; exit 7; }
echo "  ✓ srcversion=$(cat /sys/module/phytium_npu/srcversion)"

set_p() { echo "$2" | sudo tee $P/$1 >/dev/null 2>&1; }
set_p vha_sim_mode 0; set_p vha_resp_fix 0; set_p vha_vrsp_skip 1; set_p vha_push_enable 1
set_p vha_rsp_slot 1; set_p vha_rsp_slot_step 0; set_p vha_rsp_slot_max 0
set_p vha_rsp_replay 0; set_p vha_rsp_delay_ms 0; set_p vha_settle_ms 0; set_p vha_vrsp_fix 0
set_p vha_slot_reset_on_sync 1; set_p vha_slot_gap_ms 0; set_p vha_rsp_on_read 0; set_p vha_rsp_cycle_ms 0
set_p vha_reset_each_run 0; set_p vha_clr_status_before_start 0; set_p vha_suspend_after_run 0
set_p vha_mmu_cfg_each_submit 0

sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
sudo nohup dmesg -w > /tmp/dmesg_mmudbg.log 2>&1 &
DW=$!
cd /opt/npu/python
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=4 NPU_SOCK=/run/npu/npu.sock timeout 150 python3 /tmp/loop_client.py 2>&1 | tail -7
cd /
sleep 1; kill $DW 2>/dev/null
echo "=== MMUDBG（对照两会话）==="
grep -a "VHA-MMUDBG" /tmp/dmesg_mmudbg.log | sed 's/.*\[VHA/[VHA/' | head -10
echo "=== SUBMIT done ==="
grep -a "VHA-SUBMIT] done=" /tmp/dmesg_mmudbg.log | sed 's/.*\[VHA-SUBMIT\] /[SUBMIT] /' | head -8
} > $O 2>&1
cat $O

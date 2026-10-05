#!/bin/bash
# IRQDONE：以完成中断为提交完成判据 → 重建 → 重载 → mobilenet 连跑 6 次
O=/home/greatwall/irqdone.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## IRQDONE $(date +%H:%M:%S) ##########"
python3 /tmp/apply_irqdone.py $T/phytium_npu_common.c $T/phytium_npu_uapi.c || exit 4
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | grep -aE "error|Error|warning: implicit" | head -8
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
set_p vha_mmu_cfg_each_submit 0; set_p vha_force_resume_each_submit 0
set_p vha_use_irq_done 1
echo "  use_irq_done=$(cat $P/vha_use_irq_done)"

sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
echo "--- mobilenet 连跑 6 次（同一 worker）---"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=6 NPU_SOCK=/run/npu/npu.sock timeout 220 python3 /tmp/loop_client.py 2>&1 | tail -9
echo "--- Restnet50 连跑 4 次 ---"
MB_MODEL=Restnet50 MB_SHAPE=1,3,224,224 MB_N=4 NPU_SOCK=/run/npu/npu.sock timeout 150 python3 /tmp/loop_client.py 2>&1 | tail -6
cd /
echo "=== 完成判据分布 ==="
sudo dmesg | grep -ao "来源=[^ ]* done=[01]" | sort | uniq -c
echo "=== SUBMIT done ==="
sudo dmesg | grep -a "VHA-SUBMIT] done=" | sed 's/.*\[VHA-SUBMIT\] /  [SUBMIT] /' | head -12
echo "=== 推响应次数 ==="
sudo dmesg | grep -ac "VHA-PUSHRSP"
} > $O 2>&1
cat $O

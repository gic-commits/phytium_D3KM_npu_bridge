#!/bin/bash
# CLRSTATUS：启动前清 NPU_CH0_STATUS → 重建 → 重载 → 连跑测试
O=/home/greatwall/clrstatus.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## CLRSTATUS $(date +%H:%M:%S) ##########"
python3 /tmp/apply_clrstatus.py $T/phytium_npu_uapi.c || exit 4
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
set_p vha_reset_each_run 0; set_p vha_clr_status_before_start 1; set_p vha_suspend_after_run 1
echo "  clr_status=$(cat $P/vha_clr_status_before_start) reset_each_run=$(cat $P/vha_reset_each_run)"

sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
sudo nohup dmesg -w > /tmp/dmesg_clr.log 2>&1 &
DW=$!
cd /opt/npu/python
echo "--- mobilenet 连跑 3 次 ---"
for i in 1 2 3; do
  MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_MODE=both MB_TAG=mb$i NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "推理 |infer 异常" | sed "s/^/  /"
done
echo "--- 换成 Restnet50 再跑 ---"
MB_MODEL=Restnet50 MB_SHAPE=1,3,224,224 MB_MODE=both MB_TAG=rs NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "推理 |infer 异常" | sed "s/^/  /"
echo "--- sensevoice ---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理 |infer 异常" | sed "s/^/  /"
cd /
sleep 1; kill $DW 2>/dev/null
echo "=== CLRSTATUS 命中情况 ==="
grep -ac "VHA-CLRSTATUS" /tmp/dmesg_clr.log
grep -a "VHA-CLRSTATUS" /tmp/dmesg_clr.log | sed 's/.*\[VHA/[VHA/' | head -6
echo "=== SUBMIT done 汇总 ==="
grep -a "VHA-SUBMIT] done=" /tmp/dmesg_clr.log | sed 's/.*\[VHA-SUBMIT\] /[SUBMIT] /' | head -10
} > $O 2>&1
cat $O

#!/bin/bash
# RSPCYCLE：定时器循环推送响应 key → 重建 → 重载 → 测
O=/home/greatwall/rcycle.txt
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
P=/sys/module/phytium_npu/parameters
{
echo "########## RSPCYCLE $(date +%H:%M:%S) ##########"
python3 /tmp/apply_rspcycle.py $T/phytium_npu_uapi.c || exit 4
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
set_p vha_rsp_slot 1; set_p vha_rsp_slot_step 2; set_p vha_rsp_slot_max 15
set_p vha_rsp_replay 0; set_p vha_rsp_delay_ms 0; set_p vha_settle_ms 0; set_p vha_vrsp_fix 0
set_p vha_slot_reset_on_sync 1; set_p vha_slot_gap_ms 0; set_p vha_sync_beat_ms 0
set_p vha_rsp_on_read 0; set_p vha_rsp_cycle_ms 25
echo "  cycle_ms=$(cat $P/vha_rsp_cycle_ms) slot=$(cat $P/vha_rsp_slot) step=$(cat $P/vha_rsp_slot_step) max=$(cat $P/vha_rsp_slot_max) reset=$(cat $P/vha_slot_reset_on_sync)"

sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 7
sudo dmesg -C
sudo nohup dmesg -w > /tmp/dmesg_cyc.log 2>&1 &
DW=$!
sleep 1
cd /opt/npu/python
S=$(date +%s)
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=t NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/mb_client.py > /tmp/cyc_client.txt 2>&1
E=$(date +%s)
kill $DW 2>/dev/null
echo "  耗时 $((E-S))s"
grep -aE "load ->|推理 |infer 异常" /tmp/cyc_client.txt
echo "=== 推的 slot（前 30）==="
grep -a "VHA-PUSHRSP" /tmp/dmesg_cyc.log | grep -a "sess=" | sed 's/.*\[VHA/[VHA/' | head -30
echo "=== 服务端 ==="
sudo journalctl -u npusvc --no-pager -n 4 | tail -4
echo "=== 回归 mobilenet x2 ==="
sudo systemctl restart npusvc; sleep 6
cd /opt/npu/python
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_MODE=both MB_TAG=mb1 NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理 |infer 异常"
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_MODE=both MB_TAG=mb2 NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理 |infer 异常"
cd /
} > $O 2>&1
cat $O

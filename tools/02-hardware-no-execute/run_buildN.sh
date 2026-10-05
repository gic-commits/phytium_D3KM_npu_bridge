#!/bin/bash
# 通用：打指定补丁 → 重建 → 断言式重载 → 验证
# 用法: bash run_buildN.sh <补丁脚本名>
# 用 `dmesg -w` 落盘，避免环形缓冲把关键行冲掉
O=/home/greatwall/buildN.txt
PATCH=${1:-/tmp/apply_slotgap.py}
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
KDIR=/lib/modules/$(uname -r)/build
EXTRA=/lib/modules/$(uname -r)/extra
{
echo "########## 补丁=$PATCH $(date +%H:%M:%S) ##########"
echo "=== 1. 打补丁 ==="
python3 $PATCH $T/phytium_npu_uapi.c || exit 4

echo "=== 2. 重建 ==="
OLD_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
make -C $KDIR M=$T CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules 2>&1 | tail -3
NEW_MD5=$(md5sum $T/phytium_npu.ko | cut -d' ' -f1)
[ "$OLD_MD5" = "$NEW_MD5" ] && { echo "  ✗ .ko 未变"; exit 5; }
echo "  ✓ .ko 更新"

echo "=== 3. 重载（断言）==="
sudo systemctl stop npusvc 2>/dev/null; sleep 3
sudo pkill -x npuworker 2>/dev/null; sleep 2
OLD_SV=$(cat /sys/module/phytium_npu/srcversion 2>/dev/null)
sudo modprobe -r phytium_npu_platform 2>&1; sleep 2
sudo modprobe -r phytium_npu 2>&1; sleep 2
lsmod | grep -q "^phytium_npu " && { echo "  ✗ 未卸掉"; exit 6; }
sudo cp -f $T/phytium_npu.ko $EXTRA/phytium_npu.ko
sudo cp -f $T/phytium_npu_platform.ko $EXTRA/phytium_npu_platform.ko 2>/dev/null
sudo depmod -a
sudo modprobe phytium_npu_platform 2>&1; sleep 3
lsmod | grep "^phytium_npu " >/dev/null || { echo "  ✗ 未加载"; exit 7; }
NEW_SV=$(cat /sys/module/phytium_npu/srcversion 2>/dev/null)
echo "  ✓ srcversion: $OLD_SV -> $NEW_SV"

echo "=== 4. 设参 ==="
for KV in "vha_sim_mode 0" "vha_resp_fix 0" "vha_vrsp_skip 1" "vha_push_enable 1" \
          "vha_rsp_slot 1" "vha_rsp_slot_step 2" "vha_rsp_slot_max 0" \
          "vha_rsp_replay 0" "vha_rsp_delay_ms 0" "vha_settle_ms 0" "vha_vrsp_fix 0" \
          "vha_slot_reset_on_sync 0" "vha_slot_gap_ms 200"; do
  set -- $KV; sudo sh -c "echo $2 > $P/$1" 2>/dev/null
done
echo "  step=$(cat $P/vha_rsp_slot_step) reset_on_sync=$(cat $P/vha_slot_reset_on_sync 2>/dev/null) gap=$(cat $P/vha_slot_gap_ms 2>/dev/null)"
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 7

echo "=== 5. 开 dmesg -w 落盘 + 跑 sensevoice ==="
sudo dmesg -C
sudo nohup dmesg -w > /tmp/dmesg_live.log 2>&1 &
DW=$!
sleep 1
cd /opt/npu/python
S=$(date +%s)
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=t NPU_SOCK=/run/npu/npu.sock timeout 90 python3 /tmp/mb_client.py > /tmp/bN_client.txt 2>&1
E=$(date +%s)
kill $DW 2>/dev/null
echo "  耗时 $((E-S))s"
grep -aE "load ->|推理 |infer 异常" /tmp/bN_client.txt

echo "=== 6. 我们推的 slot（落盘日志）==="
grep -a "VHA-PUSHRSP" /tmp/dmesg_live.log | grep -aoE "slot=[0-9]+" | head -30 | tr '\n' ' '; echo
echo -n "  推送总数: "; grep -ac "VHA-PUSHRSP" /tmp/dmesg_live.log
echo "  序号归零次数: $(grep -ac SLOTGAP /tmp/dmesg_live.log)"
grep -a SLOTGAP /tmp/dmesg_live.log | head -4
echo "=== 7. 提交完成情况 ==="
grep -ac "VHA-TIME" /tmp/dmesg_live.log
grep -a "等待完成" /tmp/dmesg_live.log | grep -aoE "来源=[^ ]* done=[0-9]" | sort | uniq -c
echo "=== 8. 服务端 ==="
sudo journalctl -u npusvc --no-pager -n 4 | tail -4
cd /
} > $O 2>&1
cat $O

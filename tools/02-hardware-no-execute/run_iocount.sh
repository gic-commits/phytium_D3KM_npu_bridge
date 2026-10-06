#!/bin/bash
# 统计各类 ioctl 次数 + 提交路径各标记次数（无 gdb，避免拖慢）
O=/home/greatwall/iocount.txt
{
echo "########## IOCOUNT $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
echo 1 | sudo tee $P/vha_rsp_slot >/dev/null
echo 1 | sudo tee $P/vha_rsp_slot_step >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 150 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|infer"
cd /
echo "=== 各 ioctl cmd 次数 ==="
sudo dmesg | grep -aoE "IOCTL-ENTRY\] cmd=0x[0-9a-f]+" | sed 's/.*cmd=/  /' | sort | uniq -c | sort -rn
echo "=== 提交路径标记 ==="
for K in "VHA-TD-A] before:" "VHA-TD-B] before start:" "VHA-SUBMIT] done=" "VHA-PUSHRSP" "VHA-READ" "VHA-TIME] 等待完成"; do
  printf "  %-28s = %s\n" "$K" "$(sudo dmesg | grep -ac "$K")"
done
echo "=== 是否有 ioctl 未实现/被拒 ==="
sudo dmesg | grep -aiE "VHA.*(unknown|unsupported|invalid|not impl)" | sed 's/.*\[VHA/  [VHA/' | head -6
echo "=== 推送 slot 序列 ==="
sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -20 | tr '\n' ' '
echo
} > $O 2>&1
cat $O

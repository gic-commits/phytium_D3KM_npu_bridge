#!/bin/bash
# 清空后跑一次，统计各类 ioctl 的**次数与顺序**
P=/sys/module/phytium_npu/parameters
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 0 | sudo tee $P/vha_slot_reset_on_sync >/dev/null
echo 6  | sudo tee $P/vha_rsp_slot >/dev/null   # 故意用 6 好辨认
echo 1  | sudo tee $P/vha_rsp_slot_step >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 120 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "infer" | head -2
cd /
echo "=== 各类 ioctl 次数 ==="
sudo dmesg | grep -aoE "IOCTL-ENTRY\] cmd=0x[0-9a-f]+ nr=[0-9]+" | sed 's/.*cmd=/  cmd=/' | sort | uniq -c | sort -rn
echo "=== ioctl 顺序（前 30，含 write 提交标记）==="
sudo dmesg | grep -aE "IOCTL-ENTRY|VHA-TD-A] before:|VHA-PUSHRSP" | sed -E 's/.*\[VHA-([A-Z-]+)\](.*)$/\1\2/' | sed 's/真实模式推响应.*/PUSH/; s/.*slot=\([0-9]*\)/PUSH slot=\1/; s/ before:.*/SUBMIT-ENTRY/; s/cmd=0x\([0-9a-f]*\) nr=\([0-9]*\).*/IOCTL nr=\2/' | head -30

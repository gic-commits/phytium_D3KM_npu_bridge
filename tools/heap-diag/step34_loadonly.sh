#!/bin/bash
O=/home/greatwall/step34.txt
{
echo "=== 1. 关键：清空 dmesg，只跑加载（不推理），立即抓 ==="
sudo dmesg -C
sudo systemctl restart npusvc; sleep 8
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 300 python3 -c "
import sys; sys.path.insert(0,'/opt/npu/python')
import npu_client as npu
c = npu.connect()
try: print('load ->', c.load('sensevoice'))
except Exception as e: print('load 异常:', str(e)[:80])
" 2>&1 | tail -2
echo
echo "  --- 立即统计 VHA-IOCTL-ENTRY ---"
sudo dmesg | grep -ac "VHA-IOCTL-ENTRY" | sed 's/^/    总条数: /'
sudo dmesg | grep -aoE "nr=[0-9]+ sess" | sort | uniq -c | sed 's/^/    /'
echo
echo "  --- 前 20 条 ---"
sudo dmesg | grep -a "VHA-IOCTL-ENTRY" | head -20 | sed 's/.*\] //' | sed 's/^/    /'
echo
echo "=== 2. 关键：dmesg 总行数（看是否被冲） ==="
sudo dmesg | wc -l | sed 's/^/  /'
echo
echo "=== 3. 关键：VHA-CRC 条数（日志大户） ==="
sudo dmesg | grep -ac "VHA-CRC" | sed 's/^/  /'
echo
echo "=== 4. 关键：临时关闭 CRC 日志（若有参数） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "vha_crc\|CRC_LOG\|crc_log" $T/phytium_npu_uapi.c | head -5 | sed 's/^/  /'
echo
echo "=== 5. 关键：驱动里 CRC 日志是否可关 ==="
for p in $(ls /sys/module/phytium_npu/parameters/ 2>/dev/null); do
  echo "  $p = $(cat /sys/module/phytium_npu/parameters/$p 2>/dev/null)"
done
} > $O 2>&1
cat $O

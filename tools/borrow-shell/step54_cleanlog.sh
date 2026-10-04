#!/bin/bash
O=/home/greatwall/step54.txt
{
echo "=== 1. 清空 npuworker.log 后再跑 ==="
sudo sh -c "> /var/log/npuworker.log"
export VHA_VADDR_BASE=0x48200000
export VHA_VADDR_SIZE=0x40000000
export VHA_VADDR_OFFS=0
export VHA_VADDR_PAGESIZE=4096
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -4
echo
echo "=== 2. 本次完整日志 ==="
sudo cat /var/log/npuworker.log 2>/dev/null | sed 's/^/  /'
echo
echo "=== 3. 驱动侧统计 ==="
echo "  ALLOC: $(sudo dmesg | grep -ac 'alloc size=')"
echo "  28459008: $(sudo dmesg | grep -ac '28459008')"
echo "  最大: $(sudo dmesg | grep -ao 'alloc size=[0-9]*' | awk -F= '{print $2}' | sort -rn | head -1)"
} > $O 2>&1
cat $O

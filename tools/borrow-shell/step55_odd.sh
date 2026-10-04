#!/bin/bash
O=/home/greatwall/step55.txt
{
echo "=== 关键：size 必须是奇数（(size-1) & flags == 0） ==="
echo "  flags=1, size=0x40000000: (0x40000000-1) & 1 = 1 -> 失败"
echo "  flags=1, size=0x40000001: (0x40000001-1) & 1 = 0 -> 通过"
echo
echo "=== 试 size=0x40000001 ==="
export VHA_VADDR_BASE=0x48200000
export VHA_VADDR_SIZE=0x40000001
export VHA_VADDR_OFFS=0
export VHA_VADDR_PAGESIZE=4096
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
sudo sh -c "> /var/log/npuworker.log"
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -4
echo
echo "=== 报错检查 ==="
echo "  No heap capable: $(sudo grep -ac 'No heap capable' /var/log/npuworker.log 2>/dev/null)"
echo "  failed to allocate: $(sudo grep -ac 'failed to allocate' /var/log/npuworker.log 2>/dev/null))"
echo "  --- 最近报错 ---"
sudo grep -a "ERROR\|FATAL\|failed\|Cannot" /var/log/npuworker.log 2>/dev/null | tail -10 | sed 's/^/    /'
echo
echo "=== 驱动侧统计 ==="
echo "  ALLOC: $(sudo dmesg | grep -ac 'alloc size=')"
echo "  最大: $(sudo dmesg | grep -ao 'alloc size=[0-9]*' | awk -F= '{print $2}' | sort -rn | head -1)"
echo "  28459008: $(sudo dmesg | grep -ac '28459008')"
} > $O 2>&1
cat $O

#!/bin/bash
O=/home/greatwall/step52.txt
{
echo "=== 1. 设环境变量并跑 SenseVoice ==="
export VHA_VADDR_BASE=0x48200000
export VHA_VADDR_SIZE=0x40000000
export VHA_VADDR_OFFS=0
export VHA_VADDR_PAGESIZE=4096
echo "  VHA_VADDR_BASE=$VHA_VADDR_BASE"
echo "  VHA_VADDR_SIZE=$VHA_VADDR_SIZE"
echo "  VHA_VADDR_OFFS=$VHA_VADDR_OFFS"
echo "  VHA_VADDR_PAGESIZE=$VHA_VADDR_PAGESIZE"
echo
echo "=== 2. 重启服务（继承环境变量） ==="
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 2
sudo insmod /lib/modules/$(uname -r)/extra/phytium_npu.ko vha_reset_each_run=1; sleep 2
sudo insmod /lib/modules/$(uname -r)/extra/phytium_npu_platform.ko; sleep 2
sudo systemctl start npusvc; sleep 5
sudo sh -c "echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode"
echo "  npusvc=$(systemctl is-active npusvc)"
echo
echo "=== 3. 跑 SenseVoice ==="
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 900 python3 /tmp/sv_pool.py 2>&1 | tail -6
echo
echo "=== 4. 报错检查 ==="
echo "  failed to allocate: $(sudo grep -ac 'failed to allocate' /var/log/npuworker.log 2>/dev/null)"
echo "  No heap capable: $(sudo grep -ac 'No heap capable' /var/log/npuworker.log 2>/dev/null))"
echo "  --- 最近报错 ---"
sudo grep -a "ERROR\|FATAL\|failed\|Cannot" /var/log/npuworker.log 2>/dev/null | tail -10 | sed 's/^/    /'
echo
echo "=== 5. 驱动侧分配统计 ==="
echo "  ALLOC: $(sudo dmesg | grep -ac 'alloc size=')"
echo "  最大: $(sudo dmesg | grep -ao 'alloc size=[0-9]*' | awk -F= '{print $2}' | sort -rn | head -1)"
echo "  28459008: $(sudo dmesg | grep -ac '28459008')"
} > $O 2>&1
cat $O

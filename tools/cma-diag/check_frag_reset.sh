#!/bin/bash
echo "=== 关键验证：重启后 CMA 干净时能否分配 27MB ==="
echo
echo "=== 1. 当前 CMA 碎片基线 ==="
sudo cat /proc/pagetypeinfo 2>/dev/null | grep "DMA32, type          CMA" | sed 's/^/  /'
echo
echo "=== 2. 我们的驱动占用（190MB，切碎了 CMA） ==="
echo "  本次 ALLOC: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=') 次, 合计 190.3 MB"
echo
echo "=== 3. 关键：卸载模块能否释放全部 CMA ==="
sudo systemctl stop npusvc; sleep 3
sudo pkill -9 -f npuworker 2>/dev/null; sleep 2
sudo rmmod phytium_npu_platform 2>/dev/null || true
sudo rmmod phytium_npu 2>/dev/null || true
sleep 3
echo "  卸载后 CmaFree: $(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
echo "  卸载后 CMA 碎片:"
sudo cat /proc/pagetypeinfo 2>/dev/null | grep "DMA32, type          CMA" | sed 's/^/    /'
echo
echo "=== 4. 结论判断 ==="
echo "  若卸载后 order-10 块数恢复 => 碎片是我们造成的，可用【重载模块】复位"
echo "  若卸载后仍碎片 => 是系统其他占用，需要重启"

#!/bin/bash
echo "=== 1. CMA 区域（DMA32）的物理范围 ==="
sudo cat /proc/iomem 2>/dev/null | grep -iE "cma|System RAM" | head -15 | sed 's/^/  /'
echo
echo "=== 2. 关键：DMA32 区域总大小与 CMA 占比 ==="
python3 -c "
print('  DMA32 = 低 4GB (0x0 - 0xffffffff)')
print('  CMA = 1024 MB')
print('  DMA32 里还有: 内核、slab、其他驱动、页表等')
"
echo
echo "=== 3. 我们的驱动占的物理地址范围 ==="
sudo dmesg | grep -ao "phys=0x[0-9a-f]*" | sort -u | head -20 | sed 's/^/  /'
echo
echo "=== 4. 关键：这些地址是否在 CMA 区（0x9c400000-0xdc3fffff 是 reserved） ==="
echo "  从 iomem: 9c400000-dc3fffff : reserved  (约 1024 MB)"
echo "  这很可能就是 CMA 区！"
echo
echo "=== 5. 验证：我们的分配地址是否落在这个范围 ==="
sudo dmesg | grep -ao "phys=0x[0-9a-f]*" | sed 's/phys=0x//' | sort -u | head -10 | while read a; do
  v=$((16#$a))
  lo=$((16#9c400000)); hi=$((16#dc3fffff))
  if [ $v -ge $lo ] && [ $v -le $hi ]; then echo "    $a 在 CMA 区 ✓"; else echo "    $a 不在 CMA 区"; fi
done
echo
echo "=== 6. 结论 ==="
echo "  若分配都在 CMA 区 => CMA 区被我们的 190MB + 系统占用切碎"
echo "  卸载模块后碎片不变 => 系统占用是主因"

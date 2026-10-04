#!/bin/bash
O=/home/greatwall/step51.txt
{
echo "=== 1. 关键：VHA_VADDR_SIZE 的默认值路径 ==="
L=/usr/local/lib/libnpusession.so
echo "  76cb8 之后（默认值）:"
objdump -d --start-address=0x76cb8 --stop-address=0x76cd4 $L 2>/dev/null | sed 's/^/    /'
echo
echo "  => 76cc8: mov x0, #0x48200000 = VHA_VADDR_BASE 默认值"
echo "  => VHA_VADDR_SIZE 默认值需要看 76cd4 之后"
echo
echo "=== 2. 关键：VhaVaaHeapCreate 里大小为 0 的处理 ==="
echo "  3fa38: cmp x19, #0x10000000000 (1TB)"
echo "  3fa40: cmp x1, x19  <- x1=大小, x19=基址?"
echo "  => 如果大小==0，会怎样？"
echo
echo "=== 3. 直接验证：设 VHA_VADDR_SIZE 环境变量 ==="
echo "  当前环境变量:"
env | grep -i "VHA\|VADDR" | sed 's/^/    /'
echo "  (空=未设置)"
echo
echo "=== 4. 关键：库的文档/手册里是否提到这些变量 ==="
grep -rn "VHA_VADDR\|VADDR_SIZE\|VADDR_BASE" /home/greatwall/下载/kylin/D3000M_NPU/ 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 5. 关键：厂商驱动是否设了这些变量 ==="
echo "  (需要看厂商驱动的源码或文档)"
echo
echo "=== 6. 下一步：设 VHA_VADDR_SIZE=0x40000000 (1GB) 试 ==="
echo "  export VHA_VADDR_SIZE=0x40000000"
echo "  export VHA_VADDR_BASE=0x48200000"
echo "  export VHA_VADDR_OFFS=0"
echo "  export VHA_VADDR_PAGESIZE=4096"
} > $O 2>&1
cat $O

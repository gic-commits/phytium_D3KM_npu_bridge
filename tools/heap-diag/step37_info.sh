#!/bin/bash
O=/home/greatwall/step37.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. struct npu_info 的定义 ==="
awk '/struct npu_info \{/,/^\};/' $T/include/phytium_npu_uapi.h | sed 's/^/  /'
echo
echo "=== 2. 关键：库读 l1_size/l3_size 的地方（反汇编） ==="
L=/usr/local/lib/libnpusession.so
echo "  找引用 npu_info 偏移的代码..."
echo "  struct npu_info 各字段偏移:"
awk '/struct npu_info \{/,/^\};/' $T/include/phytium_npu_uapi.h | grep -n "" | sed 's/^/    /'
echo
echo "=== 3. 关键：库是否用 l3_size 判断可分配量 ==="
nm -DC $L 2>/dev/null | grep -iE "GetInfo|l3_size|L3Size|GetMemInfo" | head -10 | sed 's/^/  /'
echo
echo "=== 4. 关键：库的 INFO 调用返回值 ==="
echo "  (需要 hook 或反汇编)"
echo
echo "=== 5. 关键：官方驱动的 npu_info 返回值（从厂商材料找） ==="
find /opt/npu /home/greatwall -name "*.h" 2>/dev/null | xargs grep -l "npu_info" 2>/dev/null | head -5 | sed 's/^/  /'
echo
echo "=== 6. 关键：厂商手册里的内存参数 ==="
ls /home/greatwall/下载/kylin/D3000M_NPU/ 2>/dev/null | head -10 | sed 's/^/  /'
echo
echo "=== 7. 关键：NPU 实际内存（从设备树/硬件） ==="
sudo dmesg | grep -aiE "phytium.*npu|npu.*mem|l3" | head -10 | sed 's/^/  /'
echo
echo "=== 8. 关键：厂商驱动源码里的 l1/l3 赋值 ==="
find / -name "*.c" -path "*npu*" 2>/dev/null | head -5 | sed 's/^/  /'
grep -rn "l3_size\|l1_size" /home/greatwall/npudrv/ 2>/dev/null | head -10 | sed 's/^/  /'
} > $O 2>&1
cat $O

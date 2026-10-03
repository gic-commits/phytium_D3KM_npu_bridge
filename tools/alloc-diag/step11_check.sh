#!/bin/bash
O=/home/greatwall/step11.txt
{
echo "=== 1. 模块是否真的重载了 ==="
echo "  已加载 srcversion: $(cat /sys/module/phytium_npu/srcversion 2>/dev/null)"
echo "  磁盘 srcversion:   $(modinfo /lib/modules/$(uname -r)/extra/phytium_npu.ko 2>/dev/null | awk '/srcversion/{print $2}')"
echo "  模块文件时间: $(stat -c%y /lib/modules/$(uname -r)/extra/phytium_npu.ko 2>/dev/null)"
echo
echo "=== 2. 源码里 DIAG 是否在 ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -c "VHA-ALLOC-DIAG" $T/phytium_npu_uapi.c | sed 's/^/  源码中 DIAG 次数: /'
echo
echo "=== 3. 二进制里 DIAG 是否在 ==="
strings /lib/modules/$(uname -r)/extra/phytium_npu.ko 2>/dev/null | grep -c "VHA-ALLOC-DIAG" | sed 's/^/  .ko 中 DIAG 次数: /'
echo
echo "=== 4. 完整 dmesg（最近 30 行，不过滤） ==="
sudo dmesg | tail -30 | sed 's/^/  /'
echo
echo "=== 5. 是否有 VHA-ALLOC-RAW ==="
sudo dmesg | grep -ac "VHA-ALLOC-RAW" | sed 's/^/  RAW 条数: /'
echo
echo "=== 6. 是否有 VHA-ALLOC ==="
sudo dmesg | grep -ac "VHA-ALLOC\]" | sed 's/^/  ALLOC 条数: /'
} > $O 2>&1
cat $O

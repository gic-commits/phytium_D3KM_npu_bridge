#!/bin/bash
echo "=== 1. CMA 区域碎片（debugfs 挂载后看） ==="
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
for d in /sys/kernel/debug/cma/*/; do
  [ -e "$d" ] || continue
  echo "  --- $(basename $d) ---"
  for f in count order free total; do
    [ -e "$d$f" ] && echo "    $f: $(sudo cat $d$f 2>/dev/null)"
  done
done
echo "  (空=无 debugfs 或未启用 CMA debug)"
echo
echo "=== 2. CMA 区域大小与当前占用 ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
echo
echo "=== 3. 关键验证：能否分配 29.8MB 连续 CMA ==="
echo "  当前: CmaFree=$(awk '/CmaFree/{print $2}' /proc/meminfo) kB"
echo "  需要: 31252480 B = 30520 kB"
echo "  ⇒ 空间够，但 -16 说明【碎片化】"
echo
echo "=== 4. 驱动分配历史（看不可迁移页累积） ==="
echo "  本次 ALLOC 次数: $(sudo dmesg | grep -ac 'alloc#[0-9]* size=')"
echo "  REALFREE 次数:   $(sudo dmesg | grep -ac 'VHA-REALFREE')"
echo "  [REAL] 标记数:   $(sudo dmesg | grep -ac '\[REAL\]')"
echo
echo "=== 5. 驱动用的是哪种分配（源码确认） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
grep -n "dma_alloc_coherent\|dma_alloc_attrs\|dma_alloc_pages\|DMA_ATTR" $T/phytium_npu_uapi.c | head -10 | sed 's/^/  /'
echo
echo "=== 6. CMA 分配失败的完整记录（含时间） ==="
sudo dmesg -T | grep -ai "cma" | tail -10 | sed 's/^/  /'

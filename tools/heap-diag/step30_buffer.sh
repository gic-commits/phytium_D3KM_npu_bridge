#!/bin/bash
O=/home/greatwall/step30.txt
{
echo "=== 1. dmesg 缓冲区大小 ==="
cat /proc/sys/kernel/printk | sed 's/^/  printk: /'
dmesg 2>/dev/null | wc -c | sed 's/^/  dmesg 总字节: /'
echo "  内核 log_buf_len: $(sudo cat /sys/module/printk/parameters/ 2>/dev/null; sudo dmesg | head -1)"
echo
echo "=== 2. 关键：dmesg 里 VHA-CMD 的时间戳分布 ==="
sudo dmesg | grep -a "VHA-CMD" | head -2 | sed 's/^/  最早: /'
sudo dmesg | grep -a "VHA-CMD" | tail -2 | sed 's/^/  最新: /'
echo
echo "=== 3. 关键：VHA-CRC-after 的时间戳范围 ==="
sudo dmesg | grep -a "VHA-CRC-after" | head -1 | sed 's/^/  最早: /'
sudo dmesg | grep -a "VHA-CRC-after" | tail -1 | sed 's/^/  最新: /'
echo
echo "=== 4. 关键：dmesg 最早的时间戳（看被冲掉多少） ==="
sudo dmesg | head -1 | sed 's/^/  /'
echo
echo "=== 5. 验证：清空 dmesg 后立刻跑，看 nr=2/nr=7 是否出现 ==="
sudo dmesg -C
sudo systemctl restart npusvc; sleep 8
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock timeout 300 python3 /tmp/sv_pool.py > /dev/null 2>&1
echo "  --- 清空后立即统计 nr ---"
sudo dmesg | grep -aoE "nr=0x[0-9a-f]+" | sort | uniq -c | sed 's/^/    /'
echo "  --- VHA-CMD 条数 ---"
sudo dmesg | grep -ac "VHA-CMD" | sed 's/^/    /'
echo "  --- 前 10 条 VHA-CMD ---"
sudo dmesg | grep -a "VHA-CMD" | head -10 | sed 's/.*\] //' | sed 's/^/    /'
echo
echo "=== 6. 关键：alloc size= (VHA_ALLOC_MEM 分支) 是否出现 ==="
sudo dmesg | grep -ac "alloc size=" | sed 's/^/  /'
sudo dmesg | grep -a "alloc size=" | head -5 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 7. 关键：VHA-ALLOC-ERR (pr_err) 是否出现 ==="
sudo dmesg | grep -ac "VHA-ALLOC-ERR" | sed 's/^/  /'
sudo dmesg | grep -a "VHA-ALLOC-ERR" | head -5 | sed 's/.*\] //' | sed 's/^/  /'
} > $O 2>&1
cat $O

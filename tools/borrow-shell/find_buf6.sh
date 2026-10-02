#!/bin/bash
echo "=== 1. 找 448000 在分配序列里的位置（它是 x 输入） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=448000" | head -5 | sed 's/^/  /'
echo
echo "=== 2. 448000 前后各 6 块（看它在第几个） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | grep -n "" | grep -A6 -B6 "448000" | head -20 | sed 's/^/  /'
echo
echo "=== 3. 只出现 1 次的尺寸（候选"特殊缓冲"） ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | awk -F'size=' '{print $2}' | sort -n | uniq -c | awk '$1<=3 {print "  size="$2" 出现 "$1" 次"}'
echo
echo "=== 4. 报错说 Buffer ID: 6 —— 看第 6 块是什么 ==="
sudo dmesg | grep -ao "alloc#[0-9]* size=[0-9]*" | head -8 | sed 's/^/  /'
echo
echo "=== 5. sensevoice 的 IO 声明（x 是唯一输入） ==="
echo "  x[1,200,560] f32 = 448000  ← 与分配序列里的 448000 吻合！"
echo "  ⇒ 报错的 Buffer ID: 6 很可能就是 x 这块"

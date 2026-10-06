#!/bin/bash
# 统计一次 sensevoice 运行的 VHA 内存申请总量（判断是否池子耗尽）
O=/home/greatwall/memsum.txt
{
echo "########## MEMSUM $(date +%H:%M:%S) ##########"
P=/sys/module/phytium_npu/parameters
echo 1 | sudo tee $P/vha_heap_type >/dev/null
echo 1 | sudo tee $P/vha_heap_flags >/dev/null
sudo systemctl restart npusvc; sleep 6
sudo dmesg -C
cd /opt/npu/python
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 130 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "infer" | head -2
cd /
echo "=== 对照：mobilenet ==="
sudo dmesg -C
cd /opt/npu/python
MB_MODEL=mobilenet MB_SHAPE=1,3,224,224 MB_N=1 NPU_SOCK=/run/npu/npu.sock timeout 90 python3 -u /tmp/loop_client.py 2>&1 | grep -aE "推理|失败" | head -2
cd /
sudo dmesg | grep -aoE "VHA-ALLOC\] page=[0-9]+ iova=[^ ]+ size=[0-9]+" > /tmp/sv_allocs.txt
python3 - <<'PY'
import re
tot=0; n=0; mx=0
for line in open('/tmp/sv_allocs.txt', errors='surrogateescape'):
    m = re.search(r'size=(\d+)', line)
    if m:
        v=int(m.group(1)); tot+=v; n+=1; mx=max(mx,v)
print("  [mobilenet] 申请次数=%d 合计=%.1f MB 最大单次=%.1f MB" % (n, tot/1048576, mx/1048576))
PY
echo "=== 再看 sensevoice 的申请总量 ==="
sudo dmesg -T | grep -a "VHA-ALLOC] page=" | wc -l
python3 - <<'PY'
import subprocess, re
out = subprocess.run(['sudo','dmesg'], capture_output=True, text=True, errors='surrogateescape').stdout
# 无区分：这里打印最近一批申请的合计
tot=0;n=0;mx=0
for line in out.splitlines():
    if 'VHA-ALLOC] page=' in line:
        m=re.search(r'size=(\d+)', line)
        if m:
            v=int(m.group(1)); tot+=v; n+=1; mx=max(mx,v)
print("  申请次数=%d 合计=%.1f MB 最大单次=%.1f MB" % (n, tot/1048576, mx/1048576))
PY
echo "=== CMA ==="
grep -E "Cma(Total|Free)" /proc/meminfo
} > $O 2>&1
cat $O

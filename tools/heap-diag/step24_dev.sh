#!/bin/bash
O=/home/greatwall/step24.txt
{
echo "=== 1. 三个设备节点的详细信息 ==="
for d in /dev/npu0 /dev/phy_npu0 /dev/phy_npu; do
  echo "  --- $d ---"
  ls -l $d 2>/dev/null | sed 's/^/    /'
  sudo fuser -v $d 2>&1 | head -3 | sed 's/^/    /'
done
echo
echo "=== 2. 关键：谁在用 /dev/phy_npu0 ==="
sudo fuser -v /dev/phy_npu0 2>&1 | head -5 | sed 's/^/  /'
echo
echo "=== 3. 关键：厂商驱动是否加载 ==="
lsmod | grep -iE "npu|phytium" | sed 's/^/  /'
echo
echo "=== 4. 关键：/dev/phy_npu0 属于哪个驱动 ==="
sudo cat /sys/class/misc/*/dev 2>/dev/null | head -5
for m in /sys/class/misc/*/; do
  n=$(basename $m)
  case "$n" in *npu*|*phy*) echo "  $n: $(cat $m/dev 2>/dev/null)";; esac
done
echo
echo "=== 5. 关键：库加载时打开的设备 ==="
sudo systemctl restart npusvc; sleep 6
P=$(pgrep -f npusvc_pool | head -1)
echo "  pool pid: ${P:-无}"
if [ -n "$P" ]; then
  sudo timeout 30 strace -f -p $P -e trace=openat -s 60 -o /tmp/pool.log 2>/dev/null &
  sleep 3
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 60 python3 /tmp/sv_pool.py > /dev/null 2>&1
  sleep 3
  echo "  --- pool 打开的 npu 设备 ---"
  sudo grep -ao '"/dev/[^"]*npu[^"]*"' /tmp/pool.log 2>/dev/null | sort | uniq -c | sed 's/^/    /'
  echo "  --- pool 的 ioctl 目标 fd ---"
  sudo grep -a "ioctl" /tmp/pool.log 2>/dev/null | head -5 | sed 's/^/    /'
fi
echo
echo "=== 6. 关键：驱动侧收到的 ioctl（我们的驱动） ==="
sudo dmesg | grep -aoE "nr=0x[0-9a-f]+" | sort | uniq -c | sed 's/^/  /'
} > $O 2>&1
cat $O

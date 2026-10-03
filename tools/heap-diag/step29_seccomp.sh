#!/bin/bash
O=/home/greatwall/step29.txt
{
echo "=== 1. 关键：worker 进程的父子关系 ==="
W=$(pgrep -f npuworker | head -1)
echo "  worker pid: ${W:-无}"
[ -n "$W" ] && ps -o pid,ppid,cmd -p $W 2>/dev/null | sed 's/^/  /'
echo
echo "=== 2. 关键：worker 是否被 ptrace/seccomp ==="
[ -n "$W" ] && sudo cat /proc/$W/status 2>/dev/null | grep -iE "seccomp|TracerPid|CapEff" | sed 's/^/  /'
echo
echo "=== 3. 关键：驱动 ioctl 的完整入口（看是否所有 cmd 都记录） ==="
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
awk 'NR>=1234 && NR<=1260 {printf "%d: %s\n", NR, $0}' $T/phytium_npu_uapi.c | sed 's/^/  /'
echo
echo "=== 4. 关键：VHA-CMD 的完整记录（含 hexdump 首行） ==="
sudo dmesg | grep -a "VHA-CMD" | head -6 | sed 's/.*\] //' | sed 's/^/  /'
echo
echo "=== 5. 关键：本次加载的完整 ioctl 序列（strace 前 30 行 ioctl） ==="
sudo grep -a "ioctl(8" /tmp/w2.log 2>/dev/null | head -30 | sed 's/^/  /'
echo
echo "=== 6. 关键：驱动 dmesg 里本次加载的所有 VHA 日志 ==="
sudo dmesg | grep -a "VHA" | grep -av "CRC" | tail -20 | sed 's/.*\] //' | sed 's/^/  /'
} > $O 2>&1
cat $O

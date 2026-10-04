#!/bin/bash
O=/home/greatwall/step50.txt
{
echo "=== 1. 当前环境变量（VHA_VADDR_*） ==="
env | grep -i "VHA\|VADDR" | sed 's/^/  /'
echo "  (空=未设置)"
echo
echo "=== 2. npusvc_pool 的环境变量 ==="
P=$(pgrep -f npusvc_pool | head -1)
echo "  pool pid: ${P:-无}"
[ -n "$P" ] && sudo cat /proc/$P/environ 2>/dev/null | tr '\0' '\n' | grep -i "VHA\|VADDR" | sed 's/^/    /'
echo
echo "=== 3. npuworker 的环境变量 ==="
W=$(pgrep -f npuworker | head -1)
echo "  worker pid: ${W:-无}"
[ -n "$W" ] && sudo cat /proc/$W/environ 2>/dev/null | tr '\0' '\n' | grep -i "VHA\|VADDR" | sed 's/^/    /'
echo
echo "=== 4. 系统级环境变量 ==="
grep -r "VHA_VADDR" /etc/environment /etc/profile /etc/profile.d/ /etc/bash.bashrc ~/.bashrc ~/.profile 2>/dev/null | sed 's/^/  /'
echo
echo "=== 5. 关键：VhaVaaHeapCreate 的默认值（反汇编） ==="
L=/usr/local/lib/libnpusession.so
echo "  看 getenv 返回 NULL 时的默认值..."
objdump -d --start-address=0x76a80 --stop-address=0x76ad0 $L 2>/dev/null | sed 's/^/    /'
echo
echo "=== 6. 关键：VHA_VADDR_SIZE 的默认值 ==="
echo "  76aa4: getenv('VHA_VADDR_SIZE')"
echo "  76ab0: cbz x0, 76cb8  <- 若 NULL 跳走"
echo "  76ab4: strtoul(x0, 0, 16)  <- 十六进制解析"
echo "  76ac4: str w0, [x19, #40]  <- 存入 session+40"
echo "  76cb8: (默认值路径)"
objdump -d --start-address=0x76cb8 --stop-address=0x76cd4 $L 2>/dev/null | sed 's/^/    /'
} > $O 2>&1
cat $O

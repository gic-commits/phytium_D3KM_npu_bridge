#!/bin/bash
# 清理 Hermes 在麒麟上产生的临时数据（重启前）—— 输出写到家目录，避免被自己删
O=/home/greatwall/cleanup_report.txt
{
echo "=== 0. 清理前磁盘 ==="
df -h / /tmp /opt 2>/dev/null
echo
echo "=== 1. /tmp 下我产生的临时目录 ==="
du -sh /tmp/mbsprobe /tmp/mbsrebuild /tmp/scan2 /tmp/scan3 /tmp/sv0x 2>/dev/null
echo
echo "=== 2. 删除（只删我建的） ==="
sudo rm -rf /tmp/mbsprobe /tmp/mbsrebuild /tmp/scan2 /tmp/scan3 /tmp/sv0x 2>/dev/null
sudo rm -f /tmp/*.out /tmp/*.py /tmp/*.sh /tmp/t_npu_mbs.* /tmp/nonmbs_* /tmp/chk.bin 2>/dev/null
sudo rm -f /tmp/w.log /tmp/wr.log /tmp/t.log /tmp/tar2.log /tmp/full.asm /tmp/npus.asm /tmp/strace.log 2>/dev/null
sudo rm -f /tmp/b.txt /tmp/a.txt /tmp/sv*.log /tmp/q.log /tmp/*.dat_1.1.0 2>/dev/null
echo "  已删除"
echo
echo "=== 3. 清理后磁盘 ==="
df -h / /tmp /opt 2>/dev/null
echo
echo "=== 4. 关键保留项 ==="
echo "  sensevoice.tar: $(stat -c%s /opt/npu/model/sensevoice.tar 2>/dev/null) B"
echo "  原始备份: $(ls /opt/npu/model/sensevoice.tar.bak_* 2>/dev/null | wc -l) 个"
echo "  驱动源码: $(ls /home/greatwall/npudrv/tree/drivers/staging/phytium-npu/*.c 2>/dev/null | wc -l) 个 .c"
echo "  源码备份 .bak*: $(ls /home/greatwall/npudrv/tree/drivers/staging/phytium-npu/*.bak* 2>/dev/null | wc -l) 个"
echo "  npu_harness: $(ls /home/greatwall/npu_harness/ 2>/dev/null | wc -l) 个文件"
echo
echo "=== 5. 当前驱动状态 ==="
lsmod | grep phytium_npu | awk '{print "  "$1" refcnt="$3}'
echo "  srcversion: $(cat /sys/module/phytium_npu/srcversion 2>/dev/null)"
echo "  npusvc: $(systemctl is-active npusvc)"
echo
echo "=== 6. CMA 状态 ==="
awk '/CmaTotal|CmaFree/{print "  "$0}' /proc/meminfo
} > $O 2>&1
cat $O

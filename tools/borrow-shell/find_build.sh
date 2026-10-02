#!/bin/bash
echo "=== 1. 全盘找 model_build 类可执行（含隐藏目录） ==="
sudo find / -name "model_build*" -o -name "npu_compiler*" -o -name "*model_build*" 2>/dev/null | grep -v "^/proc" | head -10
echo
echo "=== 2. 找任何链接 libnpucompiler 的可执行 ==="
sudo grep -rl "libnpucompiler" /usr/bin /usr/local/bin /opt/npu/bin /home/greatwall 2>/dev/null | head -10
echo
echo "=== 3. /opt/npu/bin 全部内容 ==="
ls -la /opt/npu/bin/ 2>/dev/null
echo
echo "=== 4. libnpucompiler 的 C++ 符号（找编译入口函数） ==="
nm -D --defined-only /usr/local/lib/libnpucompiler.so 2>/dev/null | grep -iE " T | W " | grep -iE "compile|build|generate|create|network|mbs" | head -20
echo
echo "=== 5. 该库依赖哪些库 ==="
ldd /usr/local/lib/libnpucompiler.so 2>/dev/null | head -15
echo
echo "=== 6. 厂商 demo 包（NAS 有 npu_ftn300_demo.zip）里是否含 model_build ==="
ls -la /tmp/npu_ftn300_demo.zip 2>/dev/null || echo "  (不在设备上)"

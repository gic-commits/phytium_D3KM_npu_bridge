#!/bin/bash
echo "=== 1. 设备上已有的编译器相关文件 ==="
ls -la /usr/local/lib/ | grep -iE "npu|phy|compil" | head -15
echo
echo "=== 2. 找 model_build / npu_compiler 可执行 ==="
for n in model_build npu_compiler phynpu-opt; do
  echo "  --- $n ---"
  which $n 2>/dev/null || find / -maxdepth 5 -name "$n" -type f -not -path "/proc/*" 2>/dev/null | head -3
done
echo
echo "=== 3. libnpucompiler.so 的导出符号（看能否直接调用） ==="
nm -D --defined-only /usr/local/lib/libnpucompiler.so 2>/dev/null | head -25
echo "  --- 符号总数: $(nm -D --defined-only /usr/local/lib/libnpucompiler.so 2>/dev/null | wc -l) ---"
echo
echo "=== 4. 这个 so 是不是 x86 的（工具链是 x86 交叉编译） ==="
file /usr/local/lib/libnpucompiler.so
echo
echo "=== 5. 设备上其它 phy/npu 库 ==="
ls -la /usr/local/lib/libphy* /usr/local/lib/libnpu* 2>/dev/null
echo
echo "=== 6. 有没有工具链目录残留 ==="
ls -d /home/lib64 /opt/npu_ftn300* /home/npu_ftn300* 2>/dev/null
ls -la /home/lib64/ 2>/dev/null | head -8

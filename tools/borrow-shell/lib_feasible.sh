#!/bin/bash
L=/usr/local/lib/libnpucompiler.so
echo "=== 1. 头文件是否随库安装 ==="
find / -maxdepth 6 \( -name "CnnModel*.h*" -o -name "CnnGraph*.h*" -o -name "npucompiler*.h*" -o -name "phydnn*.h*" \) -not -path "/proc/*" 2>/dev/null | head -15
echo
echo "=== 2. 库里"一步到位"的高层入口候选 ==="
nm -DC --defined-only $L 2>/dev/null | grep -iE " T " | grep -iE "::(run|compile|build|generate|process|execute|do_|main_|start)" | head -25
echo
echo "=== 3. 有没有类似 main 的顶层函数 ==="
nm -DC --defined-only $L 2>/dev/null | grep -E " T [a-z_]+$" | grep -viE "json|std|__" | head -40
echo
echo "=== 4. 库的构建信息（编译器/版本，能看出与厂商 CLI 的关系） ==="
strings -a $L | grep -iE "GCC:|clang version|model_build|npu_compiler|PHY-|NNA_|DDK" | head -15
echo
echo "=== 5. 是否有配套的 .so 提供 CLI 逻辑 ==="
ls -la /usr/local/lib/ | grep -iE "npu|phy" | head
echo
echo "=== 6. libnpucompiler 是否被任何已装程序使用 ==="
sudo grep -rl "libnpucompiler" /opt /usr/local/bin /usr/bin 2>/dev/null | head -5
echo "  (无输出=没有现成前端)"

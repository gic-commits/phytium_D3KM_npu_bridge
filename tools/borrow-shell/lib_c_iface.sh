#!/bin/bash
L=/usr/local/lib/libnpucompiler.so
echo "=== 1. 找 C 风格入口（无 C++ mangling 的导出函数） ==="
nm -D --defined-only $L 2>/dev/null | awk '$2=="T" && $3 !~ /^_Z/' | head -40
echo "  --- 计数: $(nm -D --defined-only $L 2>/dev/null | awk '$2=="T" && $3 !~ /^_Z/' | wc -l) ---"
echo
echo "=== 2. 找 phydnn / npu_ 前缀的 C 接口 ==="
nm -D --defined-only $L 2>/dev/null | grep -E " T (phydnn|npu_|phy_|phyai)" | head -30
echo
echo "=== 3. 顶层工作流类（CnnModel / CnnGraph 的公开方法） ==="
nm -DC --defined-only $L 2>/dev/null | grep -E "CnnModel::|CnnGraph::|CnnHierGraph::" | grep -vE "~|operator" | head -30
echo
echo "=== 4. 有没有 write/save/export 产物的方法 ==="
nm -DC --defined-only $L 2>/dev/null | grep -iE "::(write|save|export|dump|emit|serialize)" | head -20
echo
echo "=== 5. 库里的 .so/.tar/.params 输出相关字符串 ==="
strings -a $L | grep -iE "\.tar|\.params|\.so$|mbs|blob|write.*file|fopen" | head -25

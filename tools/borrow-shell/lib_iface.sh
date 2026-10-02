#!/bin/bash
L=/usr/local/lib/libnpucompiler.so
echo "=== 1. 找 C++ 导出符号（编译入口候选） ==="
nm -DC --defined-only $L 2>/dev/null | grep -iE "compile|build|generate|create|network|mbs|model" | head -30
echo
echo "=== 2. 所有 T（text 段，真函数）符号里与编译相关的 ==="
nm -DC --defined-only $L 2>/dev/null | awk '$2=="T"' | grep -iE "compil|build|generat|creat|net|mbs|onnx|tvm|nnvm" | head -40
echo
echo "=== 3. 库里的错误/日志字符串（能看出工作流） ==="
strings -a $L | grep -iE "usage|option|\.onnx|io\.json|test\.json|model_build|npu_compiler|argv|parameter" | head -30
echo
echo "=== 4. 是否含 main 或 CLI 痕迹 ==="
nm -DC $L 2>/dev/null | grep -iE " main$| T main|getopt|argparse" | head
strings -a $L | grep -iE "^-|--[a-z]" | head -20

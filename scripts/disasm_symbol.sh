#!/bin/bash
# 定点反汇编 + 函数归属定位（闭源库取证第二把刀）
#
# 为什么不用 `grep -B 300`：B 给少了截掉函数标签，给多了串到上一个函数；下面的 awk 惯用法
# 一次扫描就把「调用点/常量 → 归属函数」对上，且不会因架构助记符（aarch64 用 bl 不用 call）漏命中。
#
# 用法：
#   ./disasm_symbol.sh LIB.so dump   <outdir>              # 全库反汇编落盘（大库请后台跑！）
#   ./disasm_symbol.sh LIB.so sym    WaitForCompletion [n] # 按符号名（模糊）定点反汇编，n=命中个数
#   ./disasm_symbol.sh LIB.so addr   0x78bb8 0xb14         # 按 vaddr+size 定点反汇编
#   ./disasm_symbol.sh LIB.so who    '#0x7109'  dump.txt   # 谁引用/调用这个常量或符号
#   ./disasm_symbol.sh LIB.so in     dump.txt  '#0x7109'   # 同上（参数顺序不同名）
#   ./disasm_symbol.sh LIB.so syms   'DnnSubmit|MBSParserParse|WaitForCompletion'   # 列符号+地址+大小
#
# 铁律（本技能文档 §四）：① 产物一律重定向进文件，屏幕只看摘要
# ② 批量 dump 后必须 wc -l，**0 行 = 探针写错**（BSD sed 不支持 `\|`，用它过滤会静默产出空文件）

set -u
LL=${LL:-/Library/Developer/CommandLineTools/usr/bin}   # macOS 用 Xcode CLT 的 llvm 工具链
OBJDUMP=$(command -v llvm-objdump || echo "$LL/llvm-objdump")
NM=$(command -v llvm-nm || echo "$LL/llvm-nm")
[ -x "$OBJDUMP" ] || { echo "找不到 llvm-objdump；macOS 装 Xcode CLT，或 export LL=<dir>"; exit 1; }

LIB=${1:?用法见脚本头注释}; CMD=${2:?}; shift 2

case "$CMD" in
  dump)
    OUT=${1:-.}; mkdir -p "$OUT"
    "$OBJDUMP" -d --demangle --no-show-raw-insn "$LIB" > "$OUT/dis.txt" 2>&1
    n=$(wc -l < "$OUT/dis.txt"); echo "$OUT/dis.txt 行数=$n"
    [ "$n" -gt 100 ] || { echo "⚠️ 行数异常偏少，探针可能写错了"; exit 1; }
    ;;

  syms)
    pat=${1:?给一个符号正则}; "$NM" -S -C --defined-only "$LIB" | grep -E "$pat" | sort
    ;;

  sym)
    pat=${1:?给一个符号名（可模糊）}; want=${2:-1}; hit=0
    while read -r addr size _ _ rest; do
      [ -n "${addr:-}" ] || continue
      a=$((16#$addr)); s=$((16#$size))
      echo "===== $rest  @$addr size=$size ====="
      "$OBJDUMP" -d --demangle --no-show-raw-insn \
          --start-address=$a --stop-address=$((a+s)) "$LIB" 2>/dev/null | tail -n +6
      hit=$((hit+1)); [ "$hit" -ge "$want" ] && break
    done < <("$NM" -S -C --defined-only "$LIB" | grep -E "$pat")
    [ "$hit" -gt 0 ] || { echo "没找到符号：$pat"; exit 1; }
    ;;

  addr)
    a=$((16#${1:?需要 vaddr})); s=$((16#${2:-400}))
    "$OBJDUMP" -d --demangle --no-show-raw-insn \
        --start-address=$a --stop-address=$((a+s)) "$LIB" 2>/dev/null | tail -n +6
    ;;

  who|in)
    file=${1:?给已 dump 的反汇编 txt}; pat=${2:?给常量或符号，如 '#0x7109' 或 'bl <ioctl@plt>'}
    # ★ 一次扫描把每个命中归到最近的函数标签（比 grep -B N 稳，且对 aarch64/z86 都有效）
    awk -v pat="$pat" '
      /^[0-9a-f]+ </ { fn=$0 }
      index($0, pat) { print NR": " fn " | " $0 }
    ' "$file" | head -40
    ;;

  *) sed -n '2,30p' "$0"; exit 1 ;;
esac

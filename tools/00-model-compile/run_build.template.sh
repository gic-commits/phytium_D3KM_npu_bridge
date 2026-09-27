#!/bin/bash
# run_build.template.sh — 在厂商工具链**容器内**编译一个 ONNX 模型为可部署包
#
# 用法（把本文件与 io.json / test.json / 模型放进挂载到 /out 的共享目录后，在容器里执行）：
#   bash run_build.template.sh <输出名> <模型文件名> <io.json> <test.json> <校准数据张数>
# 例：
#   bash run_build.template.sh mobilenet mobilenetv2-12-static.onnx io.json test.json 2
#
# 详见 docs/09-model-compile-pipeline.md（含两份配置文件的 schema 与全部踩坑）
set -u

NAME="${1:?输出名}"
MODEL="${2:?模型文件名}"
IOJSON="${3:?io.json}"
TESTJSON="${4:?test.json}"
MAXIN="${5:-1}"

TOOLS="${TOOLS_DIR:-/home/npu_ftn300_tools}"     # 工具目录（容器内）
WORK="${WORK_DIR:-/out}"                          # 共享工作目录（挂载点）
OUT="$WORK/build_$NAME"
LOG="$WORK/build_$NAME.log"
mkdir -p "$OUT"

export LD_LIBRARY_PATH="$TOOLS:/usr/local/lib:${LD_LIBRARY_PATH:-}"

# ★★ 必需修复：工具把 NPU_MAPPER_INSTALL_PATH 拼成 <cv2>/../../lib64:...，
#    该目录在容器里不存在 ⇒ mapper 阶段必失败（报错还被 NameError 掩盖）
mkdir -p /home/lib64
cp -f "$TOOLS/libphydnn.so" "$TOOLS/npu_compiler" "$TOOLS/libnpucompiler.so" /home/lib64/ 2>/dev/null || true

echo "== 模型: $WORK/$MODEL ($(stat -c%s "$WORK/$MODEL" 2>/dev/null) 字节)"
echo "== io.json ==";   cat "$WORK/$IOJSON"   2>/dev/null | head -30
echo "== test.json =="; cat "$WORK/$TESTJSON" 2>/dev/null | head -30

cd "$WORK" || exit 1
timeout "${TIMEOUT_S:-7200}" "$TOOLS/model_build" \
    -ll INFO -d npu -mf onnx \
    -i "$WORK/$MODEL" \
    -o "$OUT/$NAME" \
    -nf "$WORK/$IOJSON" \
    -tf "$WORK/$TESTJSON" \
    -mi "$MAXIN" \
    -mc "$TOOLS/in32out32_d16_w16b16.json" \
    -es -b1 -sn \
    -so "$OUT/$NAME.so" -tm "$OUT/$NAME.tar" -op "$OUT/$NAME.params" \
    > "$LOG" 2>&1
RC=$?

echo "== RC=$RC =="
grep -aE "CRITICAL|ERROR|COMPLETED|does not exist|Assertion" "$LOG" | tail -12
echo "== 产物（4 件套）=="; ls -la "$OUT" | grep -E "\.(json|params|so|tar)$"
echo "== 部署提示：把这 4 个文件拷到推理服务实际使用的模型目录，并 chmod a+rX；"
echo "   拷错目录的症状是 init_graph=-1（包没问题，是服务在别处找模型）=="
exit $RC

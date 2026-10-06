#!/bin/bash
# 最大化 NPU 占比：逐类加回算子，每轮记录 认领数 / 建网 / 执行
cat > /tmp/_bk_run.py <<'PYEOF'
import onnx, onnxruntime as ort, numpy as np, glob, time, sys
KEEP = set(sys.argv[1].split(","))
m = onnx.load("/home/greatwall/model_final2.onnx")
sel = [n.name for n in m.graph.node if n.op_type not in KEEP]
open("/home/greatwall/asr/npu_unsupported_nodes.txt","w").write("\n".join(sel)+"\n")
print("KEEP=%s  CPU节点=%d  NPU候选=%d" % (sys.argv[1], len(sel), len(m.graph.node)-len(sel)))
ort.set_default_logger_severity(2)
feat=None
for c in glob.glob("/home/greatwall/**/*.f32", recursive=True):
    a=np.fromfile(c,dtype=np.float32)
    if a.size==200*560: feat=a.reshape(1,200,560); break
if feat is None: feat=np.random.rand(1,200,560).astype(np.float32)
so=ort.SessionOptions(); so.log_severity_level=2
so.unspported_nodes_file="/home/greatwall/asr/npu_unsupported_nodes.txt"
try:
    s=ort.InferenceSession("/home/greatwall/model_final2.onnx", so,
                           providers=["PHYNPUExecutionProvider","CPUExecutionProvider"])
    nm=s.get_inputs()[0].name
    t=time.time(); y=s.run(None,{nm:feat})
    print("RESULT: OK %.2fs out=%s" % (time.time()-t, y[0].shape))
except Exception as e:
    print("RESULT: EXC %s %s" % (type(e).__name__, str(e)[:150]))
PYEOF

for CFG in \
  "Conv,Relu" \
  "Conv,Relu,Add" \
  "Conv,Relu,Add,Mul" \
  "Conv,Relu,Add,Mul,Sub,Div,Sqrt,Pow" \
  "Conv,Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean" \
  "Conv,Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean,Reshape,Transpose,Identity" \
  "Conv,Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean,Reshape,Transpose,Identity,MatMul" \
; do
  OUT=$(cd /home/greatwall/asr; timeout 900 python3 -u /tmp/_bk_run.py "$CFG" 2>&1)
  SUP=$(echo "$OUT" | grep -a "number of nodes supported" | tail -1 | sed 's/.*supported by PHYNPU: //')
  RES=$(echo "$OUT" | grep -a "^RESULT:" | tail -1)
  BRD=$(echo "$OUT" | grep -ac "broadcasted")
  GEN=$(echo "$OUT" | grep -ac "Model generation failed")
  printf "[%-72s] 认领=%-6s 广播错=%-3s 建网错=%-3s %s\n" "$CFG" "${SUP:-?}" "$BRD" "$GEN" "$RES"
done

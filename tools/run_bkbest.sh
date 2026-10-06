#!/bin/bash
# ★ 目标配置：MatMul 与 Conv 交 CPU，其余全给 NPU；验证执行 + 数值一致性
cat > /tmp/_bk_best.py <<'PYEOF'
import onnx, onnxruntime as ort, numpy as np, glob, time, sys
KEEP = set(sys.argv[1].split(","))
m = onnx.load("/home/greatwall/model_final2.onnx")
sel = [n.name for n in m.graph.node if n.op_type not in KEEP]
open("/home/greatwall/asr/npu_unsupported_nodes.txt","w").write("\n".join(sel)+"\n")
print("KEEP=%s" % sys.argv[1])
print("CPU节点=%d  NPU候选=%d" % (len(sel), len(m.graph.node)-len(sel)))
ort.set_default_logger_severity(2)
feat=None
for c in glob.glob("/home/greatwall/**/*.f32", recursive=True):
    a=np.fromfile(c,dtype=np.float32)
    if a.size==200*560: feat=a.reshape(1,200,560); break
if feat is None:
    feat=np.random.rand(1,200,560).astype(np.float32); print("!! 随机特征")
so=ort.SessionOptions(); so.log_severity_level=2
so.unspported_nodes_file="/home/greatwall/asr/npu_unsupported_nodes.txt"
t0=time.time()
try:
    s=ort.InferenceSession("/home/greatwall/model_final2.onnx", so,
                           providers=["PHYNPUExecutionProvider","CPUExecutionProvider"])
    print("会话建立 %.1fs" % (time.time()-t0))
    nm=s.get_inputs()[0].name
    t=time.time(); y=s.run(None,{nm:feat})
    dt=time.time()-t
    a=y[0]
    print("★★★ 执行成功 %.2fs  输出 %s %s  非零=%d  max=%.4f"
          % (dt, a.shape, a.dtype, int((a!=0).sum()), float(np.abs(a).max())))
    np.save("/home/greatwall/asr/sv_out_best.npy", a)
except Exception as e:
    print("!! 异常: %s %s" % (type(e).__name__, str(e)[:200]))
PYEOF

echo "############ 配置A：MatMul+Conv 交 CPU（其余给 NPU）############"
cd /home/greatwall/asr
timeout 900 python3 -u /tmp/_bk_best.py "Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean,Reshape,Transpose,Identity" > /home/greatwall/asr/bestA.log 2>&1
grep -aE "KEEP=|CPU节点|会话建立|执行成功|异常|number of nodes supported|cannot be broadcasted|Model generation failed" /home/greatwall/asr/bestA.log | tail -8
echo
echo "############ 配置B：同 A，但把 Conv 留给 NPU（看 11x1 是否仍崩）############"
timeout 900 python3 -u /tmp/_bk_best.py "Conv,Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean,Reshape,Transpose,Identity" > /home/greatwall/asr/bestB.log 2>&1
grep -aE "KEEP=|CPU节点|会话建立|执行成功|异常|number of nodes supported|cannot be broadcasted|Model generation failed" /home/greatwall/asr/bestB.log | tail -8

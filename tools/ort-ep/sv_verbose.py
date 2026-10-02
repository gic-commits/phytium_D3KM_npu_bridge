import os, sys, numpy as np
import onnxruntime as ort

os.chdir("/home/greatwall/asr")
UF = "/home/greatwall/asr/npu_unsupported_nodes.txt"
M = "/home/greatwall/model_final2.onnx"

print("=== 现有 unsupported 清单 ===")
if os.path.exists(UF):
    names = [l.strip() for l in open(UF, errors="replace") if l.strip()]
    print("  文件:", UF, "行数:", len(names))
    print("  前 20 个:", names[:20])
else:
    print("  不存在", UF)

print("=== 模型 IO 形状（纯 CPU 读元信息，不建 NPU session） ===")
try:
    s0 = ort.InferenceSession(M, providers=["CPUExecutionProvider"])
    for i in s0.get_inputs():
        print("  IN :", i.name, i.shape, i.type)
    for o in s0.get_outputs():
        print("  OUT:", o.name, o.shape, o.type)
    del s0
except Exception as e:
    print("  读元信息失败:", repr(e)[:200])

print("=== 开 VERBOSE 建 NPU session ===")
ort.set_default_logger_severity(0)
try:
    os.remove("graph_node.txt")
except OSError:
    pass
so = ort.SessionOptions()
so.log_severity_level = 0
so.unspported_nodes_file = UF
try:
    s = ort.InferenceSession(M, so, providers=["PHYNPUExecutionProvider", "CPUExecutionProvider"])
    print("session OK, providers:", s.get_providers())
    for i in s.get_inputs():
        print("  SIN :", i.name, i.shape, i.type)
    for o in s.get_outputs():
        print("  SOUT:", o.name, o.shape, o.type)
    feat = np.random.rand(1, 200, 560).astype(np.float32)
    try:
        y = s.run(None, {s.get_inputs()[0].name: feat})
        print("RUN OK:", [np.asarray(a).shape for a in y])
    except Exception as e:
        print("RUN 异常:", type(e).__name__, str(e)[:300])
except Exception as e:
    print("建 session 异常:", type(e).__name__, str(e)[:300])

print("=== graph_node.txt ===")
if os.path.exists("graph_node.txt"):
    g = [l.strip() for l in open("graph_node.txt", errors="replace") if l.strip()]
    print("  行数:", len(g), " 大小:", os.path.getsize("graph_node.txt"))
    print("  前 30:", g[:30])
else:
    print("  缺失")

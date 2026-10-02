import onnxruntime as ort, numpy as np
M = "/home/greatwall/npu_harness/tiny_cnn.onnx"
np.random.seed(7)
x = np.random.rand(1,3,64,64).astype(np.float32)
cpu = ort.InferenceSession(M, providers=["CPUExecutionProvider"])
y_cpu = cpu.run(None, {"x": x})[0]
print("CPU 金标: shape", y_cpu.shape, "前3值", np.round(y_cpu.flatten()[:3], 5))
so = ort.SessionOptions(); so.log_severity_level = 3
npu = ort.InferenceSession(M, so, providers=["PHYNPUExecutionProvider","CPUExecutionProvider"])
print("providers:", npu.get_providers())
for i in range(3):
    try:
        import time; t=time.time()
        y = npu.run(None, {"x": x})[0]
        dt = (time.time()-t)*1000
        a = y.flatten(); b = y_cpu.flatten()
        cos = float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))
        print(f"NPU run{i}: {dt:.0f} ms  max|Δ|={np.abs(a-b).max():.6f}  cosine={cos:.6f}  前3值={np.round(a[:3],5)}")
    except Exception as e:
        print(f"NPU run{i}: 异常 {str(e)[:150]}")

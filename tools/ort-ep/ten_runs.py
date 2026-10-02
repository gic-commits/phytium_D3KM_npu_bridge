import onnxruntime as ort, numpy as np, time
M="/home/greatwall/npu_harness/tiny_cnn.onnx"
np.random.seed(7); x=np.random.rand(1,3,64,64).astype(np.float32)
y_cpu=ort.InferenceSession(M,providers=["CPUExecutionProvider"]).run(None,{"x":x})[0]
so=ort.SessionOptions(); so.log_severity_level=3
s=ort.InferenceSession(M,so,providers=["PHYNPUExecutionProvider","CPUExecutionProvider"])
ok=0
for i in range(10):
    t=time.time()
    try:
        y=s.run(None,{"x":x})[0]; dt=(time.time()-t)*1000
        a,b=y.flatten(),y_cpu.flatten()
        cos=float(np.dot(a,b)/(np.linalg.norm(a)*np.linalg.norm(b)+1e-12))
        good = dt<100 and cos>=0.99
        ok += 1 if good else 0
        print(f"run{i}: {dt:.0f}ms cosine={cos:.6f} {'OK' if good else 'FAIL'}")
    except Exception as e:
        print(f"run{i}: 异常 {str(e)[:90]}")
print(f"===== 判据: {ok}/10 通过 =====")

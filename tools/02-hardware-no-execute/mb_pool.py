import sys, os, time, numpy as np
sys.path.insert(0, "/opt/npu/python")
import npu_client as npu

MODEL = os.environ.get("MB_MODEL", "mobilenet")
SHAPE = tuple(int(v) for v in os.environ.get("MB_SHAPE", "1,3,224,224").split(","))

print("=== 1. 连接池服务 ===")
c = npu.connect()
print("  connected, status:", c.status())

print("=== 2. 加载 %s ===" % MODEL)
t0 = time.time()
try:
    r = c.load(MODEL)
    print("  load -> %r  (%.1f s)" % (r, time.time() - t0))
except Exception as e:
    print("  load 异常:", type(e).__name__, str(e)[:400])

print("=== 3. 推理 %s shape=%s ===" % (MODEL, SHAPE))
try:
    x = np.random.rand(*SHAPE).astype(np.float32)
    t0 = time.time()
    outs = c.infer(MODEL, x)
    dt = time.time() - t0
    o = outs[0] if isinstance(outs, (list, tuple)) else outs
    a = np.asarray(o, dtype=np.float32)
    print("  推理 %.2f s  输出 shape=%s dtype=%s" % (dt, a.shape, a.dtype))
    print("  nonzero=%d  max=%.4f  argmax=%d" % (int((a != 0).sum()), float(a.max()), int(a.argmax())))
except Exception as e:
    print("  infer 异常:", type(e).__name__, str(e)[:400])

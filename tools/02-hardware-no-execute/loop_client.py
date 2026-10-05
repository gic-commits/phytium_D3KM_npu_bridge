import sys, os, time, numpy as np
sys.path.insert(0, "/opt/npu/python")
import npu_client as npu

MODEL = os.environ.get("MB_MODEL", "mobilenet")
SHAPE = tuple(int(v) for v in os.environ.get("MB_SHAPE", "1,3,224,224").split(","))
N = int(os.environ.get("MB_N", "6"))

c = npu.connect()
print("[loop] connected")
t0 = time.time()
r = c.load(MODEL)
print("[loop] load -> %r (%.1fs)" % (r, time.time() - t0))

for i in range(1, N + 1):
    try:
        x = np.random.rand(*SHAPE).astype(np.float32)
        t0 = time.time()
        outs = c.infer(MODEL, x)
        dt = time.time() - t0
        o = outs[0] if isinstance(outs, (list, tuple)) else outs
        a = np.asarray(o, dtype=np.float32)
        print("[loop#%d] 推理 %.2fs argmax=%d max=%.4f nonzero=%d"
              % (i, dt, int(a.argmax()), float(a.max()), int((a != 0).sum())))
    except Exception as e:
        print("[loop#%d] 失败: %s" % (i, str(e)[:120]))
    sys.stdout.flush()

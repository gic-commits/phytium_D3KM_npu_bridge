import sys, os, time, numpy as np
sys.path.insert(0, "/opt/npu/python")
import npu_client as npu

MODEL = os.environ.get("MB_MODEL", "mobilenet")
SHAPE = tuple(int(v) for v in os.environ.get("MB_SHAPE", "1,3,224,224").split(","))
MODE = os.environ.get("MB_MODE", "both")
TAG = os.environ.get("MB_TAG", "client")

c = npu.connect()
print("[%s] connected" % TAG)

if MODE in ("load", "both"):
    t0 = time.time()
    try:
        r = c.load(MODEL)
        print("[%s] load -> %r (%.1fs)" % (TAG, r, time.time() - t0))
    except Exception as e:
        print("[%s] load 异常: %s" % (TAG, str(e)[:200]))

if MODE in ("infer", "both"):
    try:
        x = np.random.rand(*SHAPE).astype(np.float32)
        t0 = time.time()
        outs = c.infer(MODEL, x)
        dt = time.time() - t0
        o = outs[0] if isinstance(outs, (list, tuple)) else outs
        a = np.asarray(o, dtype=np.float32)
        print("[%s] 推理 %.2fs shape=%s argmax=%d max=%.4f" % (TAG, dt, a.shape, int(a.argmax()), float(a.max())))
    except Exception as e:
        print("[%s] infer 异常: %s" % (TAG, str(e)[:200]))

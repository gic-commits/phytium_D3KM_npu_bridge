import sys, os, time, numpy as np
sys.path.insert(0, "/opt/npu/python")
import npu_client as npu

print("=== 1. 连接池服务 ===")
c = npu.connect()
print("  connected, status:", c.status())

print("=== 2. 尝试加载 sensevoice 包 ===")
t0 = time.time()
try:
    r = c.load("sensevoice")
    print("  load -> %r  (%.1f s)" % (r, time.time() - t0))
except Exception as e:
    print("  load 异常:", type(e).__name__, str(e)[:400])

print("=== 3. 若加载成功，跑一次推理 ===")
try:
    x = np.random.rand(1, 200, 560).astype(np.float32)
    t0 = time.time()
    outs = c.infer("sensevoice", x)
    dt = time.time() - t0
    o = outs[0] if isinstance(outs, (list, tuple)) else outs
    a = np.asarray(o, dtype=np.float32)
    print("  推理 %.2f s  输出 shape=%s dtype=%s" % (dt, a.shape, a.dtype))
    print("  nonzero=%d  max=%.4f  argmax=%d" % (int((a != 0).sum()), float(a.max()), int(a.argmax())))
    np.save("/tmp/sv_pool_out.npy", a)
except Exception as e:
    print("  infer 异常:", type(e).__name__, str(e)[:400])

print("=== 4. 服务端日志尾部 ===")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""借壳手术：把 ONNX 图里的 MatMul 等价改写成 1x1 Conv（NPU 只认 CNN 算子）。

原理：
    MatMul(X[B,M,K], W[K,N])  ==  Conv2d(x[B,K,M,1], w[N,K,1,1])  -> [B,N,M,1] -> [B,M,N]
即：
    1) Transpose/Reshape X: [B,M,K] -> [B,K,M,1]
    2) Conv (w = W 转置成 [N,K,1,1])
    3) Reshape/Transpose 回 [B,M,N]

用法（在设备上跑，需要 onnx 包）：
    python3 matmul2conv.py <in.onnx> <out.onnx> [--limit N] [--dry]
"""
import sys
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

NP = TensorProto.FLOAT


def main():
    if len(sys.argv) < 3:
        print("用法: matmul2conv.py <in.onnx> <out.onnx> [--limit N] [--dry]")
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    limit = 0
    dry = "--dry" in sys.argv
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    m = onnx.load(src)
    try:
        m = onnx.shape_inference.infer_shapes(m)
        print("[infer] shape inference OK")
    except Exception as e:
        print("[infer] 失败(继续): %s" % str(e)[:120])
    g = m.graph
    inits = {i.name: i for i in g.initializer}
    vi = {v.name: v for v in list(g.value_info) + list(g.input) + list(g.output)}

    # 统计
    from collections import Counter
    ops = Counter(n.op_type for n in g.node)
    print("[图] 节点总数=%d" % len(g.node))
    print("[图] 算子分布 top15: %s" % ops.most_common(15))

    cands = []
    for n in g.node:
        if n.op_type != "MatMul":
            continue
        if len(n.input) != 2 or len(n.output) != 1:
            continue
        w = inits.get(n.input[1])
        if w is None or w.dims is None or len(w.dims) != 2:
            continue
        cands.append((n, w))
    print("[图] 可改写 MatMul（常量权重、2D）数量=%d" % len(cands))
    if dry or not cands:
        return 0
    if limit:
        cands = cands[:limit]

    new_nodes, new_inits = [], []
    for idx, (n, w) in enumerate(cands):
        tag = "MM2C_%d" % idx
        K, N = int(w.dims[0]), int(w.dims[1])
        # Conv 权重 [N, K, 1, 1] = W 转置
        wt = numpy_helper.to_array(w).T.reshape(N, K, 1, 1)
        wn = "%s_w" % tag
        new_inits.append(numpy_helper.from_array(wt.astype(np.float32), wn))
        x = n.input[0]
        y = n.output[0]
        t1, t2 = "%s_t1" % tag, "%s_t2" % tag
        #  动态形状用 Shape/Gather/Concat 太重：这里假设 x 形状可在 value_info 得到
        v = vi.get(x)
        if v is None or not v.type.HasField("tensor_type"):
            print("  [跳过] %s 无形状信息" % n.name)
            continue
        dims = [d.dim_value for d in v.type.tensor_type.shape.dim]
        if len(dims) != 3 or any(d <= 0 for d in dims):
            print("  [跳过] %s 形状非静态3D: %s" % (n.name, dims))
            continue
        B, M, Kd = dims
        if Kd != K:
            print("  [跳过] %s K 不匹配 %d vs %d" % (n.name, Kd, K))
            continue
        new_nodes += [
            helper.make_node("Reshape", [x, tag + "_shp"], [t1], name=tag + "_r1"),
            helper.make_node("Transpose", [t1], [t1 + "_t"], perm=[0, 2, 1], name=tag + "_tr"),
            helper.make_node("Conv", [t1 + "_t", wn], [t2],
                             name=tag + "_conv", kernel_shape=[1, 1], pads=[0, 0, 0, 0], strides=[1, 1]),
            helper.make_node("Reshape", [t2, tag + "_shp2"], [y], name=tag + "_r2"),
        ]
        new_inits.append(numpy_helper.from_array(
            np.array([B, K, M, 1], dtype=np.int64), tag + "_shp"))
        new_inits.append(numpy_helper.from_array(
            np.array([B, M, N], dtype=np.int64), tag + "_shp2"))

    done = len(new_nodes) // 4
    print("[改写] 成功改写 %d 个 MatMul -> Conv×1" % done)
    if done == 0:
        return 1
    keep = [n for n in g.node if n.op_type != "MatMul" or n not in [c[0] for c in cands]]
    del g.node[:]
    g.node.extend(keep)
    g.node.extend(new_nodes)
    g.initializer.extend(new_inits)
    onnx.checker.check_model(m)
    onnx.save(m, dst)
    print("[保存] %s" % dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())

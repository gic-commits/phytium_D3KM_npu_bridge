#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""借壳可行性速测（在设备上跑）：
对几个"最小算子形态"分别建 ORT session，看 PHYNPU EP 的 GetCapability 是否接受，
以及能否执行 —— 直接回答"把 Transformer 算子改写成 CNN 形态能否上 NPU"。

测的形态：
  m1  1x1 Conv（普通）                     —— 基线，应可
  m2  MatMul 原样                          —— 预期被拒
  m3  MatMul 改写成 1x1 Conv               —— ★ 借壳核心
  m4  depthwise Conv kernel=[11,1] group=C —— ★ FSMN 同形态（EP 报 FRC 的那种）
  m5  普通 Conv kernel=[11,1]              —— 对照
"""
import os
import sys
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto
import onnxruntime as ort

NP = TensorProto.FLOAT
OUT = "/home/greatwall/asr/bk"
os.makedirs(OUT, exist_ok=True)


def build(kind):
    """返回 (model, input_name, input_arr)"""
    inits, nodes = [], []
    if kind == "m1_conv1x1":
        x = helper.make_tensor_value_info("X", NP, [1, 16, 8, 1])
        y = helper.make_tensor_value_info("Y", NP, [1, 32, 8, 1])
        w = numpy_helper.from_array(np.random.rand(32, 16, 1, 1).astype(np.float32), "W")
        inits.append(w)
        nodes.append(helper.make_node("Conv", ["X", "W"], ["Y"], kernel_shape=[1, 1]))
        arr = np.random.rand(1, 16, 8, 1).astype(np.float32)
    elif kind == "m2_matmul":
        x = helper.make_tensor_value_info("X", NP, [1, 8, 16])
        y = helper.make_tensor_value_info("Y", NP, [1, 8, 32])
        w = numpy_helper.from_array(np.random.rand(16, 32).astype(np.float32), "W")
        inits.append(w)
        nodes.append(helper.make_node("MatMul", ["X", "W"], ["Y"]))
        arr = np.random.rand(1, 8, 16).astype(np.float32)
    elif kind == "m3_mm_as_conv":
        x = helper.make_tensor_value_info("X", NP, [1, 8, 16])
        y = helper.make_tensor_value_info("Y", NP, [1, 8, 32])
        w = numpy_helper.from_array(np.random.rand(32, 16, 1, 1).astype(np.float32), "W")
        inits.append(w)
        nodes += [
            helper.make_node("Transpose", ["X"], ["Xt"], perm=[0, 2, 1]),
            helper.make_node("Unsqueeze", ["Xt", "ax3"], ["X4"]),
            helper.make_node("Conv", ["X4", "W"], ["Y4"], kernel_shape=[1, 1]),
            helper.make_node("Squeeze", ["Y4", "ax3"], ["Y"]),
        ]
        inits.append(numpy_helper.from_array(np.array([3], dtype=np.int64), "ax3"))
        arr = np.random.rand(1, 8, 16).astype(np.float32)
    elif kind == "m4_dwconv11":
        x = helper.make_tensor_value_info("X", NP, [1, 512, 200, 1])
        y = helper.make_tensor_value_info("Y", NP, [1, 512, 200, 1])
        w = numpy_helper.from_array(np.random.rand(512, 1, 11, 1).astype(np.float32), "W")
        inits.append(w)
        nodes.append(helper.make_node(
            "Conv", ["X", "W"], ["Y"], group=512, kernel_shape=[11, 1],
            pads=[5, 0, 5, 0], strides=[1, 1], dilations=[1, 1]))
        arr = np.random.rand(1, 512, 200, 1).astype(np.float32)
    elif kind == "m5_conv11":
        x = helper.make_tensor_value_info("X", NP, [1, 8, 200, 1])
        y = helper.make_tensor_value_info("Y", NP, [1, 8, 200, 1])
        w = numpy_helper.from_array(np.random.rand(8, 8, 11, 1).astype(np.float32), "W")
        inits.append(w)
        nodes.append(helper.make_node(
            "Conv", ["X", "W"], ["Y"], kernel_shape=[11, 1],
            pads=[5, 0, 5, 0], strides=[1, 1], dilations=[1, 1]))
        arr = np.random.rand(1, 8, 200, 1).astype(np.float32)
    else:
        raise ValueError(kind)
    g = helper.make_graph(nodes, kind, [x], [y], inits)
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 8
    return m, "X", arr


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for kind in ["m1_conv1x1", "m2_matmul", "m3_mm_as_conv", "m4_dwconv11", "m5_conv11"]:
        if only and only not in kind:
            continue
        path = os.path.join(OUT, kind + ".onnx")
        try:
            m, xin, arr = build(kind)
            onnx.checker.check_model(m)
            onnx.save(m, path)
        except Exception as e:
            print("[%s] 建图失败: %s" % (kind, e))
            continue
        try:
            so = ort.SessionOptions()
            so.log_severity_level = 3
            s = ort.InferenceSession(path, so,
                                     providers=["PHYNPUExecutionProvider", "CPUExecutionProvider"])
            prov = s.get_providers()
            t = s.run(None, {xin: arr})
            print("[%s] ✅ 可建会话+可执行  prov=%s  out=%s" % (kind, prov, t[0].shape))
        except Exception as e:
            msg = str(e).replace("\n", " ")[:220]
            print("[%s] ❌ %s: %s" % (kind, type(e).__name__, msg))


if __name__ == "__main__":
    main()

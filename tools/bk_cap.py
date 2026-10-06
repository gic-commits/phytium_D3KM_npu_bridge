#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测各最小形态被 PHYNPU EP **认领**的节点数（GetCapability 声明）。"""
import os
import sys
import numpy as np
import onnx
import onnxruntime as ort

sys.path.insert(0, "/tmp")
from bk_probe import build, OUT  # noqa: E402

ort.set_default_logger_severity(0)
for kind in ["m1_conv1x1", "m2_matmul", "m3_mm_as_conv", "m4_dwconv11", "m5_conv11"]:
    path = os.path.join(OUT, kind + ".onnx")
    if not os.path.exists(path):
        m, _, _ = build(kind)
        os.makedirs(OUT, exist_ok=True)
        onnx.save(m, path)
    print("================ %s ================" % kind)
    try:
        _, xin, arr = build(kind)
        so = ort.SessionOptions()
        so.log_severity_level = 0
        s = ort.InferenceSession(path, so,
                                 providers=["PHYNPUExecutionProvider", "CPUExecutionProvider"])
        try:
            s.run(None, {xin: arr})
            print("  执行: OK")
        except Exception as e:
            print("  执行: 异常 %s" % str(e)[:120])
    except Exception as e:
        print("  建会话异常: %s" % str(e)[:160])

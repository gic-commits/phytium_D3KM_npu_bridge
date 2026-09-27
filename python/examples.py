#!/usr/bin/env python3
"""examples.py — NPU 服务 Python 客户端示例（真机可跑，**不依赖 opencv**）

跑法：
    export NPU_SOCK=/run/npu/npu.sock
    python3 examples.py
覆盖：
  ① 图像→张量级：yunet 三输出（形状/非零统计）
  ② 图像级：人脸检测（应 1 张脸，score≈0.9553）
  ③ 分类：ResNet50（同一套 infer_image 三段式，换模型即可）
  ④ 纯张量级：任意 ndim 输入（语音 mel 形状示例），验证接口与"图像"无关
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import npu_client as npu

IMG = os.environ.get("NPU_SMOKE_IMG", "/opt/npu/testdata/20210828122250_3b289.jpg")
CLS_IMG = os.environ.get("NPU_IMAGENET_IMG", "/opt/npu/testdata/2.jpg")


def main():
    with npu.connect() as c:
        s = c.status()
        print("== STATUS: MODE=%s REQS=%s ERRS=%s SWITCHES=%s"
              % (s.get("MODE"), s.get("REQS"), s.get("ERRS"), s.get("SWITCHES")))

        print("\n== ① 图像→张量级 yunet（3 输出；prep 在 C++ 侧，Python 无需 cv2）")
        outs = c.infer_image("yunet_npu", IMG, 112, 112, norm=0)
        for i, o in enumerate(outs):
            print("   out[%d] shape=%s 非零=%d 头4=%s"
                  % (i, o.shape, int(np.count_nonzero(o)), np.round(o[:4], 4)))

        print("\n== ② 图像级人脸检测")
        faces = c.detect_yunet("yunet_npu", IMG, 112, 112, 0)
        print("   检出 %d 张" % len(faces))
        for f in faces[:3]:
            print("   box=%s score=%.4f kps=%s"
                  % (tuple(round(v, 1) for v in f["box"]), f["score"],
                     [(round(a, 1), round(b, 1)) for a, b in f["kps"]]))

        print("\n== ③ ResNet50 分类（同一 infer_image 三段式，换模型/尺寸/归一化即可）")
        try:
            o = c.infer_image("Restnet50", CLS_IMG, 224, 224, norm=1)[0]
            flat = o.reshape(-1)
            top = int(np.argmax(flat))
            print("   输出 shape=%s 类别数=%d → 预测类 %d（置信度 %.4f）"
                  % (o.shape, flat.size, top, float(flat[top])))
        except Exception as e:
            print("   跳过（%s）" % e)

        print("\n== ④ 纯张量级（接口不假设图像：直接送任意 ndim 的 float32）")
        mel = np.zeros((1, 80, 128), dtype=np.float32)      # 语音 mel 特征形状示例
        try:
            outs = c.infer("yunet_npu", mel)
            print("   被接受（输出 %d 个）——但形状由模型决定，故这只是接口示意" % len(outs))
        except Exception as e:
            print("   形状与模型不符即报错（符合预期）: %s" % e)

        s = c.status()
        print("\n== 结束 STATUS: REQS=%s ERRS=%s SWITCHES=%s WORKER_TIMEOUTS=%s"
              % (s.get("REQS"), s.get("ERRS"), s.get("SWITCHES"), s.get("WORKER_TIMEOUTS")))


if __name__ == "__main__":
    main()

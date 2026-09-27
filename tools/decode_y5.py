#!/usr/bin/env python3
# decode_y5.py — 按厂商 yolov5s.cpp 的算法解码 NPU 输出（验收用）
# 用法: decode_y5.py <out.bin> <img_w> <img_h> [conf_thr] [score_thr]
import sys, numpy as np, cv2

binp, iw, ih = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
conf_thr = float(sys.argv[4]) if len(sys.argv) > 4 else 0.30
score_thr = float(sys.argv[5]) if len(sys.argv) > 5 else 0.25

raw = np.fromfile(binp, dtype=np.float32)
rows, dims = 25200, 85
assert raw.size >= rows * dims, f"bin too small: {raw.size}"
d = raw[:rows * dims].reshape(rows, dims)

conf = d[:, 4]
cls_scores = d[:, 5:]
cls_id = cls_scores.argmax(axis=1)
cls_val = cls_scores.max(axis=1)

print(f"总行 {rows}  dims={dims}")
print(f"conf: min={conf.min():.4f} max={conf.max():.4f} mean={conf.mean():.4f}  >={conf_thr}: {(conf>=conf_thr).sum()}")
print(f"cls_val max={cls_val.max():.4f}  >={score_thr}: {(cls_val>=score_thr).sum()}")
print("前 5 行原始:", np.array2string(d[:5, :8], precision=4))

keep = (conf >= conf_thr) & (cls_val >= score_thr)
xywh = d[keep][:, :4]
scores = cls_val[keep]
ids = cls_id[keep]
xf, yf = iw / 640.0, ih / 640.0

boxes = []
for (x, y, w, h) in xywh:
    boxes.append([int((x - 0.5 * w) * xf), int((y - 0.5 * h) * yf),
                  int(w * xf), int(h * yf)])
if boxes:
    idx = cv2.dnn.NMSBoxes(boxes, scores.tolist(), score_thr, 0.4)
    idx = np.array(idx).reshape(-1)
    labels = [l.strip() for l in open(sys.argv[6] if len(sys.argv) > 6 else "coco-labels-2014_2017.txt") if l.strip()]
    print(f"\n== NMS 后 {len(idx)} 个检测（原图 {iw}x{ih}）==")
    for k in idx[:10]:
        cid = int(ids[k]); b = boxes[k]
        name = labels[cid] if cid < len(labels) else f"id{cid}"
        print(f"  {name:20s} conf={scores[k]:.4f} box=({b[0]},{b[1]},{b[2]}x{b[3]}) 图片范围={'OK' if 0<=b[0]<iw and 0<=b[1]<ih else '越界'}")
else:
    print("\n没有通过阈值的检测")

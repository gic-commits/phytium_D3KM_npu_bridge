#!/usr/bin/env python3
# decode_scrfd.py — 照抄厂商 run_face_scrd.py 的解码（方形图: 无 letterbox）
# 用法: decode_scrfd.py <前缀> <src_w> <src_h> [conf] [nms]
import sys, numpy as np, cv2

pre = sys.argv[1]; sw = int(sys.argv[2]); sh = int(sys.argv[3])
conf_thr = float(sys.argv[4]) if len(sys.argv) > 4 else 0.3
nms_thr = float(sys.argv[5]) if len(sys.argv) > 5 else 0.8
INP, STRIDES, NA = 640, [8, 16, 32], 2
newh = neww = INP; padh = padw = 0

def load(i):
    return np.fromfile(f"{pre}_{i}.bin", dtype=np.float32)

scores_list, bboxes_list, kpss_list = [], [], []
for idx, stride in enumerate(STRIDES):
    scores = load(idx).reshape(-1, 1)
    bbox_preds = load(idx + 3).reshape(-1, 4) * stride
    kps_preds = load(idx + 6).reshape(-1, 10) * stride
    h, w = INP // stride, INP // stride
    ac = np.stack(np.mgrid[:h, :w][::-1], axis=-1).astype(np.float32)
    ac = (ac * stride).reshape((-1, 2))
    if NA > 1:
        ac = np.stack([ac] * NA, axis=1).reshape((-1, 2))
    pos = np.where(scores[:, 0] >= conf_thr)[0]
    x1 = ac[:, 0] - bbox_preds[:, 0]; y1 = ac[:, 1] - bbox_preds[:, 1]
    x2 = ac[:, 0] + bbox_preds[:, 2]; y2 = ac[:, 1] + bbox_preds[:, 3]
    bb = np.stack([x1, y1, x2, y2], axis=-1)
    kps = []
    for i in range(0, 10, 2):
        kps.append(ac[:, i % 2] + kps_preds[:, i]); kps.append(ac[:, i % 2 + 1] + kps_preds[:, i + 1])
    kps = np.stack(kps, axis=-1).reshape((kps_preds.shape[0], -1, 2))
    scores_list.append(scores[pos]); bboxes_list.append(bb[pos]); kpss_list.append(kps[pos])

scores = np.vstack(scores_list).ravel()
bboxes = np.vstack(bboxes_list)
kpss = np.vstack(kpss_list)
bboxes[:, 2:4] = bboxes[:, 2:4] - bboxes[:, 0:2]
rh, rw = sh / newh, sw / neww
bboxes[:, 0] = (bboxes[:, 0] - padw) * rw
bboxes[:, 1] = (bboxes[:, 1] - padh) * rh
bboxes[:, 2] *= rw; bboxes[:, 3] *= rh
kpss[:, :, 0] = (kpss[:, :, 0] - padw) * rw
kpss[:, :, 1] = (kpss[:, :, 1] - padh) * rh

print(f"候选 {len(scores)} 个; score: max={scores.max():.4f} mean={scores.mean():.4f} >0.5: {(scores>0.5).sum()}")
if len(bboxes) == 0:
    print("无候选"); sys.exit(0)
xyxy = np.stack([bboxes[:, 0], bboxes[:, 1], bboxes[:, 0] + bboxes[:, 2], bboxes[:, 1] + bboxes[:, 3]], axis=1)
idx = cv2.dnn.NMSBoxes(xyxy.tolist(), scores.tolist(), conf_thr, nms_thr)
keep = np.array(idx).reshape(-1) if len(idx) else []
print(f"== NMS 后 {len(keep)} 张脸（原图 {sw}x{sh}）==")
for i in keep[:8]:
    b = bboxes[i]; k = kpss[i]
    print(f"   score={scores[i]:.4f} box=({b[0]:.1f},{b[1]:.1f},{b[0]+b[2]:.1f},{b[1]+b[3]:.1f}) "
          f"kps=" + " ".join(f"({p[0]:.1f},{p[1]:.1f})" for p in k))

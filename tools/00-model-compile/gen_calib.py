#!/usr/bin/env python3
"""gen_calib.py — 生成 test.json 里 extension=f32/data 所需的**原始张量**校准文件

用法:
  python gen_calib.py --spec x=float32:1,200,560  x_length=int32:1  language=int32:1  text_norm=int32:1                       --out-dir ./calib [--values language=0,3 text_norm=14,15]

要点（实测）：
  - 文件内容 = **raw 数组**，dtype 必须与 io.json 的 dtype 一致（加载侧用 np.fromfile(dtype=...)）
  - 每个输入一个文件；test.json 里 image_path 指向它，extension 写 f32 或 data
  - 多张校准样本可用**目录** + `-mi N`（目录里放同扩展名的多个文件）
"""
import argparse, os, numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", nargs="+", required=True, help="name=dtype:dim1,dim2,...")
    ap.add_argument("--values", nargs="*", default=[], help="name=v1,v2（给标量输入指定真实取值，可重复多个样本）")
    ap.add_argument("--out-dir", default="./calib")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    vals = {}
    for kv in a.values:
        k, v = kv.split("=", 1)
        vals[k] = [int(x) for x in v.split(",")]

    for spec in a.spec:
        name, rest = spec.split("=", 1)
        dtype, dims = rest.split(":", 1)
        shape = [int(x) for x in dims.split(",")]
        dt = np.dtype(dtype)
        if name in vals:
            arr = np.array(vals[name], dtype=dt)
        elif np.issubdtype(dt, np.floating):
            arr = (np.random.rand(*shape).astype(np.float32) * 2 - 1).astype(dt)
        else:
            arr = np.zeros(shape, dtype=dt)
        p = os.path.join(a.out_dir, name + ".bin")
        arr.tofile(p)
        print(f"  {p}: shape={list(arr.shape)} dtype={arr.dtype} {os.path.getsize(p)} 字节")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""打印模型 json 里第一个张量（输入）的形状，供回归脚本定输入尺寸。"""
import json
import sys

d = json.load(open(sys.argv[1]))
for k, v in d.get("attrs", {}).items():
    if k == "shape":
        t0 = v[1][0]
        print(t0[-2], t0[-1])          # H W
        break

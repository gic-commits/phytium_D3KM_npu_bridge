#!/usr/bin/env python3
# 反汇编 libnpuclient.so 的 npu_infer_ex 函数
import subprocess

L = "/opt/npu/lib/libnpuclient.so"
out = subprocess.run(["nm", "-D", L], capture_output=True, text=True, errors="replace")
for ln in out.stdout.splitlines():
    if 'npu_infer' in ln or 'npu_load' in ln or 'npu_open' in ln:
        print(ln)

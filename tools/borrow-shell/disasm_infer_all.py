#!/usr/bin/env python3
# 反汇编 infer_all 函数（0xa000 开始）
import subprocess

L = "/opt/npu/lib/libnpuclient.so"
out = subprocess.run(["objdump", "-d", "--start-address=0xa000", "--stop-address=0xb230", L],
                     capture_output=True, text=True, errors="replace")
print(out.stdout)

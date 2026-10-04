#!/usr/bin/env python3
# 反汇编 npu_infer_ex 函数
import subprocess

L = "/opt/npu/lib/libnpuclient.so"
out = subprocess.run(["objdump", "-d", "--start-address=0xb230", "--stop-address=0xb6a0", L],
                     capture_output=True, text=True, errors="replace")
print(out.stdout)

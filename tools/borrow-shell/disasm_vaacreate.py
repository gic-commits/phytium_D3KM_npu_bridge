#!/usr/bin/env python3
# 反汇编 VhaVaaHeapCreate 的完整逻辑（0x3f9f8 - 0x3fda8）
import subprocess

L = "/usr/local/lib/libnpusession.so"
out = subprocess.run(["objdump", "-d", "--start-address=0x3f9f8", "--stop-address=0x3fda8", L],
                     capture_output=True, text=True, errors="replace")
print(out.stdout)

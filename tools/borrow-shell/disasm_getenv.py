#!/usr/bin/env python3
# 找 CreateVha 里 getenv 读的环境变量名
import subprocess

L = "/usr/local/lib/libnpusession.so"
print("=== 1. 0x800f8 附近的串 ===")
out = subprocess.run(["strings", "-t", "x", L], capture_output=True, text=True, errors="replace")
for ln in out.stdout.splitlines():
    parts = ln.strip().split(None, 1)
    if len(parts) == 2:
        try:
            addr = int(parts[0], 16)
            if 0x80000 <= addr <= 0x80200:
                print(f"  0x{addr:x}: {parts[1]}")
        except ValueError:
            pass

print()
print("=== 2. CreateVha 里所有 getenv 调用 ===")
out2 = subprocess.run(["objdump", "-d", "--start-address=0x76000", "--stop-address=0x77000", L],
                      capture_output=True, text=True, errors="replace")
lines = out2.stdout.splitlines()
for i, ln in enumerate(lines):
    if 'getenv' in ln:
        # 找前面的 adrp+add
        for j in range(max(0, i-5), i):
            if 'adrp' in lines[j] or 'add' in lines[j]:
                print(f"  {lines[j].strip()}")
        print(f"  {ln.strip()}")
        print()

print()
print("=== 3. 关键：VhaVaaHeapCreate 的参数含义 ===")
print("  x0 = [session+16] = heap.base")
print("  w2 = [session+40] = 堆大小（从 getenv 读）")
print("  w3 = 1")
print()
print("  => 如果 [session+40] = 0，堆大小就是 0！")
print("  => 看 getenv 读的是什么变量，默认值是多少")

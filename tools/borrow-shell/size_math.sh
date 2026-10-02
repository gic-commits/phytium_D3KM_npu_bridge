#!/bin/bash
python3 - <<'PYEOF'
print("=== 尺寸反推 shape ===")
sizes = {'库申请': 457776, '段IO声明': 913920, '另一块': 228480}
for name, s in sizes.items():
    print(f"\n  [{name}] = {s} 字节")
    print(f"    /4  = {s//4} 个 float32")
    print(f"    /2  = {s//2} 个 float16")
    # 尝试常见 shape
    for dims, label in [
        ((1,200,560), "x[1,200,560]"),
        ((1,204,25055), "logits[1,204,25055]"),
        ((1,560,200), "x转置"),
        ((200,560), "x去batch"),
        ((1,512,204,1), "FSMN中间"),
    ]:
        n = 1
        for d in dims: n *= d
        for w, wl in ((4,'f32'), (2,'f16')):
            if n*w == s:
                print(f"    = {label} × {wl}  ← 精确匹配")
    # 找整数分解
    print(f"    质因数分解: ", end="")
    n, f = s, []
    d = 2
    while d*d <= n:
        while n % d == 0:
            f.append(d); n //= d
        d += 1
    if n > 1: f.append(n)
    print(" × ".join(map(str, f[:12])) + ("..." if len(f) > 12 else ""))

print("\n=== 关系 ===")
print("  913920 / 457776 = %.6f" % (913920/457776))
print("  913920 / 228480 = %.6f" % (913920/228480))
print("  457776 / 228480 = %.6f" % (457776/228480))
print("  913920 = 457776 + 456144 ?", 457776+456144)
print("  913920 - 457776 =", 913920-457776)
print("  457776 - 228480 =", 457776-228480)
print()
print("  x[1,200,560] f32 =", 1*200*560*4)
print("  x[1,200,560] f16 =", 1*200*560*2)
print("  x 按 560→1120 =", 1*200*1120*4)
print("  x 按 200→400 =", 1*400*560*4)
PYEOF

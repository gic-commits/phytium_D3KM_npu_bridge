import json, os
P = "/tmp/svpkg/__dependencies_info_file__"
d = json.load(open(P, encoding="utf-8", errors="replace"))
print("=== 顶层 3 项各自的键与规模 ===")
for i, it in enumerate(d):
    print("  [%d] 键=%s" % (i, list(it.keys())))
    for k, v in it.items():
        if isinstance(v, (list, dict)):
            print("      %s: %s 长度=%d" % (k, type(v).__name__, len(v)))
        else:
            print("      %s: %r" % (k, v))
print()
print("=== fname_to_nid 规模与样例 ===")
f2n = d[2].get('fname_to_nid') if len(d) > 2 else None
if f2n:
    print("  条目数:", len(f2n))
    items = list(f2n.items())
    print("  前 5:", items[:5])
    print("  后 5:", items[-5:])
    # 统计 __copy 与 npu_main
    copies = [k for k in f2n if k.startswith('__copy')]
    mains = [k for k in f2n if 'npu_main' in k]
    print("  __copy 数:", len(copies), " npu_main 数:", len(mains))
print()
print("=== consumers 结构（前 2 项） ===")
for i in (0, 1):
    c = d[i].get('consumers')
    if isinstance(c, list):
        print("  [%d] consumers 长度=%d 前 20=%s" % (i, len(c), c[:20]))
print()
print("=== dependency 结构 ===")
for i, it in enumerate(d):
    dep = it.get('dependency')
    if dep is not None:
        print("  [%d] dependency 类型=%s 长度=%s" % (i, type(dep).__name__, len(dep) if hasattr(dep,'__len__') else '-'))
        s = json.dumps(dep, ensure_ascii=False)
        print("      前 400 字符:", s[:400])

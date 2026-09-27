#!/usr/bin/env python3
"""ELF 字符串 + vaddr 清单：闭源库取证的第一把刀。

为什么要它：反汇编里 `adrp x2, 0x80000` + `add x2, x2, #0xab0` 这类引用只给出**vaddr**，
`strings` 只给**文件偏移**。本脚本解析 section header 建立 vaddr<->offset 映射，于是可以：
  1) 按**关键字**列出全库字符串（= 开工先拿到"失败模式清单"，见 SKILL.md §一·⑥）
  2) 按**vaddr** 把反汇编里读到的立即数换回字符串（一条命令定位报错含义）
  3) 按**地址区间**列出某段 .rodata（把一组相关日志/表一次性看完）

用法
  python3 elf_va_strings.py LIB.so --kw SUBMIT response "VHA device" sync notify timeout
  python3 elf_va_strings.py LIB.so --va 0x80b40 0x80b78 0x80960
  python3 elf_va_strings.py LIB.so --range 0x80000 0x80200
  python3 elf_va_strings.py LIB.so            # 列全部（长，建议重定向到文件）
退出码非 0 表示有 --va 未落在任何 section（说明立即数算错了，别硬解释）。

跨架构通用（Mac/Linux 均可，不需要 readelf/nm）。
"""
import re
import struct
import sys


def load_secs(data):
    if data[:4] != b'\x7fELF':
        sys.exit('不是 ELF 文件')
    e_shoff, = struct.unpack_from('<Q', data, 0x28)
    e_shentsize, e_shnum, _ = struct.unpack_from('<HHH', data, 0x3a)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        _, _, _, addr, offset, size = struct.unpack_from('<IIQQQQ', data, off)
        if addr and size:
            secs.append((addr, offset, size))
    return secs


def off2va(secs, o):
    for addr, offset, size in secs:
        if offset <= o < offset + size:
            return addr + (o - offset)
    return None


def va2off(secs, va):
    for addr, offset, size in secs:
        if addr <= va < addr + size:
            return offset + (va - addr)
    return None


def cstr(data, o, limit=400):
    e = data.find(b'\0', o, o + limit)
    return data[o:e if e >= 0 else o + limit].decode('utf-8', 'replace')


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path, rest = argv[1], argv[2:]
    data = open(path, 'rb').read()
    secs = load_secs(data)

    mode, vals = 'all', []
    for a in rest:
        if a in ('--kw', '--va', '--range'):
            mode = a[2:]
            continue
        vals.append(a)
    if mode == 'all' and vals:
        sys.exit('参数要跟在 --kw/--va/--range/--range 后面：%s' % ' '.join(vals))

    if mode == 'kw':
        kws = [k.lower() for k in vals]
        if not kws:
            sys.exit('--kw 需要至少一个关键字')
        for m in re.finditer(rb'[ -~]{5,}', data):
            s = m.group().decode()
            if any(k in s.lower() for k in kws):
                va = off2va(secs, m.start())
                if va is not None:
                    print('0x%x  %s' % (va, s))
        return 0

    if mode == 'range':
        lo, hi = (int(x, 0) for x in vals[:2])
        for m in re.finditer(rb'[ -~]{4,}', data):
            va = off2va(secs, m.start())
            if va is not None and lo <= va < hi:
                print('0x%x  %s' % (va, m.group().decode()))
        return 0

    if mode == 'va':
        bad = 0
        for v in vals:
            va = int(v, 0)
            o = va2off(secs, va)
            if o is None:
                bad += 1
                print('0x%x: <不在任何 section —— 立即数/基址算错了>' % va)
            else:
                print('0x%x: %r' % (va, cstr(data, o)))
        return 1 if bad else 0

    # mode == all
    for m in re.finditer(rb'[ -~]{5,}', data):
        va = off2va(secs, m.start())
        if va is not None:
            print('0x%x  %s' % (va, m.group().decode()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

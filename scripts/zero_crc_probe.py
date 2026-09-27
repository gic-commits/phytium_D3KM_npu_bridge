#!/usr/bin/env python3
"""
zero_crc_probe.py —— 离线判"某块缓冲有没有被写过"

原理：很多加速器/驱动的输出缓冲是**零初始化**的（dma_alloc_coherent / kzalloc / memset）。
     于是现场报来的 "before" CRC 往往恰好等于 **同尺寸全 0 缓冲的 CRC32**；
     而 "after" CRC **不等于** 它 ⇒ 该缓冲确实被写入了非零内容。
     一行算术就能把"引擎没写"与"上层没拿到"分开，不必上机。

用法
----
# ① 判定模式：给尺寸与观察到的 CRC（十六进制），看它是不是"全 0 缓冲的 CRC"
python3 zero_crc_probe.py --size 39592:0xbc46820e --size 5656:0x9d728bb9
#   支持 CRC 变体：附 --variants zlib,crc32c,mpeg2,init0 （默认全试）

# ② 文件模式：直接对 dump 文件算 CRC，并与"同长度全 0"对照
python3 zero_crc_probe.py --file dump1_0.bin --file dump1_1.bin

# ③ 生成对照表：只给尺寸，打印各变体下全 0 缓冲的 CRC，便于手抄给现场
python3 zero_crc_probe.py --size 2828
"""
import argparse, zlib, sys, os

def crc32_reflected(data, poly, init=0xFFFFFFFF, xorout=0xFFFFFFFF):
    """反射型 CRC-32（zlib 用的是 poly=0xEDB88320, init/xorout=0xFFFFFFFF）"""
    crc = init
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (poly if crc & 1 else 0)
    return (crc ^ xorout) & 0xFFFFFFFF

def crc32c(data):
    return crc32_reflected(data, 0x82F63B78)          # Castagnoli（部分硬件/文件系统用）

def crc32_mpeg2(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc

VARIANTS = {
    "zlib":   lambda d: zlib.crc32(d) & 0xFFFFFFFF,        # = IEEE, init/xorout 全 1（最常见）
    "init0":  lambda d: zlib.crc32(d, 0) & 0xFFFFFFFF,     # 同 zlib 但 init=0
    "crc32c": crc32c,
    "mpeg2":  crc32_mpeg2,
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", action="append", default=[],
                    help="N 或 N:0xCRC（字节数，可选附带现场观察到的 CRC）")
    ap.add_argument("--file", action="append", default=[], help="dump 文件（算它的 CRC）")
    ap.add_argument("--variants", default="zlib,init0,crc32c,mpeg2")
    a = ap.parse_args()
    want = [v.strip() for v in a.variants.split(",") if v.strip() in VARIANTS]
    if not a.size and not a.file:
        ap.print_help(); return 1

    for spec in a.size:
        n, _, obs = spec.partition(":")
        n = int(n, 0)
        zeros = bytes(n)
        line = f"size={n:>8}  全0缓冲: " + "  ".join(f"{k}=0x{VARIANTS[k](zeros):08x}" for k in want)
        if obs:
            val = int(obs, 0)
            hit = [k for k in want if VARIANTS[k](zeros) == val]
            line += f" | 现场值=0x{val:08x} ⇒ " + (
                f"★ 命中 {hit} ⇒ 该缓冲**没有被写过**（仍是初值 0）" if hit else
                "无匹配 ⇒ 该缓冲**已被写入非零内容**")
        print(line)

    for path in a.file:
        data = open(path, "rb").read()
        zeros = bytes(len(data))
        print(f"{os.path.basename(path):<28} len={len(data):>9} " +
              "  ".join(f"{k}=0x{VARIANTS[k](data):08x}" for k in want) +
              f"  (全0对照: zlib=0x{zlib.crc32(zeros) & 0xFFFFFFFF:08x})" +
              ("  ⇒ 全 0！" if not any(data) else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mbs_hdr.py — 离线读厂商 NPU 模型容器（.tar / MBS / .so）的
  (1) 容器头「代别字」（飞腾实测：MBS[4]；0x0f=旧代(能跑) / 0x10=新代(yolov5s 卡住)）
  (2) 命令流(CMDS)头的 w0..w5  —— w0 高16位=0x0400 签名、低16位=总字数；
                                 w2/w4 是「工具链代别指纹」
不需要设备、不需要运行时；纯文件解析，用于与运行期读数交叉验证、并做跨包代别分诊。

用法：
  python3 mbs_hdr.py <file> [<file> ...]
  python3 mbs_hdr.py --dump <file> <cmds_offset>     # 打印该偏移起 64 字节

设计要点（踩过的坑）：
  * CMDS 在容器里的偏移**不是常量** —— 它等于缓冲表长度，随缓冲数量变化
    （实测 yunet 676 / resnet50 404 / yolov5s 752 / ppocrv3_cls 428）
    ⇒ 因此用「dword 高16位==0x0400 且低16位>50」的签名自动定位，别写死偏移。
  * 容器魔法 42beef42 可能在文件里出现多次，取首次命中即可（tar 内是裸容器）。
已在 4 个厂商包上验证：
  yunet(能跑)      ver=0x0f  cmds@676  words=798   w2=20413090 w3=e000001f w4=361c1122 w5=0002e000
  resnet50(能跑)   ver=0x0f  cmds@404  words=4339  w2=20413090 w3=e000001f w4=261c1122 w5=0002e000
  yolov5s(卡住)    ver=0x10  cmds@752  words=2401  w2=20413482 w3=00000630 w4=1f000208 w5=0000000a
  ppocrv3_cls      ver=0x10  cmds@428  words=2093  w2=20413482 w3=00000430 w4=1f000208 w5=00000003
"""
import sys, struct

MAGIC = b'\x42\xef\xbe\x42'


def analyze(path):
    d = open(path, 'rb').read()
    i = d.find(MAGIC)
    if i < 0:
        return None
    m = d[i:]
    ver = struct.unpack_from('<I', m, 4)[0]
    stamp16 = struct.unpack_from('<Q', m, 16)[0]
    off = None
    for w in range(0, min(len(m) // 4, 60000)):
        v = struct.unpack_from('<I', m, w * 4)[0]
        if (v >> 16) == 0x0400 and (v & 0xffff) > 50:   # 流头签名
            off = w * 4
            break
    hdr = [struct.unpack_from('<I', m, off + 4 * k)[0] for k in range(6)] if off is not None else None
    return dict(mbs_off=i, mbs_len=len(m), ver=ver, stamp16=stamp16, cmds_off=off, hdr=hdr)


def main():
    args = sys.argv[1:]
    if args and args[0] == '--dump':
        d = open(args[1], 'rb').read()
        i = d.find(MAGIC)
        m = d[i:]
        o = int(args[2], 0)
        for k in range(0, 64, 16):
            print(f"{o+k:#08x}: " + " ".join(f"{x:08x}" for x in struct.unpack_from('<4I', m, o + k)))
        return
    print(f"{'file':46} {'MBSver':>7} {'mbs@':>6} {'cmds@':>6} {'words':>6}  header w0..w5")
    for p in args:
        r = analyze(p)
        if not r:
            print(f"{p:46} magic not found")
            continue
        h = " ".join(f"{x:08x}" for x in r['hdr']) if r['hdr'] else "-"
        words = (r['hdr'][0] & 0xffff) if r['hdr'] else "-"
        print(f"{p.split('/')[-1]:46} {r['ver']:#7x} {r['mbs_off']:>6} {str(r['cmds_off']):>6} {str(words):>6}  {h}")


if __name__ == '__main__':
    main()

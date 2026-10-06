#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-L1SIZE：把 NPU_INFO 的 l1_size 从硬编码 0 改成可调（库的"临时缓冲"池量）。

依据（第八轮-28，worker 日志实测）：
    FATAL: failed to allocate 28966912 bytes
    ERROR: (getPHYDNNObject) Initialising dnn network from buffer failed because of:
           Cannot allocate vha memory for TEMPORARY buffer
    ERROR: ... unable to create network for function 'tvmgen_default_npu_main_140'
  ⇒ 库在建网阶段为 TEMPORARY buffer 申请 ~28MB，失败 ⇒ 建网失败 ⇒ 执行停住。
  ⇒ NPU_INFO 里 `l1_size = 0`（硬编码），而 l3_size 已是可调的 512MB。
    库很可能用 l1_size 表示"可用于临时缓冲的内存量" ⇒ 0 就意味着没有临时缓冲可用。

改法：新增模块参数 `vha_info_l1_size`（默认 512MB，0644），并让 NPU_INFO 回报它。
      对照实验可置 0 复现原状。

用法: apply_l1size.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

PARAM_OLD = """static unsigned int vha_info_l3_size = 512u << 20;"""
PARAM_NEW = """/* HERMES-L1SIZE: 库的临时缓冲(TEMPORARY buffer)容量口径 —— 原为硬编码 0 */
static unsigned int vha_info_l1_size = 512u << 20;
module_param(vha_info_l1_size, uint, 0644);
MODULE_PARM_DESC(vha_info_l1_size, "VHA: l1_size reported via NPU_INFO (bytes)");

static unsigned int vha_info_l3_size = 512u << 20;"""

USE_OLD = """	info->l1_size = 0;"""
USE_NEW = """	info->l1_size = vha_info_l1_size;   /* HERMES-L1SIZE: 原为硬编码 0 */"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_l1size.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-L1SIZE" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("param", PARAM_OLD), ("use", USE_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_prel1size_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(PARAM_OLD, PARAM_NEW).replace(USE_OLD, USE_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-L1SIZE")
    return 0


if __name__ == "__main__":
    sys.exit(main())

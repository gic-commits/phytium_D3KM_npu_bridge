#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-PUSHSIDMODE：让推送响应的 sid 也带上 slot（试验"库按 sid 关联任务"）。

依据（第八轮-30 反汇编）：
  段处理循环 (VhaDnnImp::Execute 的 lambda, 0x1d3f8)：
     NextSegment() 取段 → 读该段对象 [+2] → 若 ∈{1,4} 视为"已完成"
       → 已完成分支 (0x1e008)：GetSlot() 得到 slot，然后调 HandleResponse(slot,...)
       → 未完成：走 GetSubmitKey 路径去提交
  任务收尾：段倒计数归零 → Update(1) + Done::~Done() ⇒ Signal ⇒ 唤醒 WaitForCompletion

  厂商 `phytium_npu_response_stream()` 填的是 `nstream->nustream.estream.sid`（=0x10101 恒定）。
  我们目前 sid 也用该值、`[+2]` 用自建 slot 序列。

本补丁：新增 `vha_push_sid_mode`
   0 = 用提交描述符里的 sid（现状）
   1 = 用**本次分配的 slot** 当 sid（试"库按 sid 关联任务"）
   2 = sid = slot，且 `[+2]` 固定为 1（状态=完成）

用法: apply_pushsidmode.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

PARAM_ANCHOR = """static int vha_push_sid = -1;"""
PARAM_NEW = """static int vha_push_sid = -1;

/* HERMES-PUSHSIDMODE: 推送响应时的 sid 策略（0=提交里的 sid，1=用 slot 当 sid） */
static int vha_push_sid_mode = 0;
module_param(vha_push_sid_mode, int, 0644);
MODULE_PARM_DESC(vha_push_sid_mode, "0=use submit sid, 1=use slot as sid");"""

# 在 vha_push_response_now 里改 sid 来源
SID_OLD = """	rsp->ursp.sid = sid;"""
SID_NEW = """	rsp->ursp.sid = (vha_push_sid_mode == 1) ? slot : sid;   /* HERMES-PUSHSIDMODE */"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_pushsidmode.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-PUSHSIDMODE" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("param", PARAM_ANCHOR), ("sid", SID_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_prepushsidmode_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(PARAM_ANCHOR, PARAM_NEW).replace(SID_OLD, SID_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-PUSHSIDMODE")
    return 0


if __name__ == "__main__":
    sys.exit(main())

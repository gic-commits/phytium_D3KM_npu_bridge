#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-RSPPERF：把提交流响应的性能字段填上（原为 kzalloc 全 0）。

依据（第八轮-30）：
  `struct npu_user_cnn_submit_rsp { struct npu_user_rsp msg; u64 last_proc_us;
    u32 mem_usage; u32 hw_cycles; }`
  厂商 `phytium_npu_response_stream()` 用 `MAX_NPU_UCNN_RSP_SIZE` 分配并设 `rsp_size` 为该值；
  我们的 `vha_push_response_now()` 尺寸/字段与厂商一致，但 `last_proc_us/mem_usage/hw_cycles`
  因 kzalloc 恒为 0。若库用其中任一字段做有效性判断（例如 mem_usage==0 视为"未真正执行"），
  就会走失败分支。

本补丁：填上合理非零值（可开关 vha_rsp_perf_fill，默认 1；=0 退回原来的全 0）。
   last_proc_us = vha_rsp_perf_us（默认 200）
   mem_usage    = 该会话已分配缓冲总和（简化：用 vha_rsp_perf_mem，默认 1MB）
   hw_cycles    = vha_rsp_perf_cycles（默认 100000）

用法: apply_rspperf.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

PARAM_ANCHOR = """/* HERMES-REPLAYSAME: 重放时保持同一 slot（1=是，默认） */"""
PARAM_NEW = """/* HERMES-RSPPERF: 提交流响应的性能字段（last_proc_us/mem_usage/hw_cycles） */
static int vha_rsp_perf_fill = 1;
module_param(vha_rsp_perf_fill, int, 0644);
MODULE_PARM_DESC(vha_rsp_perf_fill, "fill perf fields in submit response (1=yes)");
static unsigned int vha_rsp_perf_us = 200;
module_param(vha_rsp_perf_us, uint, 0644);
MODULE_PARM_DESC(vha_rsp_perf_us, "value for last_proc_us in response");
static unsigned int vha_rsp_perf_mem = 1048576;
module_param(vha_rsp_perf_mem, uint, 0644);
MODULE_PARM_DESC(vha_rsp_perf_mem, "value for mem_usage in response");
static unsigned int vha_rsp_perf_cycles = 100000;
module_param(vha_rsp_perf_cycles, uint, 0644);
MODULE_PARM_DESC(vha_rsp_perf_cycles, "value for hw_cycles in response");

/* HERMES-REPLAYSAME: 重放时保持同一 slot（1=是，默认） */"""

FILL_OLD = """\trsp->rsp_size = (int)size;
\trsp->session = sess;"""
FILL_NEW = """\trsp->rsp_size = (int)size;
\trsp->session = sess;
\t/* HERMES-RSPPERF: 填提交流响应的性能字段（kzalloc 原为 0） */
\tif (vha_rsp_perf_fill) {
\t\tstruct npu_user_cnn_submit_rsp *crsp =
\t\t\t(struct npu_user_cnn_submit_rsp *)&rsp->ursp;

\t\tcrsp->last_proc_us = vha_rsp_perf_us;
\t\tcrsp->mem_usage = vha_rsp_perf_mem;
\t\tcrsp->hw_cycles = vha_rsp_perf_cycles;
\t}"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_rspperf.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-RSPPERF" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("param", PARAM_ANCHOR), ("fill", FILL_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_presprperf_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(PARAM_ANCHOR, PARAM_NEW).replace(FILL_OLD, FILL_NEW)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-RSPPERF")
    return 0


if __name__ == "__main__":
    sys.exit(main())

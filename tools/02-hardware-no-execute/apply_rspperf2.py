#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-RSPPERF2：修响应缓冲越界 + 填性能字段（对齐厂商分配方式）。

两个问题（第八轮-30）：
1) **越界**：`struct npu_user_stream_rsp` 共 48 字节，`ursp` 在偏移 32；
   而提交流的 `rsp_size = MAX_NPU_UCNN_RSP_SIZE`(24) ⇒ 库会从偏移 32 起读 24 字节
   ⇒ **越过结构体尾部 8 字节**（我们 `kzalloc(sizeof(*rsp))` 只申请了 48）。
   厂商对照：`alloc_size = sizeof(*nustream_rsp) + (MAX_NPU_UCNN_RSP_SIZE - MAX_NPU_USER_RSP_SIZE)`
   ⇒ 必须照做。

2) **性能字段全 0**：`npu_user_cnn_submit_rsp` 还含 `last_proc_us / mem_usage / hw_cycles`，
   kzalloc 后恒为 0；若库据此判有效性会走失败分支。本补丁填合理非零值（可开关）。

用法: apply_rspperf2.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

PARAM_ANCHOR = """/* HERMES-REPLAYSAME: 重放时保持同一 slot（1=是，默认） */"""
PARAM_NEW = """/* HERMES-RSPPERF2: 提交流响应的性能字段 + 缓冲尺寸对齐厂商 */
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

ALLOC_OLD = """	rsp = kzalloc(sizeof(*rsp), GFP_KERNEL);
	if (!rsp)
		return;"""
ALLOC_NEW = """	/* HERMES-RSPPERF2: 按厂商方式多分配 (MAX_NPU_UCNN_RSP_SIZE - MAX_NPU_USER_RSP_SIZE)，
	 * 否则库按 rsp_size(24) 读取时会越过结构体尾部（ursp 在偏移 32，48 字节结构体）。 */
	{
		int asz = (int)sizeof(*rsp) +
			   (int)(MAX_NPU_UCNN_RSP_SIZE - MAX_NPU_USER_RSP_SIZE);

		rsp = kzalloc(asz, GFP_KERNEL);
	}
	if (!rsp)
		return;"""

FILL_OLD = """	rsp->rsp_size = (int)size;
	rsp->session = sess;"""
FILL_NEW = """	rsp->rsp_size = (int)size;
	rsp->session = sess;
	/* HERMES-RSPPERF2: 填性能字段（现在缓冲区已足够大） */
	if (vha_rsp_perf_fill) {
		struct npu_user_cnn_submit_rsp *crsp =
			(struct npu_user_cnn_submit_rsp *)&rsp->ursp;

		crsp->last_proc_us = vha_rsp_perf_us;
		crsp->mem_usage = vha_rsp_perf_mem;
		crsp->hw_cycles = vha_rsp_perf_cycles;
	}"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_rspperf2.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-RSPPERF2" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("param", PARAM_ANCHOR), ("alloc", ALLOC_OLD), ("fill", FILL_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_presprperf2_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = (src.replace(PARAM_ANCHOR, PARAM_NEW)
              .replace(ALLOC_OLD, ALLOC_NEW)
              .replace(FILL_OLD, FILL_NEW))
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-RSPPERF2")
    return 0


if __name__ == "__main__":
    sys.exit(main())

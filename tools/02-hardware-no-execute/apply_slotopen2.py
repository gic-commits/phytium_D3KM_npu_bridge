#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HERMES-SLOTOPEN：每次 open() 复位响应序号（对齐"库每次执行任务从 1 重新编号"）。

依据（第八轮-29 实测）：
  把 slot 基准设为 6、step=1，清空 dmesg 后跑 sensevoice，实测第一次分配时
  `seq 已经是 3` ⇒ **在客户端推理开始之前已有 3 次 slot 分配发生**
  （服务启动/warm-up 阶段的推送）⇒ 推理阶段键整体偏移（推 9,10,11 而库期待 1,2,3）。

  会话指针在 warm-up 与正式推理间不变（reset_on_session 命中 0 次）⇒ 不能靠会话判定；
  **open() 是"新一次执行"的可靠切入点**（每个 worker 至少一次）。

实现要点：`vha_rsp_slot_seq` 与开关参数必须声明在 open() **之前**，
因此把两者的声明**前置**，并删掉后面的重复声明。

用法: apply_slotopen.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

# 1) 在 open() 前插入前置声明（含开关）
OPEN_ANCHOR = """static int phytium_npu_open(struct inode *inode, struct file *file)
{"""
PRE_DECL = """/* HERMES-SLOTOPEN: 供 open() 使用的前置声明（定义在其后，此处前置声明） */
static atomic_t vha_rsp_slot_seq;

/* HERMES-SLOTOPEN: open() 时复位序号（每个 worker 至少一次） */
static int vha_slot_reset_on_open = 1;
module_param(vha_slot_reset_on_open, int, 0644);
MODULE_PARM_DESC(vha_slot_reset_on_open, "reset response slot sequence on device open()");

static int phytium_npu_open(struct inode *inode, struct file *file)
{"""

# 2) open() 入口插入复位
SESSION_OLD = """	struct phytium_npu_session *sess = phytium_npu_session_create(npudev->dev);"""
SESSION_NEW = """	/* HERMES-SLOTOPEN: 新连接 = 新的一次执行 ⇒ 响应序号归零 */
	if (vha_slot_reset_on_open) {
		atomic_set(&vha_rsp_slot_seq, 0);
		pr_info("[VHA-SLOTOPEN] ★open() ⇒ 序号归零\\n");
	}
	struct phytium_npu_session *sess = phytium_npu_session_create(npudev->dev);"""

# 3) 原定义改为带初值的定义（保留唯一带初始化器的定义）
DEF_OLD = """static atomic_t vha_rsp_slot_seq = ATOMIC_INIT(0);"""
DEF_NEW = """/* HERMES-SLOTOPEN: 前置声明在此，此处给初始化值（C 允许 tentative + 定义） */
static atomic_t vha_rsp_slot_seq;"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_slotopen.py <uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()
    if "HERMES-SLOTOPEN" in src:
        print("[SKIP] 已打过")
        return 0
    for tag, old in (("open", OPEN_ANCHOR), ("session", SESSION_OLD), ("def", DEF_OLD)):
        n = src.count(old)
        print("[INFO] %s 锚点=%d (期望 1)" % (tag, n))
        if n != 1:
            print("[FAIL] %s 锚点不唯一 ⇒ 中止" % tag)
            return 3
    if check:
        print("[CHECK] 可打补丁")
        return 0
    bak = path + ".bak_preslotopen_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = (src.replace(OPEN_ANCHOR, PRE_DECL)
              .replace(SESSION_OLD, SESSION_NEW)
              .replace(DEF_OLD, DEF_NEW))
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-SLOTOPEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重放链保持同一 slot（不递增），用于「同一条响应重复投递、提高命中率」。
背景：实测库会先把响应读走，之后才注册该 slot 的等待项 ⇒ 早到的响应被丢弃，
      库回头等时已无货 ⇒ 无限等。把同一条（同 slot）响应隔 vha_rsp_replay_ms
      重复推几次，可覆盖注册前后的窗口。

用法: apply_replaysame.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """		d->replay--;
		d->slot += (u32)vha_rsp_slot_step;
		if (vha_rsp_slot_max > 0 && d->slot > (u32)vha_rsp_slot_max)
			d->slot = 1;"""

NEW = """		d->replay--;
		/* HERMES-REPLAYSAME: 默认保持同一 slot 重复推（覆盖「响应早于注册」的窗口）；
		 * 置 0 时退回旧的「每重放一次 slot 递增」行为。 */
		if (!vha_replay_keep_slot) {
			d->slot += (u32)vha_rsp_slot_step;
			if (vha_rsp_slot_max > 0 &&
			    d->slot > (u32)vha_rsp_slot_max)
				d->slot = 1;
		}"""

PARAM_ANCHOR = "static void vha_defer_work(struct work_struct *w)"
PARAM_DEF = """/* HERMES-REPLAYSAME: 重放时保持同一 slot（1=是，默认） */
static int vha_replay_keep_slot = 1;
module_param(vha_replay_keep_slot, int, 0644);
MODULE_PARM_DESC(vha_replay_keep_slot, "keep same slot when re-pushing (1=yes default)");

"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_replaysame.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-REPLAYSAME" in src:
        print("[SKIP] 已打过 HERMES-REPLAYSAME")
        return 0
    if src.count(OLD) != 1:
        print("[FAIL] 重放片段不唯一 (%d)" % src.count(OLD))
        return 3
    if src.count(PARAM_ANCHOR) != 1:
        print("[FAIL] 找不到 vha_push_response 函数头")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_prereplaysame_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)
    out = src.replace(OLD, NEW).replace(PARAM_ANCHOR, PARAM_DEF + PARAM_ANCHOR)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-REPLAYSAME")
    return 0


if __name__ == "__main__":
    sys.exit(main())

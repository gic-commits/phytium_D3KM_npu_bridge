#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PUSHONREAD 修正：只允许第一条立即推，之后一律由 read() 触发。
问题：原实现里 vha_push_response 在"无在途"时会立即调用 vha_rr_push_one()，
      而 submit 往往在 read() 之前到达 ⇒ 把下一条抢在延迟前推出去 ⇒ 仍然早到被丢。
      （实测：延迟改成 300/600/1200/2500ms 全无效，就是被这条抢跑路径掩盖。）

用法: apply_pushonread2.py <phytium_npu_uapi.c> [--check]
"""
import sys, shutil, time

OLD = """	if (vha_rsp_on_read) {
		vha_rr_ensure();
		mutex_lock(&vha_rr_lock);
		vha_rr_sess = sess;
		vha_rr_sid = sid;
		vha_rr_err = err_no;
		vha_rr_owed++;
		mutex_unlock(&vha_rr_lock);
		vha_rr_push_one();
		return;
	}"""

NEW = """	if (vha_rsp_on_read) {
		vha_rr_ensure();
		mutex_lock(&vha_rr_lock);
		vha_rr_sess = sess;
		vha_rr_sid = sid;
		vha_rr_err = err_no;
		vha_rr_owed++;
		first = !vha_rr_kicked;
		if (first)
			vha_rr_kicked = 1;
		mutex_unlock(&vha_rr_lock);
		/* HERMES-PUSHONREAD-FIX: 只有第一条立即推；其余一律等 read() 触发，
		 * 否则 submit 会抢在延迟前把下一条推出去（早到 ⇒ 被库丢弃）。 */
		if (first)
			vha_rr_push_one();
		return;
	}"""

FLAG_ANCHOR = "static int vha_rr_inited;"
FLAG_NEW = """static int vha_rr_inited;
static int vha_rr_kicked;		/* 是否已经推过第一条 */"""


def main():
    if len(sys.argv) < 2:
        print("用法: apply_pushonread2.py <phytium_npu_uapi.c> [--check]")
        return 2
    path = sys.argv[1]
    check = "--check" in sys.argv
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if "HERMES-PUSHONREAD-FIX" in src:
        print("[SKIP] 已打过 PUSHONREAD-FIX")
        return 0
    n1 = src.count(OLD)
    n2 = src.count(FLAG_ANCHOR)
    print("[INFO] 锚点: push_branch=%d flag=%d (期望 1/1)" % (n1, n2))
    if n1 != 1 or n2 != 1:
        print("[FAIL] 锚点不唯一，中止")
        return 3
    if check:
        print("[CHECK] 可以打补丁")
        return 0

    bak = path + ".bak_prepushonread2_" + time.strftime("%m%d_%H%M")
    shutil.copy2(path, bak)
    print("[BAK ] %s" % bak)

    out = src.replace(FLAG_ANCHOR, FLAG_NEW)
    out = out.replace(OLD, NEW)
    # 需要局部变量 first
    out = out.replace("static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)\n{\n\tstruct vha_defer_ctx *d;",
                      "static void vha_push_response(struct phytium_npu_session *sess, u32 sid, int err_no)\n{\n\tstruct vha_defer_ctx *d;\n\tint first;")
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)
    print("[OK  ] 已打补丁：HERMES-PUSHONREAD-FIX")
    return 0


if __name__ == "__main__":
    sys.exit(main())

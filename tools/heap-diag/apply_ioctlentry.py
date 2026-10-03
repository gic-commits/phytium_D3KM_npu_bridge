#!/usr/bin/env python3
# 在 ioctl 入口第一行加无条件 pr_err，验证驱动是否收到所有 ioctl
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-IOCTL-ENTRY" in src:
    print("已打过补丁"); sys.exit(0)
shutil.copy2(U, T + "phytium_npu_uapi.c.bak34_preentry")

old = """static long phytium_npu_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
\tstruct phytium_npu_session *sess = file->private_data;
\tstruct phytium_npu_dev *npu = sess->npu_dev;
\tint retval = 0;

\tif (!sess)
\t\treturn -EINVAL;"""
new = """static long phytium_npu_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
\tstruct phytium_npu_session *sess = file->private_data;
\tstruct phytium_npu_dev *npu;
\tint retval = 0;

\t/* HERMES-IOCTL-ENTRY: 无条件记录每个 ioctl（验证驱动是否收到） */
\tpr_err("[VHA-IOCTL-ENTRY] cmd=%#x nr=%u sess=%p\\n",
\t       cmd, cmd & 0xff, sess);
\tif (!sess)
\t\treturn -EINVAL;
\tnpu = sess->npu_dev;"""
if old not in src:
    print("锚点未找到"); sys.exit(1)
src = src.replace(old, new, 1)
open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-IOCTL-ENTRY")

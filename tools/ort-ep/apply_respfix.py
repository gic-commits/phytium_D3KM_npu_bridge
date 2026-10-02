#!/usr/bin/env python3
# 在 18:00 基线的 uapi.c 上，只插入"响应 +2 回填"这一处（最小改动）
import shutil, sys, re
P = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/phytium_npu_uapi.c"
src = open(P, encoding="utf-8", errors="replace").read()

if "HERMES-RESP-FIX" in src:
    print("已插入过，跳过"); sys.exit(0)

anchor = "\tret = copy_to_user(buf, &rsp->ursp, ret_len);"
if anchor not in src:
    print("锚点未找到")
    for i, l in enumerate(src.splitlines(), 1):
        if "copy_to_user(buf, &rsp->ursp" in l or "ret_len" in l:
            print(i, repr(l))
    sys.exit(1)

block = (
'\t/* HERMES-RESP-FIX: 库 libnpusession 的 GetVhaResponse 取响应 +2 处的 u16 当 task/事件 id,\n'
'\t * <=0 时直接构造 "Error reading response from VHA device." 并丢弃响应\n'
'\t * (池路径表现为 phydnnWaitForEvent 失败 / ORT 路径表现为 5s 超时)。\n'
'\t * 实测库只接受 1 或 4。回退=删掉本块。 */\n'
'\t{\n'
'\t\tu16 *ridp = (u16 *)&rsp->ursp;\n'
'\n'
'\t\tridp[1] = 1;\n'
'\t\tdev_info(npu->dev, "[VHA-RESPFIX] rsp[+2] <- 1\\n");\n'
'\t}\n'
)
shutil.copy2(P, P + ".bak17_prerespfix")
open(P, "w", encoding="utf-8").write(src.replace(anchor, block + anchor, 1))
print("已插入 HERMES-RESP-FIX，备份:", P + ".bak17_prerespfix")

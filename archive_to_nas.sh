#!/bin/bash
# 归档 GitHub 仓库 + 交接到 NAS，并输出校验信息
set -e
cd "$(dirname "$0")"
D="/tmp/nas_home/交换文件"
TODAY=$(date +%Y-%m-%d)

bash gen_files.sh > /tmp/gen_out.txt 2>&1
tail -3 /tmp/gen_out.txt

# 1) 打包（排除 .git）
tar czf "$D/phytium-d3000m-npu-github-repo_$TODAY.tar.gz" --exclude=.git -C "$(dirname "$(pwd)")" "$(basename "$(pwd)")"
echo "== tar: $(ls -la "$D/phytium-d3000m-npu-github-repo_$TODAY.tar.gz" | awk '{print $5}') 字节"

# 2) 未打包同步（对端可直接读文件）
rm -rf "$D/phytium-d3000m-npu-github-repo"
cp -R "$(pwd)" "$D/phytium-d3000m-npu-github-repo"
echo "== 目录同步: $(find "$D/phytium-d3000m-npu-github-repo" -type f | wc -l | tr -d ' ') 个文件"

# 3) 交接文档
cp -f ../HANDOVER-2026-09-27-npu-service.md "$D/"
cp -f ../HANDOVER-2026-09-27-npu-service.md ../round30_evidence/
echo "== 交接文档: $(ls -la "$D/HANDOVER-2026-09-27-npu-service.md" | awk '{print $5}') 字节"

# 4) 校验
echo "== 校验:"
md5 -q "../HANDOVER-2026-09-27-npu-service.md" 2>/dev/null | sed 's/^/   交接 md5 /' || true
md5 -q "$D/phytium-d3000m-npu-github-repo_$TODAY.tar.gz" 2>/dev/null | sed 's/^/   tar  md5 /' || true
md5 -q "patches/0001-vha-bridge.patch" 2>/dev/null | sed 's/^/   补丁 md5 /' || true
echo "== NAS 交换文件下与 NPU 相关的顶层项:"
ls "$D" | grep -iE "npu|handover|phytium" | head -12 | sed 's/^/   /'

#!/bin/bash
# 生成 FILES.md（文件清单 + 大小 + md5），并做敏感信息自检
# 用法: bash gen_files.sh
set -e
cd "$(dirname "$0")"
{
  echo "# 文件清单（脚本生成）"
  echo
  echo "生成时间：$(date '+%F %T %Z')　总文件数：$(find . -type f -not -name FILES.md | wc -l | tr -d ' ')　总体积：$(du -sh . | cut -f1)"
  echo
  echo "| 文件 | 字节 | md5 |"
  echo "|---|---|---|"
  find . -type f -not -name FILES.md | sed 's|^\./||' | sort | while read -r f; do
    printf '| `%s` | %s | %s |\n' "$f" "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")" "$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)"
  done
} > FILES.md
echo "FILES.md: $(wc -l < FILES.md | tr -d ' ') 行"

echo "--- 敏感信息自检（下面应无输出）---"
grep -rInE "SYNOLOGY|password|passwd|PRIVATE KEY|172\.22\.|2113111|token=" \
     --exclude-dir=.git --exclude=FILES.md . || echo "  (clean)"

echo "--- 最大的 5 个文件 ---"
find . -type f -not -name FILES.md -exec ls -la {} \; | sort -k5 -rn | head -5 | awk '{printf "  %8s %s\n", $5, $9}'

echo "--- 体积 ---"
du -sh . | cut -f1

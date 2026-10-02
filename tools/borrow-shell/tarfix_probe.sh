#!/bin/bash
echo "=== 1. tarfix 目录内容 ==="
ls -la /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/ 2>/dev/null
echo
echo "=== 2. sensevoice_new.tar 与现用 tar 的差异 ==="
cd /tmp && rm -rf tar_cmp && mkdir tar_cmp && cd tar_cmp
echo "--- 现用 tar 的 __internal_io_file__ ---"
tar -xf /opt/npu/model/sensevoice.tar ./__internal_io_file__ 2>/dev/null && cat ./__internal_io_file__
echo
echo "--- new tar 的 __internal_io_file__ ---"
tar -xf /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/sensevoice_new.tar ./__internal_io_file__ 2>/dev/null && cat ./__internal_io_file__
echo
echo "=== 3. 两个 tar 的条目数与大小对比 ==="
echo "  现用: $(tar -tf /opt/npu/model/sensevoice.tar 2>/dev/null | wc -l) 条"
echo "  new : $(tar -tf /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/sensevoice_new.tar 2>/dev/null | wc -l) 条"
echo
echo "=== 4. bak_io 与现用 tar 的 io 差异 ==="
tar -xf /opt/npu/model/sensevoice.tar.bak_io_20260929 ./__internal_io_file__ -O 2>/dev/null | head -20
echo
echo "=== 5. tarfix 里是否有说明文档 ==="
ls -la /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/*.md /data/usershare/AI编码项目/faster-whisper-NPU/tarfix/*.txt 2>/dev/null
find /data/usershare/AI编码项目/faster-whisper-NPU/tarfix -type f 2>/dev/null | head -10

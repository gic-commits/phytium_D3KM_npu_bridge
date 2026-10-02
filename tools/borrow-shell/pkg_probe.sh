#!/bin/bash
echo "=== 1. mobilenet.json（小，全看） ==="
cat /opt/npu/model/mobilenet.json
echo
echo "=== 2. mobilenet.params（32B） ==="
xxd /opt/npu/model/mobilenet.params
echo
echo "=== 3. mobilenet.tar 结构 ==="
tar -tvf /opt/npu/model/mobilenet.tar 2>/dev/null | head -20
echo
echo "=== 4. sensevoice.json 头部（前 40 行） ==="
head -40 /opt/npu/model/sensevoice.json
echo
echo "=== 5. sensevoice.tar 结构（前 20 条） ==="
tar -tvf /opt/npu/model/sensevoice.tar 2>/dev/null | head -20
echo
echo "=== 6. sensevoice.params 头 64 字节 ==="
xxd /opt/npu/model/sensevoice.params | head -4
echo
echo "=== 7. sensevoice.so 是什么（前 64 字节） ==="
xxd /opt/npu/model/sensevoice.so | head -4

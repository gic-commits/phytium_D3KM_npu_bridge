#!/bin/bash
# 构建 NPU 服务三件套：npusvc（守护）/ libnpuclient.a（客户端库）/ npu_cli（示例客户端）
set -e
CXX=${CXX:-g++}
INC="-I. -I/usr/include $(pkg-config --cflags opencv4)"
LIB="$(pkg-config --libs opencv4)"

$CXX -O2 -fPIC -c npuclient.cpp -o npuclient.o $INC
ar rcs libnpuclient.a npuclient.o
$CXX -O2 -o npu_cli npu_cli.cpp $INC libnpuclient.a $LIB -lpthread
$CXX -O2 -o npusvc npusvc.cpp $INC -L/usr/local/lib -lphyaiengine $LIB -lpthread -Wl,-rpath,/usr/local/lib
echo "构建完成:"
ls -l npusvc npu_cli libnpuclient.a | awk '{printf "  %-18s %8s B\n", $9, $5}'
ldd npusvc | grep -E "phyaiengine|opencv_core" | sed 's/^/  /'

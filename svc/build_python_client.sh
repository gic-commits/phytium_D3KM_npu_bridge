#!/bin/bash
# 构建 Python 客户端所需的动态库，并部署到 /opt/npu/{lib,python,include}
set -e
cd /dev/shm/nputest/svc
echo "== 构建 libnpuclient.so（含 opencv core/imgproc/imgcodecs）"
g++ -O2 -fPIC -shared -o libnpuclient.so npuclient.cpp \
    -I. -I/usr/include $(pkg-config --cflags opencv4) \
    $(pkg-config --libs opencv4) -lpthread
ls -la libnpuclient.so | awk '{print "   "$5" 字节"}'
echo "== 依赖检查:"; ldd libnpuclient.so | grep -E "opencv|not found" | sed 's/^/   /'

echo "== 部署到 /opt/npu"
sudo mkdir -p /opt/npu/lib /opt/npu/python /opt/npu/include /opt/npu/testdata
sudo cp -f libnpuclient.so /opt/npu/lib/
sudo cp -f npuclient.h /opt/npu/include/
sudo cp -f python/npu_client.py python/examples.py /opt/npu/python/
sudo cp -f /dev/shm/nputest/2.jpg /opt/npu/testdata/ 2>/dev/null || true
sudo chmod -R a+rX /opt/npu
ls -la /opt/npu/lib /opt/npu/python /opt/npu/include | sed 's/^/  /'

echo "== 冒烟：Python 客户端跑一遍示例"
cd /opt/npu/python
export NPU_SOCK=/run/npu/npu.sock NPU_SMOKE_IMG=/opt/npu/testdata/20210828122250_3b289.jpg \
       NPU_IMAGENET_IMG=/opt/npu/testdata/2.jpg
python3 examples.py 2>&1 | tail -30
echo "== 结束 STATUS: $(NPU_SOCK=/run/npu/npu.sock python3 -c "import npu_client as n;print(n.connect().status())" 2>&1 | tail -c 220)"

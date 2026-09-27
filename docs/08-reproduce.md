# 复现步骤（从裸机到服务）

> 目标：在你自己的 D3000M 机器上复刻出"5 模型跑通 + 多模型服务"。
> 全过程预计半天（不含厂商材料获取）。

## 0. 前置材料清单

| 材料 | 说明 | 本仓库是否包含 |
|---|---|---|
| deepin 开源驱动 `drivers/staging/phytium-npu` | 本项目内核侧基线（GPL-2.0） | ❌ 请自行获取（见 `UPLOAD-MANIFEST.md`）|
| 厂商运行时 `npu-ftn300-rt-lib-kylinv10`（2 月版） | 用户态闭源库 + `phyAIEngine.h` | ❌ 向厂商索取 |
| 厂商模型编译工具链镜像 | 生成 `.json/.params/.so/.tar` 模型包 | ❌ 向厂商索取 |
| 模型包 | yunet / yolov5s / scrfd / ResNet50 / ppocrv3_cls | ❌ |
| **本仓库** | 桥接补丁 + 服务/工具源码 + 脚本 | ✅ |

**基线核对**（确保你手上的上游文件与本补丁匹配）：

```
phytium-npu/phytium_npu_uapi.c   11260 B   md5 9112ba15693d38bafb784ba8e1aedaaa   ← 上游基线
phytium-npu/phytium_npu_uapi.c   48123 B   md5 acdff075f00d0b5ae3e182c02794ff78   ← 打补丁后（本项目）
```

## 1. 编译并加载内核驱动

```bash
# 把补丁打到内核源码树里（或直接把打好的 uapi.c 覆盖过去）
cd <kernel-src>/drivers/staging/phytium-npu
patch -p1 < <repo>/patches/0001-vha-bridge.patch      # 或者 cp <repo>/src/phytium_npu_uapi.c .

# 只编译模块（不装载；受"不要随意 rmmod/insmod"约束时这一步很关键）
make -C /lib/modules/$(uname -r)/build M=$PWD CONFIG_PHYTIUM_NPU=m modules

# 装载（VHA 兼容模式）
sudo modprobe phytium_npu vha_sim_mode=0 vha_settle_ms=50
sudo modprobe phytium_npu_platform
dmesg | tail -20      # 应看到 probe 命中 PHYT0050、/dev/npu0 建立
ls -l /dev/npu0
```

**模块参数速查**（都可运行时 `echo` 改）：

| 参数 | 默认 | 作用 |
|---|---|---|
| `vha_sim_mode` | 0 | 1 = 只模拟不碰硬件（排查用；**此时不算跑通**）|
| `vha_settle_ms` | 50 | 提交后等待输出稳定的时间 |
| `vha_use_repeat` | 1 | **必须保持 1**（官方内存安全缺陷，置 0 会 UAF，只能硬重启）|
| `vha_int_fixup` | 0 | 交付补齐的**内核侧**实验开关（仅联调取证，生产用用户态 compat）|
| `vha_reset_each_run` | 0 | 1 = 每次提交都复位引擎（排查用）|

⚠️ **`rmmod/insmod` 前先确认没有别的进程在跑 NPU**（设备单实例），否则你会把"两个实例互抢"误判成模型问题。

## 2. 编译运行工具，先跑通一个模型

```bash
cd <repo>/tools
g++ -O2 npu_det.cpp -o npu_det -I/usr/include $(pkg-config --cflags opencv4) \
    -L/usr/local/lib -lphyaiengine $(pkg-config --libs opencv4) -lpthread -Wl,-rpath,/usr/local/lib

# 用法: npu_det <模型前缀> <图片> <W> <H> <norm:0|1|2> <outbytes|0=auto> [dump前缀]
LD_LIBRARY_PATH=/usr/local/lib ./npu_det /path/model/yunet_npu /path/face.jpg 112 112 0 0 /tmp/out
#  norm=0 裸 0-255（yunet）/ 1 = /255（yolov5s）/ 2 = (x-127.5)/128（scrfd）
#  outbytes=0 ⇒ 按 total()*elemSize() 自动定长（库返回的 Mat 可能 rows/cols=-1）
```
检查点：`init_graph -> 0`、`execute_graph -> 0`、输出文件非零字节数合理（见 `docs/06` §四）。

## 3. 确认"算得对"（L4）

```bash
python3 <repo>/scripts/decode_y5.py <dump_0.bin>          # yolov5s
python3 <repo>/scripts/decode_scrfd.py <dump_*.bin>       # scrfd
# yunet：按 docs/06 的 707 prior + 2 类 softmax 解码，期望 1 张脸、IoU≈0.939
```
⚠️ yunet 的 conf 是 **pre-softmax logits**，不施加 softmax 会误检十几张（见 `docs/06` §二）。

## 4. 起服务（进程池）

```bash
cd <repo>/svc
bash build.sh                                  # npusvc（单进程版）/ npu_cli / libnpuclient.a
g++ -O2 -o npuworker npuworker.cpp -I/usr/include $(pkg-config --cflags opencv4) \
    -L/usr/local/lib -lphyaiengine $(pkg-config --libs opencv4) -lpthread -Wl,-rpath,/usr/local/lib
g++ -O2 -o npusvc_pool npusvc_pool.cpp -lpthread

./npusvc_pool --sock /tmp/npu.sock --models /path/model/ \
              --worker ./npuworker --worker-timeout-ms 30000 --queue 64 &
./npu_cli status
./npu_cli face yunet_npu /path/face.jpg 112 112 0     # 期望 检出 1 张脸 score≈0.9553
./npu_cli infer yolov5s /path/img.jpg 640 640 1 /tmp/y5   # 期望 8568000 B
```

**后处理元数据**：`<模型名>.meta.txt` 声明 `<输出下标> <引擎页号> <op>`（例 `1 93 softmax2`）。
页号换机器/换工具链会变，用桥接的 `[VHA-ALLOC] page=… size=…` + 缓冲名字重新探一次。

## 5. 跑验收

```bash
bash svc_accept3.sh        # 五模型轮换 + 同模型连跑 + 并发 + STATUS（**建议 detached 跑**）
bash svc_smoke.sh          # 冒烟自检：判活 + 真跑一帧 + 判数值（退出码分级，可 cron）
```

**detached 姿势**（远程长任务必备，避免 ssh 被切断时把脚本一起带走）：
```bash
ssh host 'cd /path/svc; nohup setsid bash svc_accept3.sh > /tmp/acc.out 2>&1 </dev/null & echo started'
ssh host 'tail -40 /tmp/acc.out'
```

## 6. 正式部署（systemd）

```bash
sudo cp svc/npusvc.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now npusvc
systemctl status npusvc --no-pager
```
⚠️ 二进制与模型请从 `/dev/shm` 挪到持久盘（unit 里示例为 `/opt/npu`）。

## 7. 可移植性注意（换平台/换内核时必读）

| 项 | 注意 |
|---|---|
| 寄存器变体 | 平台/ACPI 走 `leopard`（基址 0x10800），PCI 变体是 0x10000。判法：`grep '#include.*reg\.h' *_platform.c` |
| 内核浮点 | arm64 麒麟内核 `-mgeneral-regs-only` ⇒ **内核里不能出现 float**（激活只能放用户态）|
| uapi 差异 | 厂商库的结构体可能比官方头**少 12 字节**（`stream_off/stream_fd/stream_size`）；偏移必须用真机描述符 hexdump 反解 |
| glibc 版本 | 4 月版运行时要求 `GLIBC_2.33`，麒麟 V10 SP1 装不上 ⇒ 用 2 月版 |
| 设备名 | 库期望 `/dev/phy_npu%d`，本桥接建 `/dev/npu0`；如需可软链，但 ABI 一致性才是关键 |
| 单实例 | 驱动按会话独占；跨进程 mmap 设备页会 `-19 ENODEV`（读缓冲必须在持有会话的进程内）|

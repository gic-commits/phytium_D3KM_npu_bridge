# 飞腾 D3000M (FTN300) 内置 NPU — 麒麟 V10 驱动桥接与推理服务

把 **飞腾 D3000M 内置 NPU** 在 **麒麟 V10 SP1 / 长城 N90F3** 上从"完全没有驱动"做到
**5 个模型端到端跑通、多应用可共享的推理服务**。

本项目解决的现实问题：
官方 BSP 里与 NPU 配套的**内核态 VHA 驱动缺失**，而厂商提供的用户态运行时（`npu-ftn300-rt-lib-*`）
是**闭源二进制**、只认一套 VHA ioctl 接口。本仓库给出：
① 用开源驱动顶上并做 **ABI 反向桥接**的完整方法；② 桥接过程中发现的**厂商库真实缺陷与其绕过**；
③ 一个**进程池式推理服务**（多模型轮换不挂死），让多应用共享这台机器的 NPU。

> 复现所需的**厂商材料**（运行时库、模型编译工具链镜像、模型包）**不随仓库分发**，见
> [`UPLOAD-MANIFEST.md`](UPLOAD-MANIFEST.md) 里给出的获取途径与链接。

---

## 一、成果（真机实测）

| 项目 | 结果 |
|---|---|
| 端到端推理 | **5 个模型全部跑通**：yunet（人脸）/ yolov5s / scrfd / ResNet50 / ppocrv3_cls，`oops=0` |
| 正确性金标 | yunet 与官方 ONNX 参照一致：`IoU = 0.939`（NPU 出框 `(24.6,21.0,62.2,77.9)`、score `0.9553`） |
| 单次推理耗时 | **~0.42 s/次**（同进程热进程，含厂商库全部开销） |
| 跨模型切换开销 | **+0.1 ~ 0.35 s**（进程池：yunet 0.52–0.58 s、yolov5s 0.80–0.81 s，含进程启动+建图+推理） |
| 多模型服务 | 轮换 5 模型连续 **20 个请求全绿**；同模型连跑 12 次稳定 414–440 ms 且不重建引擎 |
| 稳定性 | 全程 `oops=0`；桥接修复后无"偶发写回失败"（修复前 ~40% 失败率） |
| 服务验收（六项全通过） | 跨模型轮换 / 同模型连跑 / **并发两客户端** / **worker 超时击杀** / **外部击杀自愈** / **systemd 部署 + 冒烟自检** |

**一句话**：从零到"多应用可用的 NPU 服务"，验证路径 = 开源驱动顶替 → VHA ABI 桥接 →
**桥接自身 6 处缺陷逐一定位修复** → 厂商库交付缺陷在**用户态**补齐 → 因库不支持同进程多图，
服务化采用**每模型一进程**。

---

## 二、适用对象与前置条件

- 硬件：飞腾 D3000M（`ACPI PHYT0050`，内置 NPU，"x100" 变体）
- 系统：麒麟 V10 SP1（内核 5.4.18-168，aarch64）；本机为长城 N90F3
- 需要你自备：deepin 开源驱动源码 `drivers/staging/phytium-npu`、厂商运行时
  `npu-ftn300-rt-lib-kylinv10`、厂商模型编译工具链镜像（见 `UPLOAD-MANIFEST.md`）
- 若你的平台/内核不同，请先读 [`docs/08-reproduce.md`](docs/08-reproduce.md) 的可移植性说明

---

## 三、目录导航

| 文件 | 内容 | 谁该看 |
|---|---|---|
| [`docs/01-journey.md`](docs/01-journey.md) | **从零到跑通的完整历程**：每一轮的假设、实测、被推翻的结论 | 想少走弯路的人，**先读这篇** |
| [`docs/02-architecture.md`](docs/02-architecture.md) | 分层架构与数据流（硬件/开源驱动/VHA 桥接/厂商库/用户态 compat/服务） | 要动手改代码的人 |
| [`docs/03-bridge-fixes.md`](docs/03-bridge-fixes.md) | 桥接（内核侧）**6 处缺陷**的定位与修法，含代码级要点 | 正在做类似桥接的人 |
| [`docs/04-response-protocol-and-multigraph.md`](docs/04-response-protocol-and-multigraph.md) | 提交/响应线格式、`sid` 匹配机制、**为什么同进程多图必挂** | 遇到"跑一个模型正常、换模型挂死"的人 |
| [`docs/05-service-pool.md`](docs/05-service-pool.md) | 进程池推理服务：拓扑、协议、**四个真机才暴露的坑**、验收数据 | 要做服务化/多应用共享的人 |
| [`docs/06-verification-and-golden.md`](docs/06-verification-and-golden.md) | 验收分层 L1–L4、金标口径（含 `pre-softmax logits` 陷阱） | 要证明"算得对"的人 |
| [`docs/07-pitfalls.md`](docs/07-pitfalls.md) | 踩坑速查（20 条，按症状索引） | 排障时当手册翻 |
| [`docs/08-reproduce.md`](docs/08-reproduce.md) | 复现步骤：装驱动 → 编译 → 跑模型 → 验收 | 要复刻的人 |
| [`docs/09-model-compile-pipeline.md`](docs/09-model-compile-pipeline.md) | **用自己的模型编出可部署包**（`model_build`/`npu_compiler`）：两份配置文件的 schema、必需修复、错误对照表 | 想跑厂商预编译包之外的模型的人（**ASR/自定义模型必读**） |
| [`UPLOAD-MANIFEST.md`](UPLOAD-MANIFEST.md) | 本仓库包含什么、**不含什么、去哪拿** | 所有人 |
| [`NOTICE.md`](NOTICE.md) | 第三方材料与许可证边界 | 分发前必看 |

代码：
- `src/` — 我们对开源内核驱动的修改（**VHA 兼容桥接**主体，GPL-2.0）
- `svc/` — 推理服务（单进程版 + **进程池版**）、客户端库/示例、验收脚本、systemd unit
- `tools/00-model-compile/` — **自编模型包模板**（容器内编译脚本 + io.json/test.json 示例 + 校准数据生成器）
- `tools/` — 自建最小运行器 `npu_det`/`npu_gen`、页级缓冲读取 `npu_peek`（破案关键工具）、
  寄存器快照 `regsnap.py`、解码器 `decode_y5.py`/`decode_scrfd.py`
- `scripts/` — 取证脚本（ELF 字符串/反汇编、MBS 容器解析、全 0 CRC 探针等）

---

## 四、快速开始（已装好驱动的机器）

```bash
# 1) 编译服务与运行器（需厂商头/库：phyAIEngine.h + libphyaiengine.so）
cd svc && bash build.sh                 # 生成 npusvc / npu_cli / libnpuclient.a
g++ -O2 -o npuworker npuworker.cpp -I/usr/include \
    $(pkg-config --cflags opencv4) -L/usr/local/lib -lphyaiengine \
    $(pkg-config --libs opencv4) -lpthread -Wl,-rpath,/usr/local/lib
g++ -O2 -o npusvc_pool npusvc_pool.cpp -lpthread

# 2) 起服务（进程池：每个模型一个 worker，切模型即换进程）
./npusvc_pool --sock /tmp/npu.sock --models /path/to/model/ \
              --worker ./npuworker --worker-timeout-ms 30000 &

# 3) 跑一帧并判数值
./npu_cli face yunet_npu /path/to/face.jpg 112 112 0
#   期望: 检出 1 张脸 score≈0.9553
```

Python（应用侧推荐）：

```python
import sys; sys.path.insert(0, "/opt/npu/python")
import npu_client as npu
with npu.connect() as c:                       # 默认 $NPU_SOCK 或 /tmp/npu.sock
    outs  = c.infer_image("yunet_npu", "/opt/npu/testdata/a.jpg", 112, 112, norm=0)
    faces = c.detect_yunet("yunet_npu", "/opt/npu/testdata/a.jpg", 112, 112, 0)
    print(faces[0]["box"], faces[0]["score"])  # → (24.6, 21.0, 62.2, 77.9) 0.9553
```
（Python 侧只依赖 numpy：图像预处理在 C++ 客户端库里完成，见 `docs/05` §五·补）

**首次接触本项目请务必先读 [`docs/07-pitfalls.md`](docs/07-pitfalls.md)** —— 里面每一条都是真机上花掉
数小时才定位的，其中多数会伪装成"硬件问题"。

---

## 五、许可

- `src/`：派生自开源内核驱动（Linux kernel，**GPL-2.0**），对本仓库该目录的修改同样按 **GPL-2.0** 分发。
- `svc/`、`tools/`、`scripts/`、文档：**MIT**（见 `NOTICE.md`）。
- 仓库**不含**任何厂商专有二进制/模型/镜像，详见 `UPLOAD-MANIFEST.md`。

# 上传清单：本仓库包含什么、不含什么、去哪拿

> 原则：**只分发我们自己写的东西**。厂商的闭源二进制、模型包、系统镜像、工具链镜像**一律不进仓库**，
> 只写清获取途径；别人拿到本仓库 + 厂商材料即可复刻。

## 一、本仓库包含（可自由分发）

| 路径 | 内容 | 许可 |
|---|---|---|
| `patches/0001-vha-bridge.patch` | **对上游内核驱动 `phytium_npu_uapi.c` 的完整补丁**（VHA 桥接 + 完成判定 + 打点，1216 行 / +1137 −4） | GPL-2.0 |
| `src/phytium_npu_uapi.c` `.h` | 打补丁后的成品文件（可直接替换；便于看不懂 diff 的人） | GPL-2.0 |
| `svc/npuworker.cpp` | 进程池 worker：独占设备、单模型、元数据后处理 | MIT |
| `svc/npusvc_pool.cpp` | supervisor：队列/优先级/超时/换进程（**推荐部署形态**）| MIT |
| `svc/npusvc.cpp` | 单进程版服务（历史版本，A/B 对照与回退用）| MIT |
| `svc/npuclient.{h,cpp}` `svc/npu_cli.cpp` | 客户端库（张量级/图像级）+ 示例 CLI | MIT |
| `svc/build.sh` `svc/*.sh` `svc/npusvc.service` | 构建、验收（`svc_accept*.sh`）、冒烟（`svc_smoke.sh`）、systemd unit | MIT |
| `svc/libvha_tap.c` | **LD_PRELOAD 探针**（ioctl/read/write 真值抓取，定位"响应匹配"类故障的利器）| MIT |
| `tools/npu_det.cpp` `npu_gen.cpp` | 自建最小运行器（不依赖厂商 demo 的 GUI 依赖）| MIT |
| `tools/npu_peek.cpp` | 同进程内按页号读设备缓冲（**破案关键工具**）| MIT |
| `tools/regsnap.py` `vhadump.c` | 寄存器快照 / 缓冲 dump | MIT |
| `tools/decode_y5.py` `decode_scrfd.py` | 按厂商后处理源码复刻的解码器 | MIT |
| `scripts/*.py` `*.sh` | 取证工具箱（ELF 字符串/反汇编定位、MBS 容器解析、全 0 CRC 探针等）| MIT |
| `docs/*.md` | 全部文档（历程/架构/桥接修复/协议/服务/验收/踩坑/复现/**自编模型包流程**）| CC-BY-4.0（或与仓库一致，按需）|
| `docs/09-model-compile-pipeline.md` | **用自己的模型编出可部署包**：`io.json`/`test.json` 两份配置文件的 schema（实测逆向）、`/home/lib64` 必需修复、错误信息对照表、打包结构与部署陷阱、数值核验口径 | CC-BY-4.0 |
| `tools/00-model-compile/` | 编译脚本模板 `run_build.template.sh`（已内含必需修复）+ 图像/张量两类 io.json·test.json 示例 + `gen_calib.py`（原始张量校准数据生成，非图像模型用） | MIT |
| `python/npu_client.py` `python/examples.py` | Python 客户端（ctypes，**只依赖 numpy**）+ 示例（图像→张量、图像级人脸、分类、纯张量） | MIT |

## 二、**不含**（体积大或属他人专有）—— 获取途径

| 材料 | 为什么不进仓库 | 获取途径 |
|---|---|---|
| 厂商运行时 `npu-ftn300-rt-lib-kylinv10`（`.deb`） | 闭源专有；且版本敏感（4 月版要 `GLIBC_2.33`，麒麟 V10 SP1 装不上，**须用 2 月版**）| 向**飞腾/整机厂商**索取；或从下面的工具链镜像里取 |
| 厂商模型编译工具链 **Docker 镜像**（镜像名 `npu-ftn300-tools`） | 数 GB 级；本项目仅在 NAS 侧以只读方式使用 | 向厂商索取（本项目**不转发**）；镜像内含未 strip 的 `libphydnn.so`、`model_build`/`npu_compiler`、算子映射 csv，对逆向很有价值 |
| 模型包（yunet / yolov5s / scrfd / ResNet50 / ppocrv3_cls：`.json/.params/.so/.tar`）| 厂商编译产物、含权重 | 用上面的工具链自己编译，或向厂商索取 |
| OS 镜像（麒麟 V10 SP1 / deepin 等） | 与项目无关的分发 | 走发行版官方渠道 |
| deepin 开源驱动完整源码树 | 属上游内核代码，避免重复分发 | 取你所处发行版/内核源码里的 `drivers/staging/phytium-npu`；**本项目使用的基线快照已归档在内部 NAS**，md5 见 `docs/08-reproduce.md` §0 |
| 金标参照资产（官方 ONNX、厂商测试图、`synset_words.txt`）| 第三方许可不明 | 见 `docs/06` 的取法（官方模型库 / 厂商 demo 包） |

## 三、上传前的自检

1. `patches/0001-vha-bridge.patch` 能干净应用到基线（`patch -p1 --dry-run`）；
2. `src/phytium_npu_uapi.c` 的 md5 = `acdff075f00d0b5ae3e182c02794ff78`（48123 B）；
3. 仓库内**不含**任何 `.so`（厂商运行时）、`.deb`、模型 `.tar/.params`、镜像 tar；
4. 仓库内**不含**凭据（NAS 口令、SSH 私钥、设备 IP 白名单等）——上传前 grep 一遍 `password|passwd|PRIVATE KEY|token`；
5. `docs/` 里的路径若含内部主机名/IP，按需脱敏（示例里用 `/path/...`）。

## 四、建议的上传方式

```bash
cd github_repo
git init && git add -A && git commit -m "feat: D3000M NPU VHA bridge, inference service and docs"
# 发布前建议先私有仓库跑一遍 CI（至少做 patch 可用性 + 脚本 shellcheck）
```

## 五、本仓库不解决的问题（先看这里再提 issue）

- **厂商库不支持同进程多图**（`sid` 撞车）⇒ 多模型必须走进程池（`docs/04`、`docs/05`）；
- 模型转换/量化**不在本仓库范围**（用厂商工具链）；
- 本仓库的桥接**只覆盖已验证的 VHA 命令子集**（属性/分配/映射/SET_BUF/SYNC_BUF/提交/取消），
  新模型若触发其他命令，需按 `docs/03` 的方法继续补；
- 文件清单（`FILES.md`）由脚本生成，README 里的行数与大小以该文件为准。

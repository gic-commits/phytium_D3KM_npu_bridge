# 推理服务：进程池形态（supervisor + 每模型一个 worker）

> 适用前提：**闭源用户态库 + 单实例设备**（驱动按会话独占），且库**不支持同进程多图/多模型**
> （原因见 `docs/04`）。若你的库支持多图共存，本形态仍可用，但不是必需。

## 一、拓扑

```
client(s) ──unix socket──▶ supervisor（只做排队/优先级/超时/转发；**绝不碰设备、绝不 init_graph**）
                              │  管道（帧协议：首行 + 文本头 k=v\n + 二进制载荷）
                              └──▶ worker（独占 /dev/npu0 + 厂商库；**一个模型一个进程**）
```

- **切模型 = 回收旧 worker + 拉起新 worker**；同一时刻**只有一个 worker 存活**（设备独占）。
- supervisor 若自己也 `init_graph`，它立刻变成一个"多图进程"，把刚绕过的缺陷重新踩一遍。
- 对客户端的协议与单进程版**逐字一致** ⇒ 客户端零改动。

## 二、为什么不是"单进程多引擎"

实测：单进程内先 yunet 再 yolov5s ⇒ **第 2 个模型永久挂死**；"切模型时销毁旧引擎"**无效**。
⇒ 隔离边界必须是进程。另一方面，**每模型一进程也天然满足"设备独占"**，
所以池化在这里不是折中，而是与约束一致的最简形态。

## 三、四个真机才暴露的坑（都已加固）

### ① 厂商库往 stdout 打印 ⇒ 污染协议通道（协议绝不能挂在 fd1 上）
库启动会往 **stdout** 打 `INFO: NPU clock:800000 [kHz]`、`[Graph Phytium RUN][INFO] Loading xxx.json`、
`get shape0:707 …`。若 worker 的协议通道就是 fd1 ⇒ supervisor 读到的首行不是帧头 ⇒
报 **"worker 响应格式错"**（而单进程版从没这问题：那时 stdout 是日志文件）。

**修法**：worker 启动时先 `dup(0)/dup(1)` 到高位 fd（`g_in_fd/g_out_fd`），再把
**0 → /dev/null、1 → 日志文件** 让给库；协议读写只走高位 fd。库的噪音仍完整留档，便于排障。

### ② `SIGCHLD=SIG_IGN` 与显式 `waitpid` 冲突
设了它之后子进程被内核自动收尸 ⇒ `waitpid()` 立刻返回 `ECHILD` ⇒ 回收逻辑**误判"已停"**
⇒ 新旧 worker **可能同时存活并抢设备**（症状又变回"偶发卡死"，极难查）。
**修法**：不要设 `SIGCHLD=SIG_IGN`；自己 `waitpid` 回收（优雅 `QUIT` → 800 ms → `SIGTERM` → `SIGKILL`）。

### ③ "队列超时"判据不能拿序号当时间戳
`j->enq = ++g_seq;`（1,2,3…）却与 `now_ms()`（真实时间）相减 ⇒ 差值恒为天文数字 ⇒
**每个作业都被立刻判"timeout in queue"**。
**识别特征**：服务起来了、但所有请求**秒失败**、`SWITCHES=0`（worker 从未启动）、
`TIMEOUTS == 请求数`。
**修法**：**入队时间戳与序号分两个字段**（`enq = now_ms()` 用于超时判定；`seq = ++g_seq` 只用于日志）。
泛化：**任何"计数/序号"都不要参与时间比较**。

### ④ 向挂死 worker 写大数据会永久阻塞 supervisor
管道缓冲写满后 `write()` 阻塞在工作线程 ⇒ **整个服务失去响应**（所有客户端一起卡），
比"单个请求失败"严重得多。
**修法**：**管道读写都带超时**（`poll(POLLOUT/POLLIN)` + 200 ms 步进 + 总超时）；超时即 `SIGKILL` 并回收
⇒ 把"库挂死"转成**可观测错误**（`status=14` / `WORKER_TIMEOUTS++`）+ 下次请求自动换新进程。

配套参数：`--worker-timeout-ms`（响应/写超时）、`--idle-kill-ms`（空闲回收，把设备让给别的工具）、
`--queue`、`--timeout-ms`（队列超时）。

## 四、协议与可观测面

- 帧格式：`NPU1 <op|status> <hdrlen> <payloadlen>\n` + 文本头 + 二进制载荷；`op = LOAD | INFER | STATUS | QUIT`。
- supervisor **原样透传** worker 的响应头与载荷（本例 `COUNT/BYTESi/SHAPEi/MSG`），不做二次解释。
- `STATUS` 暴露池状态：`SWITCHES`（切了几次模型）/ `WORKER_TIMEOUTS` / `WORKER_PID` / `WORKER_MODEL`
  / `REQS` / `ERRS` / `TIMEOUTS` —— 这是"池是否按预期换进程"的唯一可观测面。
- 单工作线程串行执行 + 优先级队列（0/1/2，同级 FIFO）+ 队列超时；worker 另有独立响应超时。
- 客户端接口（`libnpuclient`）：
  `npu_infer_ex(model, in, shape[8], ndim, dtype, prio, timeout, out[], max)` —— **张量级通用主路径**
  （**语音/ASR 也走这条**：输入 `[1,80,T]` mel、输出 token logits，别套图像级接口）；
  `npu_detect_yunet(...)` —— 图像级**薄封装**（客户端做预处理与解码）。
  ⚠️ 图像级**不可**当作通用接口：不同模型的预处理/后处理口径完全不同（见 `docs/06`）。

## 五、验收（实测数据）

**已通过**
| 用例 | 结果 |
|---|---|
| 编译 | `npuworker` / `npusvc_pool` **0 error** |
| 冒烟 = **原来必挂的序列**（yunet→yolov5s→yunet） | 全绿：yunet 1 张脸（与金标一致）；yolov5s `8568000 B shape=[1,25200,85] 非零 4577803`，677 ms；再跑 yunet 逐位一致；`REQS=3 SWITCHES=3 TIMEOUTS=0 WORKER_TIMEOUTS=0 oops=0` |
| 五模型轮换 + 连跑 | `REQ#1..#20 全 ok`（yunet/yolov5s/scrfd/Resnet50/ppocrv3_cls）|
| 同模型连跑 12 次 | 414–440 ms，**期间零模型切换**（worker 复用生效）|
| 跨模型切换成本 | yunet 0.52–0.58 s/次、yolov5s 0.80–0.81 s/次（含进程启动+建图+推理）|

**已完成（17:00 收口，全部真机通过）**
| 用例 | 结果 |
|---|---|
| **并发（两客户端同时）** | ✅ yunet + yolov5s 并发 `rc=0`；`[req#2] yunet ok 413 ms` → 切换 → `[req#3] yolov5s ok 782 ms`；并发中 worker 空闲在 `pipe_wait` ⇒ **上一次的 `-1=NPU_E_SOCKET` 失败确认为"前次被 timeout 杀掉的残留进程/异常关闭的 NPU 会话"，干净起步即正常** |
| **超时击杀（确定性）** | ✅ `--worker-timeout-ms 50` 逼出：`★响应超时(库可能挂死) ⇒ 击杀 pid=…（下次自动换新进程）` + `status=14`；第 2 次自动换新 worker；`WORKER_TIMEOUTS=2` |
| **外部击杀 → 自愈** | ✅ `kill -9` worker 后下一请求：日志 `调用失败(写请求失败(worker 已死)) ⇒ 重启并重试一次` → 新 worker → **成功 449 ms** |
| **systemd** | ✅ unit 安装并 `start` → active；**经 `/run/npu/npu.sock` 冒烟 `OK / 1 张脸 score=0.9553 / 退出码 0`**；`is-enabled=disabled`（故意不 enable）；`stop` 后残留 0/0 |
| **冒烟脚本** | ✅ `svc/svc_smoke.sh`：判活 + 真跑一帧 + 判数值 + 报 `ERRS/WORKER_TIMEOUTS`，退出码分级；支持 `NPU_SOCK` |

**剩余工程债**：正式部署把二进制与模型从 `/dev/shm`（tmpfs，重启即丢）挪到持久盘（unit 示例 `/opt/npu`）。
**重启后恢复**：驱动会**自动以 `sim=1` 加载**（模拟，不碰硬件）——`vha_sim_mode` **运行时可写**，
`echo 0 > /sys/module/phytium_npu/parameters/vha_sim_mode` 即切真硬件，**无需 rmmod/insmod**；
工作区从持久盘 `nputest_ws_*.tar.gz` 还原后重新编译即可。

## 五·补 交付面：Python 客户端 + 持久盘部署（2026-09-27 晚实测）

### ① Python 客户端（`svc/python/npu_client.py`，ctypes，**只依赖 numpy**）
```python
import npu_client as npu
with npu.connect() as c:                      # 读 $NPU_SOCK，再退 /tmp/npu.sock
    outs  = c.infer_image("yunet_npu", "a.jpg", 112, 112, norm=0)  # 图像→张量级
    faces = c.detect_yunet("yunet_npu", "a.jpg", 112, 112, 0)      # 图像级薄封装
    outs2 = c.infer("whisper_xx", mel)                             # 纯张量级（语音/ASR）
```
- **关键设计：图像预处理下沉到 C++ 库**（新增 `npu_infer_image()`）⇒ Python 侧**不需要 opencv**
  （设备系统 python 就没装 cv2），且预处理口径与厂商一致、只有一处实现。
- 实测（真机）：`infer_image` yunet → `out[0](707,14) 非零 9898`、`out[1](707,2) 非零 1414 头=[[0.9823 0.0177]…]`
  （**概率 ⇒ softmax 生效**）、`out[2](707,1)`；`detect_yunet` → **1 张脸 score=0.9553**；
  ResNet50 `(1,1000)` argmax=407（该模型输出 logits，argmax 不受影响，要概率需补 softmax）；
  故意送错形状 → 服务返回 `-3`（符合预期）。

### ② 持久盘部署（`/opt/npu` + systemd 开机可用）
```
/opt/npu/{bin,lib,include,python,model,testdata,doc,README.txt}
```
- `npusvc.service` 关键点：`ConditionPathExists=/dev/npu0`、
  **`ExecStartPre` 把 `vha_sim_mode` 写 0**（开机模块默认 sim=1 模拟模式 ⇒ 服务启动即真硬件）、
  `--idle-kill-ms 120000`（**空闲 2 分钟回收 worker、把 `/dev/npu0` 让出来**）、
  `ExecStopPost` 杀 worker 防残留、`Restart=on-failure`、`LimitCORE=infinity`。
- `npusvc-smoke.{service,timer}`：每 15 分钟冒烟（判活+真跑一帧+判数值），日志入 journal。
- **踩坑**：`cp` 会继承源文件权限（源是 `0700`）⇒ `/opt/npu/testdata/*.jpg` 变成 root 0700，
  非 root 客户端读图失败报 **`-5 BADARG`**。部署脚本已加 `chmod -R a+rX`。

## 六、部署（systemd）

```ini
# svc/npusvc.service 关键行（完整见文件）
ConditionPathExists=/dev/npu0
Environment=LD_LIBRARY_PATH=/usr/local/lib
ExecStart=/opt/npu/npusvc_pool --sock /run/npu/npu.sock --models /opt/npu/model/ \
          --worker /opt/npu/npuworker --worker-timeout-ms 30000 --queue 64
ExecStopPost=/bin/sh -c 'pkill -x npuworker || true'   # 收尾：不留 worker 占设备
Restart=on-failure
LimitCORE=infinity                                      # 崩溃保留现场
KillMode=control-group
```
⚠️ 联调阶段二进制/模型在 `/dev/shm`（tmpfs，重启即丢）；正式部署请放持久盘（上例 `/opt/npu`）。

## 七、落地顺序（省时间的顺序）

1. **先写 worker**（可独立测试：一个进程内连跑 N 次 / 换模型）；
2. **再写 supervisor**（只做转发 + 超时 + 换进程）；
3. 先冒烟"**原来必挂的那组序列**"，再跑全套验收；
4. **保留单进程版源码/二进制不动** ⇒ 一键回退，且便于 A/B 对照定位"是池的锅还是库的锅"。

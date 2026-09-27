NPU 推理服务 —— 部署说明（/opt/npu）
====================================

一、这是什么
------------
把飞腾 D3000M 内置 NPU 做成"多应用可共享"的推理服务：客户端通过 unix socket 提交
张量级或图像级请求，服务端串行独占 NPU，支持多模型轮换（每模型一个 worker 子进程）。

  客户端 ──unix socket──▶ npusvc_pool（supervisor：排队/优先级/超时/换进程，**不占设备**）
                              └──▶ npuworker（一个模型一个进程，独占 /dev/npu0）

★ 为什么"每模型一个进程"：厂商库**不支持同进程多图**（响应按 sid 匹配，各图 sid 相同
  ⇒ 第 2 个模型必挂死；连"切模型时销毁旧引擎"都无效）。隔离边界必须是进程。
  详见 ../doc/ 与项目文档《NPU-第三十轮-多模型卡死根因》。

二、目录
--------
  /opt/npu/bin/npusvc_pool      supervisor（systemd 启动的就是它）
  /opt/npu/bin/npuworker        执行体（由 supervisor 按需拉起，勿手工常驻）
  /opt/npu/bin/npu_cli          命令行客户端（status/face/infer/bench/load）
  /opt/npu/bin/npusvc           单进程版（历史/回退用，不用于新部署）
  /opt/npu/bin/svc_smoke.sh     冒烟自检（判活 + 真跑一帧 + 判数值，退出码分级）
  /opt/npu/bin/libnpuclient.a   静态客户端库（C/C++ 链接这个）
  /opt/npu/lib/libnpuclient.so  动态客户端库（Python/其他语言用）
  /opt/npu/include/npuclient.h  客户端 C API（唯一需要 include 的头）
  /opt/npu/python/npu_client.py Python 客户端（ctypes，**只需 numpy**）
  /opt/npu/python/examples.py   Python 示例（图像→张量、图像级人脸、分类、纯张量）
  /opt/npu/model/               模型（*.json/*.params/*.so/*.tar + *.meta.txt 后处理规则）
  /opt/npu/testdata/            冒烟用的测试图
  /opt/npu/doc/                 systemd unit 副本

三、服务管理
------------
  sudo systemctl status npusvc            # 状态
  sudo systemctl restart npusvc           # 重启（会清掉旧 worker）
  sudo systemctl stop npusvc              # 停止（ExecStopPost 会杀 worker，确保设备让出）
  journalctl -u npusvc -n 50              # 日志
  sudo systemctl start npusvc-smoke       # 手工跑一次冒烟
  systemctl list-timers npusvc-smoke.timer # 冒烟定时器（每 15 分钟）

关键参数（unit 里改）：
  --worker-timeout-ms 30000   worker 响应/写超时；超时即 SIGKILL 并回收
                              ⇒ "库挂死"变成可观测错误（status=14）+ 下次自动换新进程
  --idle-kill-ms 120000       空闲 2 分钟回收 worker，**把 /dev/npu0 让出来**
                              （便于人工/其他工具临时使用）；要常驻加速设为 0
  --queue 64                  队列上限；满则拒绝（客户端收到 -7 QUEUE_FULL）

四、客户端用法
--------------
C/C++：
  #include "npuclient.h"  →  -I/opt/npu/include -L/opt/npu/lib -lnpuclient
  int h = npu_open(NULL);                       // 读 $NPU_SOCK，再退 /tmp/npu.sock
  npu_tensor_t ts[8]; unsigned char *arena; size_t ab;
  int n = npu_infer_image(h, "yunet_npu", "a.jpg", 112, 112, 0, 1, 0, 8, ts, &arena, &ab);
  // 张量级：npu_infer_ex(h, model, data, bytes, shape, ndim, "f32", prio, timeout, ...)
  npu_free(arena);

Python：
  import npu_client as npu
  with npu.connect() as c:                      # 或 npu.connect("/run/npu/npu.sock")
      outs = c.infer_image("yunet_npu", "a.jpg", 112, 112, norm=0)   # 图像→张量级
      faces = c.detect_yunet("yunet_npu", "a.jpg", 112, 112, 0)      # 图像级（薄封装）
      outs2 = c.infer("whisper_xx", mel)                             # 纯张量（语音等）

错误码：0 成功 / -1 连接或读写 / -2 协议 / -3 服务端 / -4 空间不足 / -5 参数或图片读不到 /
        -6 超时 / -7 队列满 / 服务端另有 status=14 = worker 超时被击杀

五、模型与后处理口径（★换模型必读）
------------------------------------
厂商运行时**漏了"设备页 → App 缓冲"的搬运，并且跳过了模型自带的激活**，所以每个模型在
`<模型名>.meta.txt` 里声明一条规则：`<输出下标> <引擎页号> <op>`，例如
    1 93 softmax2        # yunet：第 1 个输出在设备页 93，需要 2 类 softmax
- `op ∈ none | softmax2 | sigmoid`；**不加激活**会出现"框对、分数错、误检十几张"。
- **页号换机器/换工具链会变**：用桥接的 dmesg `[VHA-ALLOC] page=… size=…`（含缓冲名字）
  与实际输出尺寸交叉确认后更新该文件。
- 已知：yunet → `1 93 softmax2`；yolov5s / scrfd 输出为 logits 但按各自解码口径使用；
  ResNet50 输出 logits（argmax 不受影响，要概率需补 softmax）。
- 各模型输入口径：yunet 112×112 裸 0-255；yolov5s 640×640 `/255`；
  scrfd 640×640 letterbox + `(x-127.5)/128`；ResNet50 224×224 `/255`；ppocrv3_cls 192×48 `/255`。

六、开机与真硬件开关（★重要）
------------------------------
- 驱动模块在**开机时会自动加载，且默认 `vha_sim_mode=1`（模拟模式，不碰硬件）**。
  npusvc.service 里有 `ExecStartPre` 把该参数写 0 ⇒ 服务启动后即为真硬件。
- 手工跑实验时若怀疑"跑了但没真算"，先确认：
      cat /sys/module/phytium_npu/parameters/vha_sim_mode      # 应为 0
      echo 0 | sudo tee /sys/module/phytium_npu/parameters/vha_sim_mode   # 运行时可写，无需 rmmod
- 若服务占着 NPU 而你要手工跑：`sudo systemctl stop npusvc`（或等 `--idle-kill-ms` 自动让出）。

七、自检与故障对照
------------------
  bash /opt/npu/bin/svc_smoke.sh        # 0=健康 1=服务没起 2=推理失败 3=数值不对
  /opt/npu/bin/npu_cli status           # 看 REQS/ERRS/TIMEOUTS/SWITCHES/WORKER_TIMEOUTS

| 症状 | 先查 |
|---|---|
| 客户端 `-1`（SOCKET） | 服务是否在跑；socket 路径（`$NPU_SOCK`）；是否有**残留 worker**（`pgrep -x npuworker`，残留会与池抢设备） |
| 客户端 `-3`（SERVER） | `journalctl -u npusvc -n 50`；`/var/log/npuworker.log`；输入形状/图片路径是否对 |
| `status` 里 `WORKER_TIMEOUTS>0` | 该次推理超时被击杀（库侧挂死）；看 worker 日志定位模型 |
| 结果"像随机/全 0" | ①`vha_sim_mode` 是否为 0 ②`<模型>.meta.txt` 的页号是否过期 ③激活口径 |
| 换模型后必挂 | 是否被改成了同进程多模型（**必须进程池**）；查 `SWITCHES` 是否在增长 |
| `oops` 计数不为 0 | ⚠️ `grep oops` 会误匹配 systemd 的 `ramoops` ⇒ 用 `grep -E 'oops|BUG:' \| grep -v ramoops` |

八、回退
--------
- 代码回退：单进程版 `/opt/npu/bin/npusvc` 仍在（协议一致，客户端不用改）。
- 驱动回退：`/lib/modules/$(uname -r)/extra/phytium_npu.ko` 有备份目录（见项目交接文档）；
  **改内核模块前先问用户**（部分改动出错只能硬重启恢复）。
- 服务回退：`sudo systemctl disable --now npusvc`（回到"手工起服务"状态）。

（本文档随部署一起放 /opt/npu/README.txt；项目文档与复现步骤见 GitHub 仓库 docs/）

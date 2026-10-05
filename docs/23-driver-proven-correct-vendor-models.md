# 第八轮-16 ★★ 决定性转折：驱动已被证明正确，问题只在"多段包"（2026-10-05 深夜）

## 一、最重要的结论：驱动侧是**对的**

用**完全相同的驱动配置**（`sim=0 / resp_fix=0 / vrsp_skip=1 / push_enable=1 /
slot=1 / step=0 / replay=6 / replay_ms=100`）跑厂商**预编译**模型（池路径 `npu_client`）：

| 模型 | MBS 数 | load | infer | 结果 |
|---|---|---|---|---|
| **mobilenet** | 1 | ✓ 0.1s | ✓ 0.21s | **输出 (1,1000) max=3.4160 argmax=111** |
| **Restnet50** | 1 | ✓ 0.2s | ✓ 0.22s | **输出 (1,1000) max=5.9160 argmax=644** |
| **ppocrv3_cls** | 1 | ✓ 0.1s | ✓ 0.22s | **输出 (1,2)** |
| scrfd | 1 | ✓ | ✗ | 需正确形状，未复测到位 |
| **sensevoice** | **141** | ✓ 16s | ✗ | 挂死（worker 无任何错误输出） |
| sv0（备选包） | **37** | ✓ 5.2s | ✗ | worker 死 |

**⇒ 结论：我们的驱动（响应投递 / `[+2]` / slot / 完成通知）对单段模型完全正确。**
**⇒ 失败**只**发生在"多段包"上 ⇒ 卡点性质从"驱动投递"转为"多段执行"。**

## 二、多段包的真实失败信息（此前一直被忽略的关键）

`svtest`（= sv0，未打补丁）的网络创建**直接失败**，worker 日志有明确文本：

```
ERROR: (getPHYDNNObject) Initialising dnn network from buffer failed because of:
  Incorrect input buffer, id: 6   Segment: 1
  Detailed error: Buffer ID: 6 exceeds its capacity.
    It is of size: 457776, but segment IO declares size: 913920
ERROR: unable to create network for function 'tvmgen_default_npu_main_0'
```

- `sensevoice.json`/`sv0.json`/`mobilenet.json` 里**都搜不到** `913920`/`457776`（十进制+小端十六进制都搜过）
  ⇒ 两个数都是**运行时算出来的**（`docs/14` 已判定为"库内部两套口径"）。
- 数字关系：`913920 = 228480×4`（精确）；`457776 = 228480×2.0036`（≈2 倍，不精确）。
- `__internal_io_file__` 声明输入正是 `x[1,200,560] float32`（**我们的测试输入没写错**）、输出 `logits[1,204,25055]`。

**⇒ 我们早前用「改 MBS `0x368` 声明尺寸」绕过该检查，让**当前** `sensevoice.tar` 能 load（16.1s）；**
**⇒ 但推理阶段 worker 日志**一条错误都没有**，纯挂住 ⇒ 补丁把"显式报错"变成了"静默挂死"。**

## 三、库侧执行机制（静态+实测，全确认）

| 项 | 事实 |
|---|---|
| 完成置位 | `VhaNotifyImp::Update(status)` @`0x16310`；**只写 `this+256`，不 notify** |
| 两个调用点 | `0x1dfc0 → Update(1)`（任务段列表倒计数到 0）；`0x1ed64 → Update(4)` |
| 等待 | `WaitForCompletion(timeout)` @`0x15c58`（**导出符号**，`libphydnn_execute.so` 调） |
| 实测返回 | **status 在 4 / 1 之间交替**；`SetError` **0 次**（库没设任何错误） |
| 每任务段数 | 实测 `w20` = **8**（伴随一个 1）；`W20` 呈 `8,1,8,1…` ⇒ **重试循环** |
| OutputSync | `SetOutputSync(fd)` 实测被调 **3 次**（fd=13/16/18）；`WaitForStatus` **0 次** |
| 锁 | `Acquire=3 / Release=2`（有一次未释放） |

## 四、下一轮的方向（明确）

**核心命题：多段包为什么在多段执行时挂住？**

优先动作：
1. **在成功的 mobilenet 上量出"成功基线"**：`w20` 段数、`Update` 次数、`WFC` 返回分布
   —— 上一轮 gdb 没挂上（mobilenet 太快），需在 `init_graph` 后立刻 attach 或改用
   `gdb -ex "set breakpoint pending on"` + 提前 attach 到常驻 worker。
2. **数清 sensevoice 实际执行到第几段挂住**：在 `1d3fc bl 32430 (NextSegment)` 打印段序号，
   看是否停在固定的第 N 段（若是，则该段的 MBS 有问题）。
3. **对照段 IO 尺寸**：把 `sensevoice` 里**每个** MBS 的声明尺寸与库申请尺寸逐一对齐
   （而不是只改一个字段）—— 现在的补丁可能只对齐了一处。
4. **验证"单段 vs 多段"的库差异**：`VhaObserver::Register()` @`0x36c00`、接收线程 `_M_run`
   在多段场景是否被多次注册/同一 map。

## 五、设备当前状态（交接必读）

- 模型目录 `/opt/npu/model/`：
  - `sensevoice.tar` = **改建版**（含 `__internal_io_file__.orig`，589373440 B）—— **能 load**
  - `sensevoice.tar.bak_20260929` = 原始版（589516800 B，143 项）—— **不能 load**（worker 死）
  - `sensevoice.tar.bak_current_1005_2111` = 本次操作前的改建版副本
  - `svtest.*` = `sv0.*` 的副本（72 MBS，未打补丁，创建网络即失败）
- `.ko`：`srcversion=65AF4BC491B212C74F54A5D`，`/sys/module/phytium_npu/parameters/*` **0644 可写**
- **调参走 sysfs，勿 rmmod；`vha_rsp_replay` ≤ 个位数**（否则 `cma_alloc→flush_work` 死锁 ⇒ D 状态 ⇒ 只能硬重启）
- 脚本：`run_mb.sh`（mobilenet 成功基线）、`run_vendors.sh`（横向）、`run_sverr.sh`（抓 worker 错误）、
  `gdb_w20.py`（段数）、`gdb_wfc.py`（完成返回分布）、`gdb_wfs.py`（OutputSync/Acquire）

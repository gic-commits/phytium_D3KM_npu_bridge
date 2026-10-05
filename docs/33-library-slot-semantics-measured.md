# 第八轮-26 ★库的 slot 语义彻底测出（含之前猜错的修正）

## 一、探针失效的真相：`gdb -batch` 缺 `continue`

`gdb -p <pid> -x script.py -batch` 跑完脚本就 **detach**，断点从未生效过
（所以一度出现"按符号挂上了断点却 0 命中"的假象，与"库没读响应"的错觉叠加，误导了一轮）。
**脚本末尾必须 `gdb.execute("continue")`。** 这是本轮最便宜的坑，但浪费了不少时间。

## 二、★★★★★ 测出的库 slot 语义（权威，实测）

用符号名断点（`npu::VhaDnnTask::GetSlot() const` 返回 `*(u32*)($x0+4)`、
`npu::VhaObserver::HandleResponse(int,...)` 读 `$w1`）实测：

**mobilenet（1 个子图）**
```
[SLOT#1] task->slot = 1      → [HR#1] 库注册等待 slot/id=1
[SEG#2] NextSegment
[SLOT#3] task->slot = 1      → [HR#2] 库注册等待 slot/id=1
（每次推理都从 slot=1 重新开始）
```

**sensevoice（多子图）**
```
[SLOT#1..5] task->slot = 1        → [SEG#1] → [HR#1] 库注册等待 slot/id=1
[SLOT#6]    task->slot = 2        → [SEG#2]
[SLOT#7..14]task->slot = 3        → [SEG#3] → [HR#2] 库注册等待 slot/id=3
[SLOT#16]   task->slot = 4        → [SEG#4]
[SLOT#17..] task->slot = 5        → …
```

**⇒ 结论（三条）：**
1. **库的任务是**连续编号** `1,2,3,4,5…`（不是 1,3,5,7！）** ——
   之前"库依次要 1,3,5,7"的说法**只反映了 `HandleResponse` 的注册（只对奇数任务注册）**，
   把偶数任务（2,4,…）漏掉了，于是错误地推出"步长 2"并据此调参多轮。
2. **每个子图对应一个任务**；任务号在**一次推理内**连续递增，**每次新推理从 1 重新开始**
   （mobilenet 每次都是 slot=1，正是这个规律的退化情形）。
3. 驱动每收到一次提交就应回一条 **`[+2] = 该任务号`** 的响应；顺序即任务号顺序。

## 三、因此正确的参数是 `vha_rsp_slot_step = 1`（不是 2）

实测（step=1、reset_on_sync=1、gap=0）：
- **mobilenet 3/3 全绿** ✅
- sensevoice 仍 -3，推送序列为 **`2,3,4`** —— **整体错一位**

## 四、错位原因（下一步就修这个）

`vha_alloc_slot()` 实现本身正确：`n = atomic_inc_return(&seq) - 1; s = slot + n*step`
⇒ **首次分配应为 1**。但实测首发是 2 ⇒ **在推理的第一次可见推送之前，已经有**一次分配**
被"看不见的路径"消耗掉了**（`phytium_npu_uapi.c:826 d->slot = vha_alloc_slot();` 这类
排队/延迟推送路径会分配但不一定打日志；`load` 阶段也会走提交路径）。

⇒ **库在推理开始时把任务号从 1 重排，而我们的计数器没有在那一刻归零 ⇒ 整体错一位 ⇒
库等 1 我们给 2、库等 3 我们给 4 ⇒ 全部落空 ⇒ 3 段后停住。**

**复位手段现状：**
- `vha_slot_gap_ms`（静默间隔复位）：试过 500/1000/1500，**均未在 load→推理边界触发**；
  且 500ms 时会在段间误触发（段与段之间的间隔也可能 >500ms）⇒ **不可靠**。
- `vha_slot_reset_on_sync`（库 arm OUTPUT_SYNC 时复位）：**在 sensevoice 流程上未观察到触发**。

**下一步候选（按优先级）：**
1. 找出并**排除**那个"看不见的分配"（把 `vha_alloc_slot()` 的所有调用点打日志，
   定位到底哪条在推理前多分了一次）—— 最直接。
2. 给 `vha_slot_reset_on_sync` 打日志确认 OUTPUT_SYNC 是否真的到达、在哪个时刻到达；
   若是"执行结束后"才到，就改用**"上一次推送已被库读取"**作为复位点。
3. 最稳的做法：**不再自己数**，而是从提交 payload 里取库给的任务身份（若 payload 中确有该字段）。

## 四·补 ALLOCDBG 精确定位（本次新增）

在 `vha_alloc_slot()` 里加 `pr_info("[VHA-ALLOC] caller=%pS n=%d slot=%u ...")`（`%pS` 把返回地址
解析成符号名），模块重载后单独跑 sensevoice，**全程只记录到 3 次分配**：

```
caller=vha_rr_push_one+0x4c/0xa8 [phytium_npu]  n=1  slot=2  step=1  gap_ms=0
caller=vha_rr_push_one+0x4c/0xa8 [phytium_npu]  n=2  slot=3  step=1  gap_ms=0
caller=vha_rr_push_one+0x4c/0xa8 [phytium_npu]  n=3  slot=4  step=1  gap_ms=0
```

**⇒ 两点确定：**
1. **推送全部走 `vha_rr_push_one`**（不是 `vha_push_response` 主路径）；
2. **`n` 从 1 开始**（`n = atomic_inc_return(&vha_rsp_slot_seq) - 1` ⇒ 首次 inc 返回 2 ⇒
   **`vha_rsp_slot_seq` 在首次推送前已经是 1**），而全程**只有这 3 次分配**被记录到。

⇒ 即：加载模块后、首次可见推送前，**序列被加过 1 次但没有产生记录**（可能是
`OUTPUT_SYNC` 之前的某条路径，或 `vha_rr_push_one` 之外的另一处赋值）。
**下一步只需在这一处补日志（把 inc 前后都打出来 + 打印是谁把 seq 置成 1），即可收口。**

**修好这一点后，sensevoice 的响应序号就能从 1 开始对齐 ⇒ 预计即通。**

## 五、本轮其他确认

- **厂商官方完成路径确实推响应**：`phytium_npu_inference_complete()` →
  `phytium_npu_response_stream(sess, nstream, nstream->nustream.estream.sid, NPU_RSP_OK, 0)`
  （键 `[+2]`=0 被库丢弃；我们自己补推的那条键=slot，被库接受）。
- **库确实在读响应**：`[VHA-READ]` 6 次、每次 `empty=0`；`read()` 里有 `list_del` 摘链 ⇒ 投递通。
- **发现一处真实内存泄漏（待修）**：`if (!rsp->session) kfree(rsp);` —— 我们自己造的响应
  `session` 非 NULL ⇒ 读走后**永不释放**，每次推理泄漏一条 `npu_user_stream_rsp`。
- 三个模型库/依赖已核实：worker 加载 `/usr/local/lib/{libnpusession,libphyaiengine,libphydnn_execute,libtvm_runtime}.so`
  与模型自带 `/opt/npu/model/<model>.so`。

## 六、状态
- 参数：`vha_use_irq_done=1 rsp_slot=1 rsp_slot_step=1 slot_gap_ms=0 slot_reset_on_sync=1`
- **mobilenet 3/3、6/6 全绿**（此前的"隔次失败"已彻底消除）
- sensevoice 仍 -3，卡点已精确定位到"推送序号整体错一位"

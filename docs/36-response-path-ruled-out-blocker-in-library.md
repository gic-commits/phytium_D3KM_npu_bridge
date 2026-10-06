# 第八轮-29 收尾：响应侧已彻底排除；卡点锁定在库内部等待

## 一、本轮**排除**的响应侧全部变量（负结果清单，别再回头试）

| 变量 | 取值 | 结果 |
|---|---|---|
| 响应键 = 常量 | `1` / `4` | ✗（笔记里"库只接受 1 或 4"的说法**不成立**） |
| 响应键 = 递增 | `1,2,3…`（step=1）/ `1,3,5…`（step=2） | ✗ |
| 响应键 = 覆盖式一串 | 每段推 1..15（burst，42 条全部被库读走） | ✗ |
| 响应键复位时机 | open() 复位 / 每段复位 / 会话切换复位 | 复位生效了（mobilenet 键从 1 开始），但 sensevoice 仍 ✗ |
| `err_no` | =0（与厂商 `NPU_RSP_OK=0` 一致） | ✗ 排除 |
| 性能字段 | `last_proc_us/mem_usage/hw_cycles` 填非零 | ✗ |
| 响应结构 | 与厂商逐字段一致（sid/err_no/rsp_err_flags/session_id/rsp_size/session） | 已对齐 |
| 缓冲越界 | 按厂商方式多分配（ursp 在偏移 32、rsp_size=24 ⇒ 原越界 8 字节） | **已修**（不是卡点，但确实是 bug） |
| 投递 | 库 `read()` 全部读走（42/42） | 通道正常 |

**⇒ 结论：响应的"键、内容、结构、投递"四个方面全部排除。卡点不是响应。**

## 二、卡点的最终定位（已很窄）

修复内存后（`drop_caches`+`compact_memory`）：
- **worker 日志零错误**（无 FATAL、无 "unable to create network"）
- CPU ticks 实测：`t=3s→178  t=6s→413  t=10s→429  t=15s→429` ⇒ **6 秒后完全冻结**
  ⇒ **不是"慢慢在建网"，是真阻塞**
- 线程栈：
  ```
  主线程   → … → PhytiumEvents::WaitHelper → VhaNotifyImp::WaitForCompletion(int)   ← 等任务完成
  任务线程 → VhaDnnImp::Execute{lambda#4} → VhaObserver::HandleResponse(...)          ← 等它那条响应
  接收线程 → GetVhaResponse()（read 阻塞，队列空）
  ```

**⇒ 综合：库在"提交 3 段"之后停止继续提交，主线程阻塞在任务完成等待上；
而我们把能控制的一切（键/结构/字段/条数/时机）都试遍了仍不前进
⇒ 剩余疑点在库内部**等待被唤醒的链路**（`Update(status)` 只写不 notify，
   真正唤醒依赖另一条通知路径），或与**未复刻的某个 ioctl 语义**有关。**

## 三、本轮确认的协议事实（有价值的中间成果）

1. **提交不走 ioctl，而是 `write()`** → `vha_real_submit()`。
2. 描述符（272B）字段：`@0 sflags  @2 stype  @4 sid  @10 all  @11 in  @12 t(命令缓冲句柄)`
   实测三次提交：`sflags=0x8/0xa/0xc`（步长 2 递增）、`stype=0x3`、`sid=0x10101`（恒定）、
   `all=6/7/8`、`t` 各异。
3. `#define NPU_COMPUTEFLAG_NOTIFY 0x0001 /* send response when cmd complete */`
   ⇒ `stype=0x3` 含 bit0 ⇒ 该流**确实要求完成响应**，与我们的推送行为一致。
4. 单次 sensevoice 运行的 ioctl 实况（清 dmesg 后）：**~555×ALLOC + ~555×MAP_BUF + 10×BUF_OP**
   （此前"只有 nr=9"是日志被冲掉的假象）。

## 四、性能对照（多段模型 141 子图）
| 模型 | 提交次数 | 结果 |
|---|---|---|
| mobilenet | 1 | ✓ 连跑 6/6 |
| Restnet50 | 1 | ✓ 连跑 4/4 |
| sensevoice | 3（然后停） | ✗ |

## 五·补2 ★★★ 库对响应 `[+2]` 的**确切校验**（反汇编实锤）

在 `VhaDnnImp::Execute` 的段处理 lambda（`0x1d410` 附近）：

```asm
1d410:  ldrh w0, [x0, #2]          ; ★ 读响应 [+2] 的 u16
1d41c:  cmp  w0, #0x4
1d420:  ccmp w0, #0x1, #0x4, ne    ; ★ 判 [+2] 是否为 4 或 1
1d424:  b.eq 1e008                 ; 是 1 或 4 → 正常分支
1d428:  mov  w0, #0x2
1d42c:  str  w0, [sp, #212]        ; 否则 status = 2（失败）
1d43c:  bl   VhaDnnTask::GetSubmitKey(w1)   ; 非 1/4 时改走"提交键"路径
1d44c:  bl   VhaDnnTask::GetId()
```

**⇒ 判据（务必记住）：库要求响应 `[+2]` 的 u16 ∈ **{1, 4}**。**

**这直接推翻了此前所有"键序列"努力的方向：**
- `step=2` 得到 `1,3,5` ⇒ 第 2 条起 `[+2]=3/5` **非法**
- `step=1` 得到 `1,2,3` ⇒ 第 2 条起 `[+2]=2/3` **非法**
- 只有常量 `1` 或常量 `4` 能通过该校验（而这两者实测**仍然阻塞**）

⇒ **卡点在"该校验通过之后"的环节**，不在键值本身。

**（`GetSubmitKey` 只在"非 1/4"分支被调用 ⇒ 说明还有一条"提交键"路径用于软处理段；
`SetSubmitKey` 在 `Execute+0x241dc` 被调用，紧接着就调 `GetSlot()` ⇒ 提交键与 slot 是两套并行机制。）**

## 五·补3 ★ 唤醒链路（已定位到函数）

```asm
; Signal() 通知的正是主线程等待的 condvar (this+0x98)
165b0: add x0,x19,#0x98 ;  165c0: b d2c0 (notify_all)
; 调 Signal 的仅两处，都在 VhaDnnTask 内：
32d2c: bl 16568   ← VhaDnnTask::Finalize() (0x32cc0)
330a8: bl 16568   ← VhaDnnTask::Done
; Update (只写 +256，不 notify)：
1dfc0 / 1ed64
```

**⇒ 库停住的直接原因：**任务的 `Finalize()` 没被调用**（`Update` 只写状态，不唤醒）。
⇒ 下一步精确目标：**找 `VhaDnnTask::Finalize()` 的调用者**（无反汇编直接 `bl` ⇒
经虚表/函数指针间接调用，或由 `libphydnn_execute`/`libphyaiengine` 侧驱动）。**

## 五·补4 给下一轮的明确抓手

用反汇编追"谁唤醒主线程"：

```asm
; VhaNotifyImp::Signal()  —— 通知的正是主线程等待的 condvar (this+0x98)
165b0:  add x0, x19, #0x98
165c0:  b   d2c0            ; ← notify_all

; 谁调用 Signal (0x16568)：
32d2c:  bl  16568 <npu::VhaNotifyImp::Signal()>      ← 在 VhaDnnTask::Finalize() 内
330a8:  bl  16568 <npu::VhaNotifyImp::Signal()>      ← 在 VhaDnnTask::Done 相关代码内

; 谁调用 Update (0x16310)（只写 +256，不 notify）：
1dfc0:  bl  16310 <VhaNotifyImp::Update>              ; 传 status=1
1ed64:  bl  16310 <VhaNotifyImp::Update>              ; 传 status=4
```

**⇒ 结论：**
- **主线程 `WaitForCompletion` 等待的 condvar（`+0x98`）由 `VhaNotifyImp::Signal()` 唤醒；**
- **`Signal()` 由 `npu::VhaDnnTask::Finalize()`（0x32cc0）调用**；
- `Update()`（`1dfc0`/`1ed64`）**只写状态不 notify** ⇒ 光有 Update 不会唤醒线程
  ⇒ **必须有人调 `Finalize()`**。

**⇒ 因此：库停住的直接原因是"任务的 `Finalize()` 没有被调用"。**
**下一步（精确）：找 `VhaDnnTask::Finalize()` 的调用者** —— 反汇编里**没有直接 `bl 32cc0`**
⇒ 它是**经虚表/函数指针间接调用**的（`ldr xN,[xM,#off]; blr xN`），
或由 `libphydnn_execute.so` / `libphyaiengine.so` 侧驱动。
**只要找到"谁在什么条件下调 Finalize"，就等于找到了驱动必须满足的条件。**

**（另一条并行线索：`VhaDnnTask` 还有 `SetSubmitKey/GetSubmitKey`、`SetSwProcKey/GetSwProcKey`、
`GetSwExecutor` —— 说明"提交键/软处理键"是库用来把**响应与任务**关联的机制，
很可能就是我们一直在猜的"响应 [+2]"的真正语义来源。）**

1. **`Update` 的唤醒路径**：`VhaNotifyImp::Update` 只写 `+256` 不 notify；定位**谁负责 notify**
   （早期反汇编发现 `0x2010c` 处通知的是 `obj+0xd8`，不是 `WaitForCompletion` 等的 `+0x98`）
   —— 这很可能就是"主线程永远不被唤醒"的直接原因。
2. **未复刻的 ioctl 语义**：`VHA_BUF_OP`(nr=9，每段若干次) 与 `VHA_OUTPUT_SYNC`(nr=0xa)
   的真实语义仍是空白（第四轮回传里的第 2、3 项），这两者很可能就是"段就绪"的握手。
3. **运行前置步骤（务必）**：
   ```bash
   sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
   ```
   否则多段模型一定在建网阶段失败（已确认根因）。

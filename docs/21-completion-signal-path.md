# 第八轮-14 完成信号机制定位（2026-10-05 晚）

## 一、`VhaNotifyImp` 的等待/置位机制（全部静态确认）

### `WaitForCompletion(int timeout)` @ `0x15c58`（**导出符号**，由 `libphydnn_execute.so` 调）

```asm
15cb0: ldr  w19, [x20, #256]      ; status
15cb4: mov  w0, #1
15cbc: strb wzr, [x20, #264]      ; cancelling = 0
15cc4: cbnz w19, 15e4c            ; status!=0 ⇒ 直接返回
15cc8: str  w21, [x20, #260]      ; 存 timeout
15ccc: cmp  w21, #0
15cd0: add  x22, x20, #0x98       ; ★ condvar = this+0x98
15cd4: b.gt 15d6c                 ; timeout>0 ⇒ 走定时等待
15ce0: cv::wait(x22)              ; ---- 循环 A ----
15cec: ldr  w0, [x20, #256]
15cf0: cbz  w0, 15ce0             ; status==0 ⇒ 继续等
...   ; status!=0 后检查 acquire/cancelling，可能进循环 B
```

**⇒ 等的是 `this+256`（status）变为非 0。**

### `Update(NotifyStatus)` @ `0x16310`

```asm
16344: ldr w0, [x19, #256]
16348: cbz w0, 16368      ; 只在 status==0 时写入（首个状态生效）
1636c: str w21, [x19, #256]      ; ★ status = 参数
16364/16380: 解锁后返回（尾调 cb00 = pthread_mutex_unlock）
```

**⇒ `Update` 只写 status，**不 notify**。**

### `Signal()` @ `0x16568`

```asm
165a0: strb w0, [x19, #264]      ; cancelling = 1
165b0: add  x0, x19, #0x98
165c0: b    d2c0                 ; ★ notify_all(this+0x98)（取消路径）
```

### 全库 `notify_all` 只有 7 处

| 地址 | 所在 | x0 目标 |
|---|---|---|
| `0x165c0` | `VhaNotifyImp::Signal()` | `this+0x98` |
| `0x2010c` | `Execute` 的 lambda | `*(obj)+0xd8` |
| `0x24d80` | `VhaDnnImp::Execute` | ? |
| `0x32110` | `VhaDnnTask` ctor lambda | `obj+0x78` |
| `0x32b74` | `VhaDnnTask::operator()` | `task+0x78` |
| `0x334f0` | `VhaDnnTask::~VhaDnnTask()` | ? |
| `0x36658` | `VhaObserver` 接收线程 | `observer+0x10` |

**⇒ 除了 `Signal()`（取消），**没有**其它地方 notify `this+0x98`。**
**⇒ 而 `Update` 只写 status、不 notify ⇒ 存在"写完状态但唤醒者不同"的疑点（偏移 `+0x98` vs `+0xd8`）。**

## 二、完成条件的来源（`VhaDnnImp::Execute` 内）

```asm
1d354: ldr  x23, [x19, #264]     ; 段列表
1d3a8: bl   32be8                ; VhaDnnTask::Done 回调构造
1d3c4: cbz  w20, 1dfb8           ; ★ w20 = 段数；0 ⇒ 直接完成
1d3f0: str  w20, [sp, #144]      ; 倒计数 = 段数
1d3f8: f9408660 ldr x0, [x19, #264]
1d3fc: bl   32430                ; VhaDnnTask::NextSegment()
1d414: str  w1(-1), [sp, #212]
1d41c: cmp  w0, #0x4
1d420: ccmp w0, #0x1, #0x4, ne   ; ★ 段[+2] ∈ {1,4} 检查
1d424: b.eq 1e008
1d428: str  w0(2), [sp, #212]
...
1dfa8: subs w0, w0, #1           ; 每消费一段 -1
1dfb4: b.ne 1d3f8
1dfc0: bl   16310                ; ★★ Update(this, 1)  ⇒ 完成
```

另一处：`1ed64: Update(this, 4)`，条件是 `[sp,#212] == 4`。

**⇒ status ∈ {1, 4}（正是早期"库只接受 1 或 4"的出处）。**

## 三、这对我们意味着什么

`WaitForCompletion` 需要的 status=1，条件是**任务段列表被消费完**（`w20` 计数到 0）。
而"消费一段"由 `1d3fc NextSegment()` 驱动 —— **它依赖段列表的内容**。

**⇒ 如果库的段列表长度 > 我们提供的完成次数，计数永远到不了 0 ⇒ 永远等。**
这也解释了历史上"喂多少走多远"的现象。

## 四、下一步（按优先）

1. **确认 `this+0x98` 到底有没有被 notify**：在 `d1b0`（cv::wait）和 `d2c0`（notify_all）下断点，
   打印 `this`（`$x0`）与调用者，看同一个对象是否配对。
   若 `Update` 之后确实没人 notify ⇒ 库依赖**定时等待**或**别处 notify**，需查清。
2. **数清段列表长度 `w20`**：在 `1d3f0` 下断点打印 `$w20` —— 这就是库期待的完成次数。
   然后让驱动**恰好**推这个条数（`replay = N-1`）。
3. 对照 `1d3fc NextSegment` 的返回（`x0`）与 `段[+2] ∈ {1,4}` 的检查 —— 段内容从哪来。

## 五、关键坐标（`libnpusession.so`）

| 符号/项 | 偏移 |
|---|---|
| `WaitForCompletion(int)` | `0x15c58`（T） |
| `WaitForStatus(int)` | `0x15a80` |
| `Update(NotifyStatus)` | `0x16310`（唯二调用点 `0x1dfc0`/`0x1ed64`） |
| `Signal()` | `0x16568` |
| `Reset/GetStatus/SetOutputSync` | `0x16388` / `0x159c0` / `0x16808` |
| `VhaDnnTask::NextSegment()` | `0x32430` |
| `VhaDnnTask::Done` 构造 | `0x32be8` |
| `VhaDnnTask::operator()` | `0x32aa8`（唯一调用点 `0x24690`） |
| `VhaObserver::HandleResponse` | `0x356c0` |
| 接收线程 `_M_run` | `0x36420` |
| `VhaObserver::Register()` | `0x36c00` |

## 六、当前设备状态

- `.ko`：`srcversion=65AF4BC491B212C74F54A5D`
- 参数（上次）：`resp_fix=0 vrsp_skip=1 push_enable=1 slot=1 step=1 max=16 replay=15 settle=0`
- **调参走 sysfs，勿 rmmod；`replay` 须 ≤个位数**（否则 `cma_alloc→flush_work` 死锁 ⇒ D 状态 ⇒ 需重启）

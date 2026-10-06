# 第八轮-31 ★★★★★★★ 收尾被走到 ⇒ 卡点是「wait 与 notify 不是同一个对象」

## 一、先推翻"收尾没被调用"的旧结论

用 6 个断点探针（`gdb_segflow.py`）实测 sensevoice 一次推理：

```
[42402.490] ★首次命中 loop_in     (0x1d3f8 段循环入口)
[42402.490] ★首次命中 done_branch (0x1d424 段状态 ∈{1,4} 成立)
[42402.490] ★首次命中 signal_tail (0x1dfcc Done::~Done() ⇒ Signal)
#0  npu::VhaDnnImp::Execute(...)::{lambda()#4}::operator()()
#1  std::thread::_State_impl<...VhaDnnTask::VhaDnnTask(...)::{lambda()#1}>::_M_run()
```

**⇒ `signal_tail` 在同一 10ms 内就被走到了 ⇒ `Done::~Done()` **确实被调用** ⇒
   **"任务收尾从未发生"这个旧结论被推翻**（此前只靠"无反汇编直接 bl"推断，属误判）。**

**⇒ 收尾由 `VhaDnnTask` 自己的线程跑（`lambda#1 → lambda#4`），不是主线程。**

## 二、★★★★★★★ 根因级发现：wait 与 notify 的对象**不是同一个**

`gdb_condvar.py`：同时断在
- `npu::VhaNotifyImp::WaitForCompletion(int)`（0x15c58）→ 打印 `this`
- `Signal()` 内 `0x165b0: add x0, x19, #0x98`（形成 condvar 地址处）→ 打印 `x19`

实测（sensevoice 一次推理）：

```
[42643.490] [WAIT  ] #1 this(x0)=0x2bc1d4e0  condvar(+0x98)=0x2bc1d578    ← 0x2b…堆
[42643.490] [SIGNAL] #1 this(x19)=0x7f60288f38 condvar(+0x98)=0x7f60288fd0 ← 0x7f…
[42643.520] [WAIT  ] #2 this(x0)=0x2bcc33b0  condvar(+0x98)=0x2bcc3448
[42643.530] [SIGNAL] #2 this(x19)=0x7f37ffcf38 condvar(+0x98)=0x7f37ffcfd0
[42646.350] [SIGNAL] #3 this(x19)=0x7f2f7fbf38 ...
[42646.350] [WAIT  ] #3 this(x0)=0x2bcf3b20  condvar(+0x98)=0x2bcf3bb8
[42646.350] [WAIT  ] #4 this(x0)=0x2bcf8380  condvar(+0x98)=0x2bcf8418
[42646.380] [SIGNAL] #4 this(x19)=0x7f2effaf38 ...
[42649.220] [WAIT  ] #5 this(x0)=0x2d753a10  condvar(+0x98)=0x2d753aa8
[SUM] SIGNAL=2 / WAIT=0（首轮）；本轮 SIGNAL=4 / WAIT=5，两组地址从不重合
```

**⇒ 等待方（主线程）等待的对象始终在 `0x2b…/0x2d…`（堆），
   而 `Signal()` 作用的对象始终在 `0x7f…`（线程栈区）⇒ **两组对象从不重合**。**

**⇒ ⇒ **这就是"notify 被调用但没人醒"的直接原因**：
   通知送到了一个**没有等待者的对象**上，主线程仍在 `WaitForCompletion` 里永远阻塞。**

**⇒ ⇒ ⇒ 至此，"响应键/条数/结构/段状态/唤醒链路"全部可以收口：
   驱动把响应送到了，库也把收尾走到了，但**库内部把 wait 与 notify 挂在了两个不同的对象上**。**

## 二·补 ★★★★★★★ 对照实验：mobilenet 也"不同对象"，真正的差异是**对象是否复用**

对**能通的** mobilenet 跑同一个探针：

```
[WAIT  ] #1..#5 this(x0)=0x3646cbc0   condvar=0x3646cc58    ← ★每次都是同一对象
[SIGNAL] #1..#5 this(x19)=0x7f9c71cf38 condvar=0x7f9c71cfd0 ← ★每次也是同一对象
         ⇒ 5 次 wait / 5 次 signal，完全一一对应
```

对比 sensevoice：

```
[WAIT  ] this = 0x2bc1d4e0, 0x2bcc33b0, 0x2bcf3b20, 0x2bcf8380, 0x2d753a10 ← ★每次全新
[SIGNAL] this = 0x7f60288f38, 0x7f37ffcf38, 0x7f2f7fbf38, 0x7f2effaf38     ← ★每次不同线程栈
```

**⇒ ⇒ 「wait 与 notify 对象不同」在**能通的** mobilenet 上同样成立 ⇒ **它不是原因**（§二 的结论修正）。
**⇒ ⇒ ⇒ 真正的差异 = 对象**是否复用**：**
- **mobilenet（通）**：同一对对象被反复复用，wait/signal **一一对应**
- **sensevoice（卡）**：**每段都新建任务/通知对象，且由不同线程 signal** ⇒ 等待者与通知者**错配**

**⇒ ⇒ ⇒ ⇒ 机制：库在 sensevoice（多段）路径下**为每个段创建独立的
   `VhaDnnTask` + `VhaNotifyImp`**（`0x7f…` 是各任务线程自己的栈上对象），
   而主线程只在**其中一个**对象上等待 ⇒ 别的线程 signal 它看不到。**

## 二·补2 由此产生的下一步（精确且便宜）
1. **数清 sensevoice 下到底创建了多少个任务/通知对象**（在 `VhaDnnTask::VhaDnnTask`
   或 `VhaNotifyImp` 构造处设断点计数），与"主线程只等 1 个"对照。
2. 找出**主线程等的那一个**是哪个（`0x2b…` 堆对象是谁构造的、谁持有）。
3. 判定：是**库在多段路径下的固有编排**（须绕过/规避），还是**某个我们没满足的条件**
   让库把任务拆散了（若是，找那个条件 —— 这是唯一还能由驱动侧修的方向）。

## 二·补4 ★★★★★★★ 对象计数对照：**决定性差异 = 是否新建任务对象**

`gdb_taskcount.py`（断 `VhaDnnTask` 构造 + `Signal`，各记 `this`）：

```
mobilenet（通 6/6 次推理）:
  task_ctor = 0     ← ★ 一次都没新建 VhaDnnTask
  signal    = 6     ← 6 次 Signal 全在同一个对象 0x25fa9bc0
  ⇒ 复用同一个任务/通知对象 ⇒ wait 与 signal 一一对应

sensevoice（卡，1 次推理）:
  task_ctor = 5     ← ★ 新建了 5 个 VhaDnnTask
    this = 0x2d8e05b0, 0x2d9cb500, 0x2d9ae370, 0x2d9dfcc0, 0x2d9cf680
  signal    = 4     ← 4 次 Signal 分别在 4 个不同对象
    this = 0x2d9064e0, 0x2d9ac3b0, 0x2d9dcb20, 0x2d9e1380
  ⇒ 每段新建对象、且通知发到各新对象 ⇒ 与等待者错配
```

**⇒ ⇒ ⇒ 机制定论：**
- **库在单段（mobilenet）路径下**复用**同一个任务/通知对象 ⇒ wait/signal 配对成功**
- **库在多段（sensevoice）路径下**为每段新建任务对象**，`Signal()` 发到各自对象 ⇒
  主线程等的那一个收不到 ⇒ `WaitForCompletion` 永睡 ⇒ worker 超时击杀**

**⇒ ⇒ ⇒ ⇒ 这与此前所有观测一致：**
  - 我们的响应确实被读走（6/96/254 条都读走）—— 库在正常工作
  - 收尾/Signal 确实被走到（`signal_tail` 命中）—— 但发错了对象
  - 调驱动参数全部无效 —— 因为这是**库内部的编排**

## 二·补5 下一轮唯一有意义的两个方向
1. **判明"主线程该等哪一个对象"**：在 `VhaDnnTask::GetId()` / 任务创建处打印 id，
   看主线程等的 `0x2d75…` 属于哪个 id，与 5 个新建任务对照 ⇒ 是否"库等错了对象"
   （若是库 bug ⇒ 只能规避：例如让库不进多段拆分路径）。
2. **让库不进"每段新建任务"的路径**：查 `VhaDnnTask` 构造的触发条件
   （`VhaDnnImp::Execute` 里按段拆分的判据），寻找**能否由驱动侧条件影响**
   —— 这是唯一还能由我们修的方向。

- 响应延迟 0/300/1500ms：mobilenet 时延 0.42→1.52s 正常变化，sensevoice 提交恒 3、行为不变
  ⇒ **不是"响应太快造成丢失唤醒"的竞态**
- 段状态字段（`0x2b…` 库堆对象，非驱动内存）：写断点零命中；gdb 强制 3→1 也不放行


**mobilenet（单段）是通的** ⇒ **在那个场景下 wait 与 notify 一定是同一个对象**。
所以两种可能：
- (a) **库本身的编排缺陷**：多段（sensevoice）路径下 `VhaDnnTask` 与 `VhaDnnImp::Execute`
  拿到的是**两个不同**的 `VhaNotifyImp`（例如一个来自构造参数、一个来自 `Done` 守卫捕获）。
- (b) **驱动影响了库的分支**：某个我们没满足的条件让库走了"另一个 notify 对象"的分支。

**⇒ 判据（下一轮第一件事，非常锋利）**：
**对 mobilenet 跑同一个 `gdb_condvar.py`**：
- 若 WAIT 与 SIGNAL 对象**相同** ⇒ 说明 (b)：是某个条件让 sensevoice 路径错位 ⇒ 找那个条件；
- 若也**不同**（但仍能成功）⇒ 说明对象不同不是充分原因，需要看 `WaitForCompletion` 的
  判据字段（`+0x??` 的计数）是否已被置位（即 wait 之前状态已满足 ⇒ 不进 condvar）。

## 四、本轮另两项已排除
- **延迟响应**（0 / 300 / 1500 ms）：mobilenet 时延 0.42→1.52s 正常变化，
  sensevoice 提交数恒为 3、行为不变 ⇒ **不是"响应太快导致丢失唤醒"的竞态**
- **段状态字段**（库堆对象，非驱动内存）：写断点零命中、强制改 1 也不放行

## 五、结论
**驱动侧已全部排除（有实测）。剩余唯一卡点 = 库内部 wait/notify 对象不一致。**
下一轮第一件事：**对 mobilenet 跑 `gdb_condvar.py` 做对照**（判据见 §三）。

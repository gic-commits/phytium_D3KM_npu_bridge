# 第八轮-32 ★★★★ 任务在「建网阶段」由 InitResources 创建，且 observer = NULL

## 一、抓到了 `VhaDnnTask` 的确切构造者与参数

`gdb_taskctor.py`（断 `npu::VhaDnnTask::VhaDnnTask(unsigned int, VhaObserver*)`，
打印 `$w0`(id) / `$x1`(observer) 与调用栈），sensevoice 加载+推理全过程：

```
★VhaDnnTask ctor #5   id=...   observer=0x0          ← ★★★ observer 是 NULL
#0 npu::VhaDnnTask::VhaDnnTask(unsigned int, npu::VhaObserver*)
#1 npu::VhaDnnImp::InitResources(MBSParser*)          ← ★ 建网阶段，不是推理阶段
#2 npu::VhaDnnImp::Init(MBSParser*)
#3 npu::VhaDnnImp::InitFromBuffer(char const*, unsigned int)
#4 npu::VhaSessionImp::CreateDnnNetwork(char const*, unsigned int, char const*)
#5 npu_phydnnLoadNetworkObject()
#6 tvm::runtime::phytium::ExecuteOnNPU(...)
#7 tvm::runtime::PhytiumModuleNode::GetFunction(...)::{lambda#1}::Call(...)
```

**⇒ 结论 1：多段模型的"段任务"是在 **`load` 建网** 时由 `VhaDnnImp::InitResources` 一次性创建的，
   不是推理时按需创建。**
**⇒ 结论 2：创建时 `observer = NULL`。**
**⇒ 结论 3：调用链证明上层是 TVM 运行时（`libtvm_runtime.so` → `libphydnn_execute.so` →
   `libnpusession.so`），即模型走的是 `tvmgen_default_npu_main_N` 那套。**

## 二、与"能通的 mobilenet"的差异（已实测）

```
mobilenet（通 6/6）:  VhaDnnTask 构造 = 0 次（整个运行期）
                      Signal = 6 次，全在同一个对象 0x25fa9bc0
sensevoice（卡）:     VhaDnnTask 构造 = 5 次（load 阶段）
                      Signal = 4 次，在 4 个不同对象
```

**⇒ 单段模型**根本不新建**任务（复用 load 时建好的那一个）⇒ wait/signal 稳定配对。**
**⇒ 多段模型**在 load 时就为各段建好多个任务**，每个任务各有自己的通知对象 ⇒
   推理时各任务线程各自 `Signal()`，主线程等的那一个**收不到**。**

## 三、这条线索为什么重要（与已知事实全部吻合）

| 已知事实 | 由本条解释 |
|---|---|
| 我们的响应被读走（6/96/254 条） | 库在正常干活 |
| `signal_tail`（`Done::~Done()`）被走到 | 通知确实发出 |
| 主线程仍阻塞在 `WaitForCompletion` | 通知发到了**别的**任务对象 |
| 调驱动参数全部无效 | 这是**库内部的建网/编排**，与驱动无关 |
| mobilenet 能通 | 单段 ⇒ 复用同一对象 |

## 四、下一步（两个精确探针）

1. **observer 何时被赋值？** 对任务对象的 observer 字段设**写断点**
   （先确定字段偏移：在 ctor 里 tail-call 后读入参落点），看它是否在 `Execute`
   被赋值、赋的是不是主线程等的那个 `0x2b…` 对象。
   - 若**从未赋值**（一直 NULL）⇒ 库在多段路径下存在缺陷 ⇒ 只能规避。
   - 若**赋了别的值** ⇒ 找赋值点的条件 ⇒ 可能是唯一还能由驱动侧修的方向。
2. **主线程等的对象（`0x2b…` 堆）是谁建的？** 对它设写断点/追构造者，
   看它是 `VhaNotifyImp` 还是别的类，以及创建它的调用栈。
   - 若它由 `Execute`（调用方）创建，而 5 个段任务由 `InitResources` 创建 ⇒
     两者天生不相关 ⇒ 确认"多段编排错配"。

## 五、附：本轮其他已固化的对照数据
- `Signal`/`WaitForCompletion` 的 `this` 对照（`gdb_condvar.py`）：
  mobilenet 稳定同址；sensevoice 每次新址、每次不同线程栈
- 响应延迟 0/300/1500ms 对 sensevoice 无影响 ⇒ 非"丢失唤醒"竞态
- 段状态字段（库堆对象）：写断点零命中；强制改 1 不生效

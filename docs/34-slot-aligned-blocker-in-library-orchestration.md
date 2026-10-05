# 第八轮-27 slot 序号已完美对齐；阻塞点确认不在 key/内存/硬件

## 一、会话切换复位的实现与修正（重要教训）

**发现**：`vha_alloc_slot()` 的真实调用者是 **`vha_push_response()`**，不是 `vha_rr_push_one()`
（`caller=%pS` 实测：`vha_push_response.constprop.0+0x15c`）。
第一次把会话检查加进 `vha_rr_push_one` ⇒ **从未生效**（所以 `[VHA-SLOTSESS]` 一次没打印）。

**教训**：判断"哪条路径在跑"必须用 `%pS` 打印调用者，不能按函数名猜。
（这与"gdb -batch 缺 continue"是同一类错误：**工具没生效，却当成结论**。）

## 二、★ 关键推理：库要的是**奇数**序列 `1,3,5,7…`

`gdb` 实测的库侧注册：
```
[HR#1] 库注册等待 slot/id=1
[HR#2] 库注册等待 slot/id=3     ← 只注册奇数任务
```
⇒ HR#3 必然是 5 ⇒ **库需要的响应 key 序列是 1,3,5,7…，而不是 1,2,3,4…**

**实测验证（`vha_rsp_slot=-1` + `vha_rsp_slot_step=2`，无符号回绕得 1/3/5）：**
```
推送序列：slot=1  slot=3  slot=5      ← 与库的 HR 序列完全一致
```
（对照：`slot0=0`+`step=1` 得 `1,2,3`；`slot0=1`+`step=1` 得 `2,3,4`。
  `slot0=-1`+`step=2`：`(u32)(-1) + n*2` 回绕 ⇒ 1,3,5 ✓）

## 三、但 sensevoice **仍然**在第 3 段停住 —— 阻塞点不在 key

在"推送序列 = 库的 HR 序列"这一最优对齐下，仍是：
```
submit=3   push=6（3 次推送）   infer -> -3 SERVER
```

**同时排除的项：**
| 检查项 | 结果 |
|---|---|
| CMA 内存 | `CmaFree 1039032 / CmaTotal 1048576`（**99% 空闲**） |
| 分配失败 | **1962 次分配全部成功**，无 ENOMEM/fail 行 |
| 最后一次分配 | `size=28459008`（28MB，正常） |
| 库是否读响应 | 读（`[VHA-READ]` 6 次，`empty=0`，`list_del` 摘链） |
| 硬件是否执行 | 执行（完成中断 3/3，`done=1 after 8~10ms`） |
| key 对齐 | **已完美（1,3,5）** |

⇒ **结论：卡点在"编排层"——库做完 3 个任务后停止继续提交，而不是在响应/内存/硬件上。**

## 四、下一步方向（明确）

1. **`VHA_OUTPUT_SYNC`(nr=0xa) 语义**：本驱动用 anon fd 模拟，`vha_sync_wq_ensure()`/`vha_sync_signal()`
   在完成时置位。但**库是否在等这个 fd 变成 ready 才继续**？——加探针统计该 fd 的 poll/read 次数与时机。
   （这正是第四轮回传里的"第 3 项：OUTPUT_SYNC 未实现（假 fd），payload 含 id=37/47"。）
2. **`BUF_OP`(nr=9) 语义**：实测 `cmd=0x40107109` 进入 **10 次**（比提交多），
   怀疑它是"缓冲就绪"握手；当前实现是否回填了正确字段需复核。
   （第四轮回传的"第 2 项"。）
3. **用 gdb 跟踪库在 3 个任务后的行为**：现在探针可用（记得 `continue`），
   断在 `VhaDnnTask::NextSegment` / `HandleResponse` / `VhaNotifyImp::WaitForCompletion`，
   看它**最后一次调用停在哪里** —— 这能直接指出它在等什么。

## 四·补 ★阻塞点定位：主线程在等一个"我们没推送过"的 slot

失败时刻抓 worker 全线程栈（19 线程），三处卡点：

```
Thread 1  (主线程)  main → phyAIEngine::execute_graph → GraphExecutor::Run
                    → ExecuteOnNPU → SetEventForNode → PhytiumEvents::WaitHelper
                    → npu_phydnnWaitForEvent → ★VhaNotifyImp::WaitForCompletion(int)   ← 等 NPU 事件
Thread 19 (任务线程) VhaDnnTask 构造 lambda → VhaDnnImp::Execute{lambda#4}
                    → ★VhaObserver::HandleResponse(int, std::function<void(void*)>, int)  ← 等它那条响应
Thread 2  (接收线程) VhaObserver 构造 lambda → ★GetVhaResponse()                        ← read() 阻塞（队列空）
其余 7 个        tvm::runtime::ThreadPool::RunWorker 空闲待命
```

**⇒ 主线程等的那个"NPU 事件"是**由我们推送的响应驱动**的。
⇒ 我们只推了 3 条（slot=1,3,5），而库**已经为更多任务登记了等待**（`HandleResponse` 在任务线程里先注册）
⇒ **第 4 个任务等不到它的 slot ⇒ 主线程卡在 `WaitForCompletion` ⇒ 循环不再提交第 4 段。**

**⇒ 即卡点不是"库要的 key 算错了"，而是"库登记了 N 个等待、我们只回了 3 条"。**

**下一步（明确）：**
1. 数清库**一共登记了多少个等待**（`HandleResponse` 调用次数）——
   用可用的 gdb 探针（记得 `continue`）在卡住前统计 `HR#` 总数。
2. 若登记数 ≫ 提交数，说明库**预先登记了全部任务的等待** ⇒ 我们需要**按任务数推送**，
   而不是"来一次提交推一条"。此时应从提交 payload 里取任务身份，或按库的登记顺序补足推送。
3. 复核 `VhaDnnTask` 构造时挂的那个 lambda（`VhaDnnImp::Execute::{lambda#4}`）——
   它决定"谁来 arm 这个等待"，是理解登记时机的关键。

## 五、当前最佳配置（保留）
```
vha_use_irq_done=1        # ★突破：完成判据用中断（单段模型 6/6 全绿）
vha_rsp_slot=-1
vha_rsp_slot_step=2       # ⇒ 响应 key 序列 1,3,5,7…（与库 HR 序列一致）
vha_slot_reset_on_sync=1
vha_slot_reset_on_session=1
vha_slot_gap_ms=0  vha_rsp_on_read=0  vha_rsp_cycle_ms=0  vha_resp_fix=0
```
- **mobilenet 6/6、Restnet50 4/4 全绿**（单段模型已彻底通）
- sensevoice(141 段) 卡在"第 3 个任务后不再提交"

## 六、本轮新增
`apply_slotsess.py` / `apply_slotsess2.py` / `run_slotsess.sh` / `run_slotsess2.sh` /
`apply_allocdbg2.py` / `run_allocdbg2.sh`

# 第八轮-23 机制收敛：电源节律 / MMU 假设被推翻 / Restnet50 成为快速试验台（2026-10-05 23:40）

## 一、MMU 假设被**推翻**（重要，省掉一条弯路）

给提交路径加 `HERMES-MMUDBG`（打印本会话页表基址 + 设备当前映射寄存器），实测：

```
sess A id=1 ctx0=1 pc0=0x21ab463 ctx1=5 | REG map_ctx=0x5 map_addr=0x21ab463   ← 对得上
sess B id=3 ctx0=3 pc0=0x21b705c ctx1=7 | REG map_ctx=0x7 map_addr=0x21b705c   ← 也对得上
```

**⇒ 两个会话的页表基址都有效，设备映射寄存器每次都已指向正确的那套。
⇒ "全局映射被互相覆盖" 这个假设**不成立**。**

（顺带确认：`GET_CONTEXT_ID = id%4 + slot*4`，实测 id=1→ctx 1/5、id=3→ctx 3/7，完全吻合。）

## 二、现象**修正**：不是"会话 B 不行"，而是"每个会话的第 1 次提交行、第 2 次不行"

把 MMUDBG 与 `[VHA-SUBMIT] done=` 逐条对齐：

```
submit1  sess A(id=1)  done=1 ✓
submit2  sess A(id=1)  done=0 ✗     ← 同一个会话，一次成功一次失败
submit3  sess B(id=3)  done=1 ✓
submit4  sess B(id=3)  done=0 ✗     ← 同样
```

**⇒ 库在会话间"两两轮转"（A,A,B,B,A,A…），而**每个会话的第 2 次提交都会失败** ⇒ 表现为隔次。**

## 三、机制线索：厂商的电源节律（`NPU_AUTO_SUSPEND_TIMEOUT = 5000`）

```c
void phytium_npu_try_resume_work(npudev)
{
    if (power_status == NPU_STATE_ON)        cancel_delayed_work_sync(&rt_delay_work);  /* 只取消挂起 */
    else if (power_status == NPU_STATE_OFF) { phytium_npu_resume(npudev);  /* ★真正的重新初始化 */
                                              power_status = NPU_STATE_ON; }
}
int phytium_npu_schedule_suspend(npudev, delay_ms);   /* 厂商完成路径以 5000ms 调用 */
```

**⇒ 厂商设计：完成后挂起（5s 后生效）；5s 内有新提交则取消挂起（`power_status` 保持 ON，**不重新初始化硬件**）。**
**⇒ 我们的失败提交**恰好等了 5000ms 超时**，这期间挂起生效（OFF）⇒ 下一次提交走 `resume` 才又能跑 ⇒ 隔次。**

**⇒ 已实现 `HERMES-FORCERESUME`（提交前 `power_status=OFF` 再调 `try_resume_work`，强制走 resume）。实测命中 16 次（`power_status 1 -> 1` = 走了 resume 后回到 ON）。**

## 四、A/B：FORCERESUME **没有**改变 Restnet50 的行为（重要负结果）

同一路径连跑 Restnet50 6 次：

| `vha_force_resume_each_submit` | 结果 |
|---|---|
| 0 | 首条全 0，其余 5 条正常（**不挂死**） |
| 1 | 首条全 0，其余 5 条正常（**不挂死**） |

**⇒ Restnet50 本来就不挂死 ⇒ 之前把它当"失败"是**误判**（它的"失败"是 `argmax=0 max=0.0`＝输出全 0，不是超时）。**
**⇒ FORCERESUME 对 Restnet50 无影响；对 mobilenet 也仍隔次挂死 ⇒ 该补丁目前**未解决问题**，仅保留开关。**

## 五、新的高效试验台：Restnet50

| | mobilenet | Restnet50 |
|---|---|---|
| 现象 | **严格隔次挂死**（每次 5s 超时） | **只首条输出全 0，之后全好** |
| 单次耗时 | ~20ms | ~20-30ms |
| 是否卡 5s | 是（一半次数） | 否 |

**⇒ Restnet50 每次只花 ~25ms、"不到位"的现象是"输出全 0"而不是"卡 5 秒" ⇒ 适合做高频对照线。**
**⇒ 关键子问题：**为什么一次真实的 load 之后，第一次提交的运算没有落地（输出全 0）却仍返回成功？**
（提示：我们的完成判定里 `src=CRC` 路径可能在"缓冲区被复位/未写"时误判为完成 ⇒ 需要加判据。）

## 六·补 新发现：失败那次**硬件其实把命令流读完了**

对比成功/失败两次提交的寄存器快照：

```
[TD-B] before start: CMDREQ_RD=0x0 CMDREQ_RD_WORD=0x0 OUTSTANDING_RD=0x0 MDBG_IDLE=0xffff   ← 两次完全一样
[SUBMIT] done=1 after 7ms    CMDREQ_RD_WORD=0xeff MDBG_IDLE=0xffff FAULT=0x0               ← 成功
[SUBMIT] done=0 after 5002ms CMDREQ_RD_WORD=0xeff MDBG_IDLE=0xffff FAULT=0x0               ← 失败
```

`0xeff = 3839`＝命令流长度（`cmd_words=3839`）。

**⇒ 失败那次的命令读指针同样推进到了**命令流末尾** ⇒ 硬件把整条命令流都取走了，且 `FAULT=0x0`。**
**⇒ 所以失败不是"硬件没取命令"，而是"取完没产出完成事件/没写输出缓冲"。**
**⇒ 这把问题进一步收窄到：命令流**内容**（MMU 翻译后的页是否真的是本会话的 CMDS）、
   或硬件执行到某个子命令后静默停止（例如等一个永远不会来的 buffer 就绪）。**

## 七 下一步（明确）

1. **首条全 0 的判据**：在 `VHA-OURCMP` 等完成判定处，区分"CRC 变化"与"CRC 变化且输出非全 0"；
   若把"全 0"也当完成，就会像 Restnet50 首条那样"成功返回但结果是 0"。
2. **用 Restnet50 高频迭代**：每次 ~25ms，一轮 6 次只需 ~1s ⇒ 适合做"改一点跑一次"的快速对照。
3. **mobilenet 的隔次挂死**是更严重的形态，优先用 Restnet50 把"第 1 次提交不落地"的根因找出来，
   再看它是否同时解释 mobilenet 的隔次。
4. 已排除：MMU 映射覆盖、清 STATUS 位、完成后 suspend、每轮 resume+reset、每轮重配 MMU、FORCERESUME。

## 七、状态

- 设备：`worker=0`、`D 状态=0`；`srcversion=0A85E07FC3E1AE26682CF49`
- 当前参数：`resp_fix=0 vrsp_skip=1 push_enable=1 slot_step=0 slot_reset_on_sync=1
  rsp_on_read=0 rsp_cycle_ms=0 clr_status_before_start=0 mmu_cfg_each_submit=0 force_resume_each_submit=1`
- 新增脚本：`apply_mmudbg.py` / `run_mmudbg.sh` / `apply_forceresume.py` / `run_forceresume.sh`

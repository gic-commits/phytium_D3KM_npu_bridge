# 第八轮-20 硬件"隔次不执行"——交替模式的进一步取证（2026-10-05 23:00）

## 一、本轮排除的三个假设

| 假设 | 实测结果 | 结论 |
|---|---|---|
| 清 `NPU_CH0_STATUS` 位可解除 | 写 1 后读回仍是 1；且值单调递增 `0x1→0x3→0x5→0x7` | **不是 W1C 位，是计数器/只读状态 ⇒ 此路不通** |
| 按厂商节律"完成后 `schedule_suspend`" | 加了 `HERMES-SUSPENDAFTER`（`phytium_npu_schedule_suspend`），仍交替失败 | **无效**（但保留开关 `vha_suspend_after_run`） |
| `vha_reset_each_run=1`（resume+reset） | "跳过"日志消失、复位确实执行（rc=0），仍失败 | **无效** |

## 二、最强的新线索：**严格的"隔次失败"**

mobilenet 在同一 worker 里连跑 4 次：

```
mb1 ✓   mb2 ✗   mb3 ✓   mb4 ✗
```

`[VHA-SUBMIT] done=` 序列：

```
done=1 after 10ms     ✓
done=0 after 5005ms   ✗
done=1 after  7ms     ✓
done=0 after 5004ms   ✗
...（之后换模型/Restnet 的提交全部 done=1）
```

**⇒ 严格交替 ⇒ 强烈指向"乒乓/双缓冲"类状态，而不是随机竞态。**

## 三、已确证的事实（可直接引用的硬数据）

1. **失败的那次提交，参数与成功那次逐字节相同**：
   `i=0 fd=0 sz=602112 iova=0x48200000 / i=1 fd=148 / i=2 fd=147 sz=4000 / i=3 fd=1755 sz=4263168`，
   `CONTROL=0x307f used=0x8001e ctxid=3 stream_size=122848 cmd_words=3839`；
   启动前 `CMDREQ_RD=0 CMDREQ_RD_WORD=0 OUTSTANDING_RD=0 MDBG_IDLE=0xffff` 也相同。
2. **失败时**：`EVENT_STATUS=0x0`、`VHA-CRC-after == VHA-CRC-before`（输出没被写）、
   `EVENT_ENABLE=0x1d000b`（使能正常）⇒ **硬件确实没执行**。
3. **成功时**：`done=1 after 7~11ms src=CRC`。
4. **第一轮与第二轮启动前唯一不同**：`NPU_CH0_STATUS` 0x0 vs 0x1、`NPU_CH0_CONTROL` 0x0 vs 0x307e。
5. **驱动侧**：22 次 `[VHA-SUBMIT]` 里只有 1 次 `[VHA-PUSHRSP]`（其余 done=0 不推）
   ⇒ 库端 `解出key=0`（一条响应都没收到）⇒ `HandleResponse` 无限等 ⇒ 池 30s 超时击杀。

## 四、下一步（按优先级）

1. **验证"交替"的归属**：在一个客户端里**连续 infer 多次**（不重复 load），看是否仍隔次失败；
   再在**两个不同 worker** 里各跑一次（新 worker 首跑一向正常）⇒ 判断是"会话内计数"还是"硬件全局状态"。
2. **对比成功/失败两次提交的"中间态"**：在提交后 1ms 打印
   `NPU_CH0_STATUS / NPU_CH0_CONTROL / EVENT_STATUS / MDBG_IDLE / CMDREQ_RD`，
   看失败那次是否连"启动"都没被硬件受理（对照 `MDBG_IDLE` 是否还在 0xffff）。
3. **查厂商 `phytium_npu_schedule_suspend` 的实现**（`common.c:280`）：
   它是否真的对核做了 power-down / 状态清理；我们的 `vha_suspend_after_run` 是否真的走到。
4. **回到"双缓冲"假设**：检查库是否在两次推理间**交替使用两组 buffer**
   （`[VHA-4COL]` 里的 fd/page 序列在成功与失败两次是否不同）。

## 五、状态

- 当前 `.ko` 含：SLOTSEQ / SLOTRESET / SLOTGAP / SYNCBEAT / REPLAYSAME / PUSHONREAD(+FIX+FIX2) /
  RSPCYCLE / CLRSTATUS / SUSPENDAFTER，**全部带开关**。
- **回归保护的默认值**：`vha_rsp_on_read=0`、`vha_rsp_cycle_ms=0`、`vha_rsp_slot_step=0`、
  `vha_sync_beat_ms=0`、`vha_clr_status_before_start=0`、`vha_suspend_after_run=1`、
  `vha_slot_reset_on_sync=1`、`vha_reset_each_run=0`
- **`Restnet50` 在第二轮起出现 `argmax=0 max=0.0`（输出全 0）** —— 与"硬件没执行"同源，需一并回归验证。
- 重载：先卸 `phytium_npu_platform` 再卸 `phytium_npu`；装回 `modprobe phytium_npu_platform`。

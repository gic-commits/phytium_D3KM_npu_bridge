# 第八轮-21 ★★★ 卡点收敛：两个会话交替，其中一个硬件不执行（2026-10-05 深夜收尾）

## 一、本轮最终确定的结论

1. **sensevoice 挂死不是响应投递问题**，而是**硬件在某些提交上根本不执行**
   （`EVENT_STATUS=0x0`、输出 CRC 不变、`done=0 after 5000ms`）。
2. **现象是严格"隔次失败"**：同一客户端、同一 worker 内连跑 6 次 →
   `1✓ 2✗ 3✓ 4✗ 5✓ 6✗`（`mb_client` 分次跑也一样：mb1✓ mb2✗ mb3✓ mb4✗）。
3. **"隔次"的本质 = 库交替使用两个 session**（`HERMES-MMUCFG` 打印暴露）：
   ```
   [VHA-MMUCFG] sess=...229a2434 ctxid=1   -> 成功
   [VHA-MMUCFG] sess=...bc5a776b ctxid=3   -> 失败
   [VHA-MMUCFG] sess=...35dda296 ctxid=1   -> 成功
   [VHA-MMUCFG] sess=...9ab3988a ctxid=3   -> 失败
   ```
   ⇒ **ctxid=1 的会话每次都行；ctxid=3 的会话每次都不行。**

## 二、本轮排除的修复（都无效，但都留了开关）

| 补丁 | 假设 | 结果 |
|---|---|---|
| `HERMES-CLRSTATUS` | 清 `NPU_CH0_STATUS` 位可解除 | ✗ 写 1 后读回仍 1，且值单调递增 0x1→0x3→0x5→0x7 ⇒ **不是 W1C，是计数器** |
| `HERMES-SUSPENDAFTER` | 按厂商节律完成后 `schedule_suspend` | ✗ 仍交替 |
| `vha_reset_each_run=1` | 每轮 resume+reset | ✗ 复位确实执行（rc=0）但仍交替 |
| `HERMES-MMUCFG` | 每轮重配本次会话 MMU | ✗ rc=0 但失败会话照旧 |

## 三、已确证的硬数据（可直接引用）

- 成功与失败的两次提交，**参数逐字节相同**：
  `i=0 fd=0 sz=602112 iova=0x48200000 / i=1 fd=148 / i=2 fd=147 sz=4000 / i=3 fd=1755 sz=4263168`；
  `CONTROL=0x307f used=0x8001e ctxid=3 stream_size=122848 cmd_words=3839`；
  启动前 `CMDREQ_RD=0 CMDREQ_RD_WORD=0 OUTSTANDING_RD=0 MDBG_IDLE=0xffff` 也相同。
- 失败时 `[VHA-NODONE] EVENT_STATUS=0x0 EVENT_ENABLE=0x1d000b`，
  且 `VHA-CRC-after == VHA-CRC-before` ⇒ **输出一个字节都没被写**。
- 失败的那次提交**驱动不推响应**（22 次 `[VHA-SUBMIT]` 只对应 1 次 `[VHA-PUSHRSP]`）
  ⇒ 库端 `解出key=0`（0 条响应）⇒ `HandleResponse` 无限等 ⇒ 池 30s 击杀。

## 四、下一轮方向（明确）

1. **搞清库为什么用两个会话**：是 `phytium_npu_open` 被调两次（我们每次 open 都新建 session 对象），
   还是库自己开了两个 fd。**看 `[VHA-IOCTL-ENTRY] ... sess=` 的首次出现时序与 open 次数。**
2. **对比两个会话在驱动里的初始化差异**：`mmu_ctx[]`、`context_id`、页表基址、
   `NPU_MMU_CONTEXT_MODULE_ID` 相关寄存器在 ctxid=1 与 ctxid=3 会话上分别是多少。
3. **怀疑点：MMU 上下文/页表在 ctxid=3 上没真正生效**（`rc=0` 只代表函数返回成功）。
   ⇒ 在提交前后打印 MMU 相关寄存器（页表基址、ctx 有效位）做对照。
4. **旁证：`Restnet50` 在第二轮起输出全 0**（`argmax=0 max=0.0`），与"硬件没执行"同源，
   应作为第二条验证线（它比 sensevoice 快得多，适合做高频对照）。

## 五、交接状态

- **回归必须包含"同一 worker 连跑 ≥3 次"**——首跑正常不能算通过（这是今晚最大的方法论教训）。
- 已装补丁（全部带开关）：SLOTSEQ / SLOTRESET / SLOTGAP / SYNCBEAT / REPLAYSAME /
  PUSHONREAD(+FIX+FIX2) / RSPCYCLE / CLRSTATUS / SUSPENDAFTER / MMUCFG
- **当前一轮的参数**：`resp_fix=0 vrsp_skip=1 push_enable=1 slot_step=0 slot_reset_on_sync=1
  rsp_on_read=0 rsp_cycle_ms=0 sync_beat_ms=0 clr_status_before_start=0 suspend_after_run=0
  mmu_cfg_each_submit=1 reset_each_run=0`
- 重载：先 `modprobe -r phytium_npu_platform` 再 `-r phytium_npu`；装回 `modprobe phytium_npu_platform`。
- 控制台已静音（`dmesg -n 1`）：LOAD 16.1s→1.0s，且不再产生 D 状态进程。
- 新脚本：`loop_client.py`（同一进程连跑 N 次）、`run_mmucfg.sh`、`run_susp.sh`、
  `run_clrstatus.sh`、`run_2ndhw.sh`、`run_probe2.sh`、`apply_*.py`

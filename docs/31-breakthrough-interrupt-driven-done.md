# 第八轮-24 ★突破：真根因 = 完成判据用错了（轮询猜，而非中断）已修复

**结论一句话：硬件一直是对的，中断每次都有；错在我们用"轮询猜完成"，猜错的那些次就不推响应，于是库挂死。
改用中断里的 `NPU_INFERENCE_COMPLETE_EVENT` 作完成判据后，单段模型从"严格隔次失败"变成**连跑全绿**。**

---

## 一、决定性实验：中断每次都来（IRQDBG）

给 `phytium_npu_handle_irq`（上半部）与 `phytium_npu_handle_thread_irq`（下半部）加计数打印，
mobilenet 连跑 4 次（当时仍是"1✓2✗3✓4✗"）：

```
[VHA-IRQTOP] #1..#4  status=0x1 mask=0x1d000b
[VHA-IRQTH ] #1..#4  status=0x1 COMPLETE=1 AXI=0 ERR=0 MMU=0 WDT=0 INFERR=0 MEMWDT=0

IRQTOP 次数 = 4        IRQTH 次数 = 4        COMPLETE=1 次数 = 4
[SUBMIT] done=1 after 10ms  ...   ← loop#1
[SUBMIT] done=0 after 5006ms ...  ← loop#2（失败）
```

**⇒ 4 次提交 → 4 次 `NPU_INFERENCE_COMPLETE_EVENT` 中断 ⇒ **硬件每次都执行完成并报了完成事件**。
⇒ "硬件隔次不执行"这个方向（第八轮-19/20/21/22）**被彻底推翻**。**

## 二、真根因：我们的完成判据是"猜"，猜错就不推响应

`vha_real_submit()` 的等待循环只有两个判据：

```c
if (atomic_read(&vha_rsp_served) > served_before) { done=1; src=1; break; }  /* 库已消费过一条响应 */
if (vha_out_crc() != crc0)                       { done=1; src=2; break; }  /* 输出缓冲 CRC 变了 */
```

而**推响应是 `if (done && !vha_sim_mode)` 才做的**。

**⇒ 失败那两次两个判据都不成立 ⇒ `done=0` ⇒ **根本不推响应** ⇒ 库的 `HandleResponse` 永远等不到
⇒ worker 挂死 30s 被击杀 ⇒ 用户态看到 `-3 SERVER(服务端错误)`。**

**⇒ 而"上一轮的响应被库消费"本来就**不是**本轮完成的标志（`vha_rsp_served` 是本轮完成判定里的脏判据）；
"输出 CRC 变化"在输出与上次相同的输入下也不成立（mobilenet 每次 argmax 相同 ⇒ 输出可能逐字节相同）。**

## 三、修复（HERMES-IRQDONE）

```c
/* phytium_npu_common.c —— 中断下半部的完成分支 */
if (status & NPU_INFERENCE_COMPLETE_EVENT) {
    atomic_inc(&vha_irq_complete_cnt);      /* ★ 新增：权威完成信号 */
    phytium_npu_inference_complete(npu_dev);
    phytium_npu_try_excute_queued_stream(npu_dev);
}

/* phytium_npu_uapi.c —— 提交等待循环 */
int irq_before = atomic_read(&vha_irq_complete_cnt);
...
if (vha_use_irq_done && atomic_read(&vha_irq_complete_cnt) > irq_before) {
    done = 1; src = 3; break;               /* 来源=完成中断 */
}
```

参数 `vha_use_irq_done`（默认 1，0644）可一键对照。

## 四、修复效果（同一 worker 内连跑）

| 模型 | 修复前 | 修复后 |
|---|---|---|
| **mobilenet** | `1✓ 2✗ 3✓ 4✗ 5✓ 6✗`（严格隔次，每次失败卡 5s） | **6/6 全绿** |
| **Restnet50** | 隔次失败 | **4/4 全绿**（首条仍输出全 0，见下） |
| 所有提交 | `done=0 after 5000ms` 占一半 | **全部 `done=1 after 5~11ms`** |

**⇒ 这是本轮（乃至第八轮）最实质的进展：单段模型从"隔次失败"到"稳定连跑"，
且失败时的 5 秒空等完全消失（耗时 5000ms → 5~11ms）。**

## 五、顺带修正的两条旧结论

1. **"硬件隔次不执行"不成立** —— 中断 4/4 都有，`CMDREQ_RD_WORD` 也每次都走到命令流末尾。
2. **MMU 全局单寄存器互相覆盖不成立** —— `HERMES-MMUDBG` 实测两个会话的 `pc_base_phys_addr`
   都有效，设备映射寄存器每次都已指向正确会话：
   ```
   sess A id=1 ctx0=1 pc0=0x21ab463 | REG map_ctx=0x5 map_addr=0x21ab463
   sess B id=3 ctx0=3 pc0=0x21b705c | REG map_ctx=0x7 map_addr=0x21b705c
   ```
   （`GET_CONTEXT_ID = id%4 + slot*4` 得到 1/5 与 3/7，完全吻合。）

## 六、剩余问题（已收窄、可攻）

1. **sensevoice（141 段）仍 `-3`**：load 成功、提交 3 段后就停在等响应。
   现在"响应 key 序列"成了决定因素：已用 `vha_rsp_slot_step=2`（推 1,3,5,7…）让 key 递增，
   库侧 `HandleResponse` 仍只走到第 2 次就停 ⇒ 多段语义还差最后一层（下一步用 `gdb_key.py`
   抓"库在第几次注册等待、等哪个 slot、我们的 key 是否在它注册**之前**就被读走"）。
2. **Restnet50 首条输出全 0**：第一个 submit 的 `done` 现在由中断给出（正确），
   但输出缓冲仍是 0 ⇒ 首个 submit 的输出地址/映射可能与后续不同（下一步打印首次提交的
   `ADDR_USED/CMD_BASE` 与输出 fd 的 iova 对照）。
3. `ten_runs.py` 回归与 `verify_npu.py` 需在 IRQDONE 配置下重跑一遍确认。

## 七、教训（已写进技能）

- **该由中断驱动的完成，绝不要用轮询/CRC 去猜** —— 猜错时"不推响应"，用户态只看到超时，
  症状会伪装成"硬件不执行"。
- **`done` 这类判据若同时控制"是否推响应"，判错就是致命的**（本次坑：一半提交石沉大海）。
- **中断路径要给探针**：上半部/下半部各计数一次，一眼就能区分"没中断"与"中断了但走错分支"。

## 八、状态

- 设备：`worker=0`、`D 状态=0`；`srcversion=297B5123976A02AEFCEF624`
- 参数：`use_irq_done=1 rsp_slot_step=2 slot_reset_on_sync=1 push_enable=1 resp_fix=0
  mmu_cfg_each_submit=0 force_resume_each_submit=0 clr_status_before_start=0`
- 新增：`apply_irqdbg.py` / `run_irqdbg.sh` / `apply_irqdone.py` / `run_irqdone.sh` / `run_loopkey.sh`

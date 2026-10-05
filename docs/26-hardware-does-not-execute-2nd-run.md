# 第八轮-19 ★★★★ 真根因定案：第二轮提交后**硬件不执行**（2026-10-05 深夜）

## 一、结论（一句话）

**sensevoice 挂死的根因不是"响应投递"，也不是"多段/多 slot"，而是：
同一个会话里的**第 2 次提交**，NPU 硬件根本不执行（`EVENT_STATUS=0x0`、输出 CRC 不变），
于是驱动没有响应可推，库的 `HandleResponse`/`WaitForCompletion` 无限等。**

## 二、决定性对照实验（mobilenet 连跑两次）

| | 第 1 次 | 第 2 次 |
|---|---|---|
| 结果 | **成功** `argmax=111` 0.02s | **失败** `-3 SERVER` |
| `[VHA-SUBMIT] done=` | `done=1 after 7~11ms` | **`done=0 after 5003ms`** |
| `EVENT_STATUS` | 有事件 | **`0x0`** |
| `VHA-CRC-after` | 变化 | **与 before 完全相同（输出没被写）** |
| `[VHA-NODONE] EVENT_ENABLE=0x1d000b` | — | 事件使能正常，但没有事件 |
| **提交参数（fd/iova/size/CONTROL/stream_size/cmd_words）** | \multicolumn{2}{c}{**逐字节完全相同**} |
| 启动前 `CMDREQ_RD / RD_WORD / OUTSTANDING / MDBG_IDLE` | \multicolumn{2}{c}{**完全相同（0/0/0/0xffff）**} |
| 启动前 `[VHA-TD-A] STATUS / CTRL` | `0x0 / 0x0` | **`0x1 / 0x307e`（上一轮残留）** |

⇒ **唯一差别 = NPU 核残留状态 `NPU_CH0_STATUS=0x1`（+ `NPU_CH0_CONTROL=0x307e`）。**

## 三、为什么之前所有"响应方案"都无效

它们是**下游**：硬件不完成 ⇒ 驱动 `vha_push_response` 不被调用（实测第二轮
`[VHA-PUSHRSP]` 只出现 1 次，而 `[VHA-SUBMIT]` 出现 22 次）⇒ 库 `解出key=0`（一条都没收到）。

## 四、厂商流程 vs 我们的提交路径（差异定位）

厂商 `phytium_npu_submit_stream()`（`common.c:565`）每轮依次做：

```
try_resume_work → config_clock → config_hl_wdt
→ mmu_config_dev_mmu(sess)      ← 我们没做
→ config_dma_address(sess,nstream)  ← 我们没做（我们只写 ADDR0+8/16/24/32）
→ clear_irq_status(NPU_ALL_EVENT)   ← 我们没做
→ config_event(NPU_ALL_EVENT, TRUE) ← 我们没做
→ config_start_inference()          ← 我们做了（写 NPU_CH0_CONTROL，值一致）
```

厂商完成路径 `phytium_npu_inference_complete()`（`common.c:586`）末尾：

```
phytium_npu_response_stream(...)          ← 我们自己做推送
phytium_npu_schedule_suspend(npu, AUTO_SUSPEND_TIMEOUT)   ← ★ 我们没做
```

**⇒ `uapi.c` 里 grep 不到任何 `schedule_suspend`。**
**⇒ 厂商"每轮结束挂起、下轮 resume"的节律被我们省掉了 ⇒ 核停在完成态。**
**⇒ 而我们的 `vha_reset_each_run=1` 只调 `common_resume + hw_reset_self`（rc=0），
实测**并未清掉 `NPU_CH0_STATUS`**（第二轮 before 仍是 `0x1`）。**

## 五、正在验证的修复（HERMES-CLRSTATUS）

`apply_clrstatus.py`：在写 `NPU_CH0_CONTROL` 之前，若 `NPU_CH0_STATUS & 0x1`
则向 `NPU_CH0_STATUS` 写 1（W1C）并打印前后值；另加 `vha_suspend_after_run` 开关。

- `vha_clr_status_before_start`（默认 1）
- `vha_suspend_after_run`（默认 1）

**判据**：mobilenet 连跑 3 次全部成功；`Restnet50` 恢复 `argmax=644`；`VHA-CLRSTATUS` 有命中打印。

## 六、★ 方法论纠错（很重要）

1. **"mobilenet 能跑通"这个基线是靠不住的** —— 我们之前每轮实验都 `systemctl restart npusvc`，
   等于每次都用**全新 worker**。**同一个 worker 里的第 2 次推理一直是坏的**，之前从没测到。
   ⇒ **回归测试必须包含"同一 worker 连跑 ≥3 次"，不能只测首跑。**
2. **`WaitForCompletion` 返回 4 不是错误**：mobilenet（成功）实测也是 `Update(4)` + 返回 4。
   之前把它当成错误分支解读，方向错了。
3. **`DnnProcessSegmentStatus` 的低 16 位判据**：`[VHA-TD-A]` 之外还有一条——
   该函数在 `w4 & 0xffff == 0` 时返回 4；库侧 `status=1/4` 都可能出现，**不能用来判定成败**。
4. **Gemini（免费网页 AI）连问两次都答偏**（会话上下文串到历史话题），
   其"缓存一致性/全零"结论与本轮证据不符（mobilenet 同路径正常）⇒ **本轮未采纳**。

## 七、当前驱动状态（交接必读）

- `.ko` 已含补丁：SLOTSEQ / SLOTRESET / SLOTGAP / SYNCBEAT / REPLAYSAME / PUSHONREAD(+FIX,FIX2) / RSPCYCLE / CLRSTATUS
  —— **每个都带独立开关，默认值以"不破坏 mobilenet 首跑"为准。**
- **默认可绕过项**（回归保护）：`vha_rsp_on_read=0`、`vha_rsp_cycle_ms=0`、`vha_rsp_slot_step=0`、
  `vha_sync_beat_ms=0`、`vha_slot_reset_on_sync=1`、`vha_clr_status_before_start=1`
- 重载铁律：`modprobe -r phytium_npu_platform` **先**，再 `modprobe -r phytium_npu`；
  装回用 `modprobe phytium_npu_platform`（会自动拉 npu）。
- 构建：`make -C /lib/modules/$(uname -r)/build M=<tree> CONFIG_PHYTIUM_NPU=m CONFIG_NPU_PLATFORM=m modules`
- 控制台刷屏已治（`dmesg -n 1`）：LOAD 从 16.1s → 1.0s，且不再产生 D 状态进程。
- 关键探针：`gdb_miss2.py`（丢弃/解出key/HR/GetSlot）、`gdb_slot2.py`、`gdb_wfc.py`（Update/WFC 返回）
- 关键脚本：`run_clrstatus.sh`、`run_2ndhw.sh`、`run_probe2.sh`、`run_buildN.sh`

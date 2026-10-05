# 02 · 硬件"隔次不执行"取证与驱动补丁（2026-10-05 夜）

## 结论（权威）
sensevoice 挂死的**根因不在响应投递**，而在**硬件对一部分提交根本不执行**：
`done=0 after 5000ms` / `EVENT_STATUS=0x0` / 输出缓冲 CRC 一个字节都没变。

现象是**严格隔次失败**（同一进程内连跑：`1✓2✗3✓4✗5✓6✗`），
本质是**库交替使用两个 session**（`sess A ctxid=1` 成功 / `sess B ctxid=3` 失败）。

**首要嫌疑**（见 docs/29）：`NPU_CH0_MMU_MAPPING_CONTEXT` / `NPU_CH0_MMU_MAPPING_ADDR`
是**全局单寄存器**，两个会话交替时互相覆盖；厂商每轮提交都重配一次映射，我们没有。

> 阅读顺序：docs/26 → 27 → 28 → 29；docs/24/25 是当晚更早的结论（CMA 死锁 / 绕过方案），
> 部分已被 26 之后的证据**取代**（例如"卡在 CMA 分配"其实主要是控制台日志洪水 + 后续状态问题），
> 保留作为过程记录。

## 关键探针
| 脚本 | 作用 |
|---|---|
| `gdb_miss2.py` | 库接收线程：响应被丢弃次数 / 解出的 key / HandleResponse 次数 / GetSlot |
| `gdb_slot2.py`  | 读 `VhaDnnTask::GetSlot()` 真实返回值 + 各关键计数 |
| `gdb_wfc.py`    | `WaitForCompletion` 进出与 `Update(1)/(4)` 计数 |
| `loop_client.py`| **同一进程内连续推理 N 次**（发现隔次失败的关键工具） |
| `mb_client.py` / `mb_pool.py` | 单次 load+infer 客户端 |
| `sv_pool.py`    | sensevoice 客户端 |

## 驱动补丁（全部带独立开关，可回退）
| 补丁 | 作用 | 实测结果 |
|---|---|---|
| `apply_slotseq.py` | 响应 `[+2]` 的 slot 全局单调递增（库按 `GetSlot()` 逐个等） | key 对齐成功（1,3,5…） |
| `apply_slotreset.py` | 库 arm `OUTPUT_SYNC` 时重置序号 | 辅助 |
| `apply_slotgap.py` | 按静默间隔重置序号 | 辅助 |
| `apply_replaysame.py` | 重放保持同 slot | ✗ |
| `apply_pushonread.py`(+2,+3) | 读一条再推下一条 | ✗（且暴露了状态机未复位的 bug） |
| `apply_rspcycle.py` | 定时器循环推送 key | ✗ |
| `apply_syncbeat.py` | output-sync fd 心跳 | ✗ |
| `apply_clrstatus.py` | 启动前清 `NPU_CH0_STATUS` | ✗（该寄存器不是 W1C，是计数器） |
| `apply_suspendafter.py` | 完成后按厂商节律 `schedule_suspend` | ✗ |
| `apply_mmucfg.py` | 每轮提交前重配本会话 MMU | 暴露了"两会话交替"，本身未生效 |

## 运行脚本
`run_first_sv.sh`（干净启动首跑取证）、`run_probe2.sh`（参数正确的 gdb 探针壳）、
`run_buildN.sh`（打补丁+重建+断言式重载）、`run_2ndhw.sh`（第二轮硬件侧取证）、
`run_mmucfg.sh` / `run_susp.sh` / `run_clrstatus.sh` / `run_rcycle.sh`

## 铁律（本轮新增）
1. **回归必须"同一 worker 连跑 ≥3 次"**，首跑正常不算通过（历轮都重启服务 ⇒ 假基线）。
2. **交替成功/失败 = 两组对象在轮换**，不要去调时序参数，要逐字段对账两组对象。
3. 判"硬件跑没跑"看 **输出 CRC 是否变化** + `EVENT_STATUS`，不要看上层报错。

# 第八轮-15 ★ 完成信号已在发，疑似转入"重试循环"（2026-10-05 晚）

## 一、实测（`gdb_w20.py`，免重载）

断点：`base+0x1d3f0`（`str w20,[sp,#144]`，段数）与 `base+0x1dfc0`（`Update(this,1)`，完成置位）。

```
[SETUP] base=0x7f65a06000  W20=0x7f65a233f0  UPD=0x7f65a23fc0
[W20] 段数 = 4
[W20] 段数 = 1
[UPD] Update(status=1) 第 1 次
[W20] 段数 = 8
[W20] 段数 = 1
[UPD] Update(status=1) 第 2 次
[W20] 段数 = 8
[W20] 段数 = 1
[UPD] Update(status=1) 第 3 次
...  （8,1 循环；UPD 累计 7 次）
```

**⇒ 每任务段数 = 8；`Update(status=1)`（完成）被**反复置位**。**
**⇒ `W20` 呈 `8,1,8,1,…` 重复 ⇒ 库在**重试/重放循环**里。**

## 二、推论（与之前的判断不同）

原先认为卡在 `VhaNotifyImp::WaitForCompletion` 等不到完成。
现在看：**完成状态确实被置位了**（7 次），而且循环在重复 ⇒
**更像"执行跑完了但结果不被接受 ⇒ 重试 ⇒ 直到 30s 超时"**，而不是死等。

需要复核的点：
- `WaitForCompletion` 的等待与 `Update` 的置位是否真的配对（`notify` 只在 `Signal()` 里出现，
  偏移 `+0x98`；而 `Execute` 的 lambda 通知的是 `*(obj)+0xd8`）——
  **若配对失败，则 waiter 靠"定时等待/轮询"醒来**（`WaitForCompletion(timeout>0)` 才走定时路径）。
- `VhaNotifyImp::GetStatus()` / `GetLastError()` / `IsTimingOut()` 的返回值，看库自己认为失败原因是什么。

## 三、下一步（最有价值）

1. **在 `VhaNotifyImp::WaitForCompletion` 返回处下断点，打印返回值**（`w0`）——
   0 成功 / 其它即错误码。若返回 0 却仍重试 ⇒ 问题在结果校验。
2. **在 `GetLastError`/`GetStatus` 下断点**打印内容，拿到库自认的失败原因（可能有字符串）。
3. **在 `Update` 的两处调用点**分别统计（`status=1` 与 `status=4`），
   看是否出现 `status=4`（另一条完成/错误路径，`0x1ed64`，条件 `[sp,#212]==4`）。
4. 若确认是"结果不正确导致重试"，则焦点从"响应投递"转到**输出缓冲区/CRC/数值比对**。

## 四、当前状态

- `.ko`：`srcversion=65AF4BC491B212C74F54A5D`
- 参数：`resp_fix=0 vrsp_skip=1 push_enable=1 slot=1 step=1 max=16 replay=15 replay_ms=60 settle=0`
- **调参走 sysfs 勿 rmmod；`replay` ≤个位数**（防 `cma_alloc→flush_work` 死锁 ⇒ D ⇒ 重启）
- 脚本：`gdb_w20.py` + `run_w20.sh`（免重载，可直接复用）

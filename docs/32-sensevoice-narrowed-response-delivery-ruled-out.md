# 第八轮-25 sensevoice 收窄：响应投递已证明是通的，只剩"key 数值对齐"

## 一、已排除：响应投递（不是问题）

驱动里本就有 `[VHA-READ]` 探针。sensevoice 实测：

```
[VHA-READ] sess=000000000fba9685 id=13 len=32 empty=0 list_head=...
（6 次，每次 empty=0）
  库读取次数 = 6      submit=3      push=6（3 次推送 × 2 行日志）
```

且 `phytium_npu_read()` 里 `copy_to_user` 之后确有 **`list_del(&rsp->stream_rsp_list_entry);`** 摘链。

**⇒ 库确实在读、也确实把响应取走了（读到 32 字节的 `npu_user_rsp`）。**
**⇒ "库没读 / 队列没摘链 / 响应丢失" 这三个假设全部排除。**

## 二、厂商官方成功路径**确实会推响应**（此前误以为不会）

```c
static void phytium_npu_inference_complete(struct phytium_npu_dev *npudev)
{
	struct phytium_npu_stream *nstream = npudev->activated_stream;
	struct phytium_npu_session *sess = nstream->session;
	if ((npudev->irq_status != NPU_INFERENCE_COMPLETE_EVENT) || !nstream) return;
	phytium_npu_update_stream_buf_status(nstream);
	nstream->infer_status = NPU_STREAM_INFER_DONE;
	...
	phytium_npu_response_stream(sess, nstream, nstream->nustream.estream.sid, NPU_RSP_OK, 0);  /* ★ */
	phytium_npu_schedule_suspend(npudev, NPU_AUTO_SUSPEND_TIMEOUT);
}
```

**⇒ 官方在完成中断里用**该流真实的 sid** 推响应（`NPU_RSP_OK`，键 `[+2]` = 0 被库丢弃）；
**⇒ 我们自己补推的那条用库给的 sid（`0x10101`，是库自己传的，不是我们造的），键 `[+2]` = slot，被库接受。**
**⇒ ⇒ 两条并存：官方的被丢、我们的被收 —— 这解释了为什么"必须我们自己推"才能让库前进。**

## 三、收窄后的真正卡点：**key（slot）数值整体错位**

现象：sensevoice 提交 **3 段** 后停住；`slot` 推送序列为 **3, 5, 7**（即使模块刚重载、计数器本应从 1 开始）。

**⇒ 说明在"第一次推理推送"之前，计数器已经被自增过（`load` 阶段的提交也走了推响应路径，占掉了 1 和 3）
⇒ 推理阶段的推送序号与库为推理任务分配的 slot **整体错位**。
⇒ mobilenet 之所以 6/6 全绿，正因为**它每次只用 slot=1**（与错位无关，随便推什么都自洽）；sensevoice 需要 1,3,5,… 逐个对齐，错位就立刻卡死。**

已试过的对齐手段与结果：

| 参数 | 效果 |
|---|---|
| `slot_step=2`（1,3,5…递增） | 序号能递增，但**起点错位**（首推=3） |
| `slot_gap_ms=500`（静默复位） | 能复位成 1，但**每段都复位成 1**（段间间隔 >500ms） |
| `slot_reset_on_sync=1` | 在 sensevoice 流程上未触发 |
| `resp_fix=0/1` | 无关（那是 read 出口的遮罩，已关） |

**⇒ ⇒ 结论：靠"我们自己的计数器"去猜库的 slot 必然不稳。**
**下一步应当"从提交请求里直接取库给出的期望 key"**（提交 ioctl 的 payload / 描述符里很可能就带着
该任务的身份），而不是继续调计数器参数。

## 四、顺带发现的一处真实内存泄漏（待修）

```c
list_del(&rsp->stream_rsp_list_entry);
atomic_inc(&vha_rsp_served);
...
if (!rsp->session)
	kfree(rsp);        /* ← 我们补推的响应 session 非 NULL ⇒ 永不释放 */
```

我们自己构造的响应（`rsp->session = sess`）被读走后**不会被释放** ⇒ 每次推理泄漏一个
`npu_user_stream_rsp`。长跑（141 段 × 多次）会累积。**修法：给我们自己造的响应打个标记字段，
读走时按该标记释放**（下一轮一并处理）。

## 五、本轮已验证的好状态（不要回退）

- `HERMES-IRQDONE`（`vha_use_irq_done=1`）：**mobilenet 6/6、Restnet50 4/4**，提交耗时 5~11ms（此前一半卡 5 秒）。
- 已完成的三条排除：MMU 覆盖、硬件不执行、响应投递。
- 设备干净：无 `npuworker` 残留；`ps` 里 12 个 D 状态全是麒麟自带服务（avahi/cups/ksc-defender 等），与 NPU 无关，`loadavg 0.30`。

## 六、下一步（精确）

1. **修 gdb 探针**（`gdb_key.py` 的偏移是很多轮前量的，`libnpusession.so` 若变过就全部错位 ——
   实测这次 `HandleResponse调用=0`，与"驱动侧读到 6 次 read"矛盾 ⇒ 探针已失效）。
   改用符号名断点（`VhaDnnTask::GetSlot` / `HandleResponse`）而非硬编码偏移，先拿到
   **sensevoice 推理阶段库期待的真实 slot 序列**。
2. **改为从提交 payload 取 key**：定位提交 ioctl 里携带任务身份/序号的字段，直接用它填 `[+2]`，
   替掉我们自建的 `vha_alloc_slot()` 计数器。
3. 修第四节的内存泄漏。

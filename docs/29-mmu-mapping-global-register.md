# 第八轮-22 ★★★ 重大嫌疑：MMU 映射寄存器是全局单寄存器，两会话互相覆盖（2026-10-05 23:25）

## 一、发现的代码事实

```c
/* phytium_npu_mm_mmu.c:116-117 */
#define CONTEXT_ID_SHIFT  4
#define GET_CONTEXT_ID(X, D)  ((X)->id % 4 + (D) * CONTEXT_ID_SHIFT)
/* ⇒ 硬件上下文号 = session->id % 4 + mmu_ctx 槽位 × 4 */

/* phytium_npu_dev_mmu.c:78-83 */
static inline void phytium_npu_mmu_setup_dev_config(npudev, int ctxid, u32 pc_phys)
{
    REGWRITE64(npudev, NPU_CH0_MMU_CTRL_BS,         MMU_CTRL_BYPASS_DISABLE);
    REGWRITE64(npudev, NPU_CH0_MMU_MAPPING_CONTEXT, ctxid);    /* ← 单寄存器 */
    REGWRITE64(npudev, NPU_CH0_MMU_MAPPING_ADDR,    pc_phys);  /* ← 单寄存器 */
}

/* phytium_npu_dev_mmu.c:84-98 */
int phytium_npu_mmu_config_dev_mmu(struct phytium_npu_session *sess)
{
    for (i = 0; i < ARRAY_SIZE(sess->mmu_ctx); i++) {
        phytium_npu_mmu_setup_dev_config(npudev, sess->mmu_ctx[i].context_id,
                                         sess->mmu_ctx[i].pc_base_phys_addr);
        phytium_npu_mmu_dev_flush_tlb(npudev, sess->mmu_ctx[i].context_id);
    }
}
```

**⇒ `MMU_MAPPING_CONTEXT` / `MMU_MAPPING_ADDR` 是**全局单组**寄存器（用 ctxid 参数切换指向哪个上下文），
不是"每上下文各一组"。**
**⇒ 两个会话（ctxid=1 / ctxid=3）交替提交时，谁最后配置，映射就指向谁。**

## 二、与实测现象的对应

| 实测 | 解释 |
|---|---|
| 严格"隔次失败"（1✓2✗3✓4✗5✓6✗） | 两个会话严格交替 |
| `[VHA-MMUCFG] sess=... ctxid=1` 成功 / `ctxid=3` 失败 | **成功那个的映射恰好是设备当前指向的那套** |
| 失败时 `EVENT_STATUS=0x0`、输出 CRC 不变 | 设备 MMU 映射错 ⇒ 取不到命令/数据 ⇒ 不执行 |
| 提交参数逐字节相同 | 参数没错，**错的是 MMU 映射状态** |
| `open()` 每次新建 session + `create_new_mmu_context()` | 库开了两个 fd ⇒ 两个 session ⇒ `id%4` 分别是 1 和 3 |

## 三、厂商为什么不会踩到

`phytium_npu_submit_stream()`（`common.c:565`）**每轮提交**都做：

```c
phytium_npu_mmu_config_dev_mmu(sess);      /* 把全局映射切到本次会话 */
phytium_npu_config_dma_address(sess, nstream);  /* 再配本会话的 DMA 地址 */
```

**⇒ 每轮都把"全局映射"重新指向本次会话 ⇒ 永远不会用到别人的映射。**
**⇒ 我们的 `vha_real_submit` 两者都没有（本轮才补了 `mmu_config_dev_mmu`，但补得不完整：
`config_dma_address` 仍缺，且库自身的其它 ioctl 可能在其中穿插再次切换映射）。**

## 四、下一步（精确）

1. **打印两个会话的关键字段**（提交时）：
   `sess->mmu_ctx[0].context_id`、`mmu_ctx[0].pc_base_phys_addr`、`sess->id`。
   **判据**：若失败会话的 `pc_base_phys_addr` 为 0 或与 `MMU_MAPPING_ADDR` 当前值不符，直接坐实。
2. **补 `phytium_npu_config_dma_address` 的等价动作**（需要 `nstream`；可先用
   `sess->mmu_ctx[..]` 里已有的地址重写 `NPU_CH0_ADDR0+…`，或直接复用我们已有的 ADDR 写入序列）。
3. **把 `VHA-OUTPUT_SYNC`(nr=0xa) 的 arm 时机也当成"切换映射"的机会**
   —— 已实测库每轮执行都会 arm 一次（`SetOutputSync` 3 次/轮）。
4. **验收判据**：`loop_client.py` 连跑 6 次 **全绿**；随后 `Restnet50` 恢复 `argmax=644`；
   再跑 `sensevoice` 期待 `load -> True` + `推理 …`。

## 五、交接

- 已装补丁与默认参数见 `NPU-第八轮21`。本文件只新增结论，无新补丁。
- 关键探针对照点：`HERMES-MMUCFG` 打印（`sess`/`rc`/`ctxid`）——**它暴露了"两会话交替"这一结构性事实**，
  是今晚最有价值的单条线索。

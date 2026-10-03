# 18 · 27MB 分配失败：推翻 CMA 碎片化，定位到驱动侧（2026-10-03）

> 承接 `docs/17`。本篇记录**重启后的诊断**，**推翻了 `docs/17` 的"CMA 碎片化"结论**。
>
> **新结论：CMA 完全干净（1012 MB 连续）时 27 MB 仍分配失败；驱动收到请求但 `dma_alloc_coherent` 静默返回 NULL，且 CMA 无报错。**

---

## 一、推翻 CMA 碎片化假设（关键）

**重启后 CMA 完全干净**：
```
CmaFree: 1040336 kB (1 GB 满值)
Node 0, zone DMA32, type CMA: order10 = 253 个块 (≈1012 MB 连续)
   ← 重启前只有 148 个
```

**但 27 MB 仍然失败**：
```
FATAL: failed to allocate 28459008 bytes
Cannot allocate vha memory for TEMPORARY buffer
```

**⇒ 碎片化不是原因**（1012 MB 连续都分不出 27 MB）。

---

## 二、定位到驱动侧

```
[VHA-ALLOC] page=98150 iova=0x603f3000 size=28459008 head=00005a3f   ← 驱动收到请求
cma 失败次数: 0                                                       ← CMA 无报错
```

**⇒ 两个决定性事实**：
1. **驱动收到了 27 MB 请求**（`[VHA-ALLOC]` 日志）
2. **CMA 侧没有失败记录** ⇒ **`dma_alloc_coherent` 返回 NULL 但没走 CMA 路径**

---

## 三、试过无效：`coherent_dma_mask`

**发现**：原代码只设了 `dma_mask`，**没设 `coherent_dma_mask`**：
```c
phytium_npu_platform.c:88:  dma_set_mask(dev, 0xffffffffff);   // 只设了 dma_mask
（无 dma_set_coherent_mask 调用）
```

**补上后**：
```
coherent_dma_mask set to 0xffffffffff  ✓
但报错一模一样
```

**⇒ 无效**。（`dma_alloc_coherent` 用的确实是 `coherent_dma_mask`，但这里不是根因。）

---

## 四、当前卡点：`VHA-ALLOC-DIAG` 一条都没打印

**加了诊断日志**（在 `dma_alloc_coherent` 调用前后）：
```c
dev_info(npu->dev, "[VHA-ALLOC-DIAG] try size=%zu gfp=%#x ...");
e->kvaddr = dma_alloc_coherent(...);
dev_info(npu->dev, "[VHA-ALLOC-DIAG] ret=%p phys=%pad");
```

**结果**：
```
[VHA-ALLOC] 打印了（源码 1317 行）
VHA-ALLOC-DIAG 一条都没打印（源码 1368 行前）
```

**⇒ 说明中间某处 `break` 了**，或者**新模块没被加载**。

**中间只有两处可能 `break`**：
- `1325`: `if (req.size == 0) { retval = -EINVAL; break; }` —— `28459008 ≠ 0`，排除
- `1330`: `if (!e) { retval = -ENOMEM; break; }` —— `kzalloc` 失败？不太可能

---

## 五、下次开机的第一步（已备好脚本）

1. **确认新模块是否真加载**：对比 `/sys/module/phytium_npu/srcversion` 与磁盘
2. **看 `[VHA-ALLOC-RAW]` 是否打印**（源码 1322 行，在 `[VHA-ALLOC]` 之后、`VHA-ALLOC-DIAG` 之前）⇒ 定位 `break` 点
3. 若模块没加载 ⇒ 修重载流程；若加载了 ⇒ 查 `kzalloc` 或 `req.size` 检查

---

## 六、经验

- **"CMA 碎片化"这个结论要撤回** —— 干净 CMA 也失败，说明不是碎片问题。
- **`cma 失败次数: 0` 是关键信号** —— 说明 `dma_alloc_coherent` 没走 CMA 路径。
- **诊断日志"没打印"本身就是线索** —— 说明代码没走到那里，而不是"分配失败"。
- **`dma_set_mask` 与 `dma_set_coherent_mask` 是两回事** —— 前者管 `dma_map_*`，后者管 `dma_alloc_coherent`。
- **设备反复关机 ⇒ 每次开机先做"状态核对"再动手**（模块是否加载、参数是否正确）。

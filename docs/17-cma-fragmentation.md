# 17 · CMA 碎片化：SenseVoice 卡在 TEMPORARY 缓冲分配（2026-10-03）

> 承接 `docs/16`。本篇记录**改 MBS 之后的新卡点**与**根因定位**。
>
> **结论：`Buffer ID` 校验已通过（改 MBS 生效），新卡点是 CMA 碎片化 —— 库先做 1300+ 次小分配把 CMA 切碎，再要 27 MB 连续块，`cma_alloc` 返回 `-16`。**

---

## 一、突破：改 MBS 的 `0x368`（段IO要求）让校验通过

`docs/16` 里改 `0x358`（容量）无效。**改 `0x368`（段IO要求）有效**：

```
改前: Buffer ID: 10 exceeds its capacity (418608 vs 835584)   ← main_10
改后: FATAL: failed to allocate 28459008 bytes                ← main_10 过了！
      Cannot allocate vha memory for TEMPORARY buffer
```

**⇒ `Buffer ID` 校验消失，前进到缓冲分配阶段。**

---

## 二、新卡点：CMA 碎片化

### 现象
```
CmaFree: 655760 kB (640 MB)          ← 空间够
FATAL: failed to allocate 28459008 bytes (27.1 MB)
cma: cma_alloc: alloc failed, req-size: 6948 pages, ret: -16   ← EBUSY
```

### 根因（已定位）
```
alloc#1301 size=835584      (0.8 MB)
alloc#1302 size=1632
alloc#1303 size=278016
alloc#1304 size=1815616     (1.7 MB)
alloc#1305 size=647328
cma: cma_alloc: req-size: 6948 pages (27.1MB), ret: -16   ← 切碎后要 27MB
```

**⇒ 库先做 1305 次小分配（共 190 MB）把 CMA 切碎，然后才要 27 MB 连续块。**

### CMA 碎片实测
```
Node 0, zone DMA32, type CMA:
  order 10: 148 个块 (4MB)   ← 数量够
  order 9:  21
  ...
需要 27.1 MB = 7 个连续 order-10 块 ⇒ 凑不出
```

### 关键事实
- **CMA 区 = `0x9c400000-0xdc3fffff`（1 GB，在 DMA32）**
- 我们的分配**都在这个区**（已验证）
- **卸载模块后碎片完全不变**（`order-10` 仍是 148）⇒ **不是我们占的**

---

## 三、已试无效的方案

| 方案 | 结果 |
|---|---|
| `__GFP_RETRY_MAYFAIL`（`vha_gfp_tune=1`） | ❌ 报错一字未变 |
| 重载模块（清分配链表） | ❌ 干净状态下也失败 |
| 移走 `/opt/npu/` 下解包副本 | ❌ 库不从那里读 |
| 改 MBS 容量字段（`0x358`） | ❌ 库不读该字段 |
| **改 MBS 段IO要求（`0x368`）** | ✅ **有效**（校验通过） |

---

## 四、下一步方向

1. **驱动侧"大块预留池"** —— 模块加载时预留一大块 CMA，大请求从池里切
   （前提：加载时能分出 27 MB 连续块 —— **待验证**）
2. **增大 CMA**（`cma=2048M` 引导参数 + 重启）—— 需用户操作
3. **用 SG 映射**（驱动已有 `phytium_npu_mmu_map_sg`）—— 让物理分散页映射成连续虚拟
4. **改 MBS 让库减少小分配**（治本，但需理解库的分配策略）

---

## 五、经验

- **改 MBS 要分清"容量"与"要求"两个字段** —— 容量（`0x358`）库不读，要求（`0x368`）才是校验依据。
- **CMA 碎片化与"空闲量"无关** —— `CmaFree` 640 MB 仍可能分不出 27 MB。
- **`cma_alloc` 的 `-16`（EBUSY）= 迁移失败**，不是空间不足。
- **卸载模块不恢复 CMA 碎片** —— 别用它当"复位"手段。

# 19 · 27MB 分配失败：真相定位（2026-10-04）

> 承接 `docs/18`。本篇记录**连续推翻三个假设**、**定位到库的"内存堆"机制**的过程。
>
> **核心结论：驱动侧一切正常（555 次分配全成功），库报 `failed to allocate 28459008 bytes` 是【库自己内部】的判断 —— 与"内存堆（heap）"机制有关。**

---

## 一、连续推翻三个假设

### ❌ 假设1：CMA 碎片化（docs/17）
```
重启后 CMA 完全干净: 253 个 order-10 块（≈1012 MB 连续）
但 27 MB 仍然失败
⇒ 碎片化不是原因
```

### ❌ 假设2：驱动 `dma_alloc_coherent` 失败
```
VHA-ALLOC-DIAG: 1110 条，全部 ret=非0 phys=有效
最大分配: 20447232 (19.5 MB) 成功
⇒ 驱动侧分配完全正常
```

### ❌ 假设3：驱动没收到分配请求
```
（早期误判）"驱动只收到 10 次 ioctl"
真相：dmesg 环形缓冲被冲掉（VHA-CRC 2351 条 + VHA-ALLOC 1962 条）
清空 dmesg 后只跑加载阶段：
  VHA-IOCTL-ENTRY 总条数: 1110
    555 × nr=2 (VHA_ALLOC_MEM)
    555 × nr=7 (VHA_MAP_BUF)
⇒ 驱动确实收到了全部请求
```

---

## 二、关键事实

```
本次加载: 555 次分配, 合计 298.7 MB（全部成功）
库报错:   FATAL: failed to allocate 28459008 bytes
          Cannot allocate vha memory for TEMPORARY buffer

★ 28459008 从未出现在驱动的分配记录里
⇒ 库在【发起分配之前】就拒绝了
```

**`28459008` 的来历**：
```
28459008 = 27.14 MB = 6948 页
28459008 / 208896 = 136.24
28459008 / 228480 = 124.56
```

---

## 三、定位到库的"内存堆"机制

### 驱动的 `VHA_GET_MEM_HEAPS` 实现
```c
case VHA_GET_MEM_HEAPS: {
    struct vha_heap_desc heaps[16];
    memset(heaps, 0, sizeof(heaps));
    heaps[0].base  = 0x80000000;
    heaps[0].type  = 1;   /* unified */
    heaps[0].flags = 1;   /* present */
    copy_to_user(arg, heaps, sizeof(heaps));
}

struct vha_heap_desc {   /* 只有 12 字节，没有"大小"字段 */
    u32 base;
    u32 type;
    u32 flags;
} __packed;
```

### 库的关键串
```
7d2b0 "Heap size has to be page_size aligned!"
7d2d8 "Maximum heap size exceeded!"
7d2f8 "Heap size must be more than 1 page!"
80200 "INFO: Heap :%s (%#x)"                    ← 库打印堆信息
80218 "could not create virtual address heap"
80388 "No heap capable to alloc from"           ← 最终报错
803f8 "Ambiguous allocation flags, using default internal heap!"
```

### 库的分配调用链（反汇编）
```
VhaSessionImp::AllocateMemory (0x121e8)
  → VhaMemoryImp::Allocate (0x14be8)
      → AllocateVhaMem (0x77240)
          → VhaVaaHeapAlloc (0x3fda8)   ← 虚拟地址堆分配
          → ioctl × 4
          → VhaVaaHeapFree / VhaVaaHeapCreate
```

**⇒ 库先用 `VhaVaaHeapAlloc` 从"虚拟地址堆"分配 IOVA，再调 ioctl。**

### 已确认
```
npuworker.log: "INFO: Heap :unified (0x1)"
⇒ 库【识别到了】我们的堆（type=1 unified）
```

---

## 四、已试无效

| 方案 | 结果 |
|---|---|
| `dma_set_coherent_mask` | ❌ 报错不变 |
| `info->l3_size = 512MB`（原为 0） | ❌ 报错不变（但库识别到 `Heap :unified`） |
| `__GFP_RETRY_MAYFAIL` | ❌ 报错不变 |
| 重载模块 / 清 dmesg | ❌ 报错不变 |

---

## 五、下一步

1. **反汇编引用 `No heap capable to alloc from`（`0x80388`）的代码** —— 看库判断"堆可用"的条件
2. **反汇编 `VhaVaaHeapCreate`（`0xa6635`）** —— 看它需要什么参数（堆大小从哪来）
3. 重点怀疑：**`struct vha_heap_desc` 缺少"大小"字段** ⇒ 库用 `base` 推算大小，可能推错

---

## 六、经验

- **`dmesg` 环形缓冲会冲掉早期日志** —— 排查"驱动是否收到请求"时，必须先 `dmesg -C` 再跑，且**只跑目标阶段**（不要跑完整推理）。
- **"驱动侧日志为 0" ≠ "驱动没执行"** —— 先排除日志被冲。
- **库的报错可能在【发起 ioctl 之前】** —— 驱动侧看不到对应请求时，要往库的内部逻辑找。
- **`INFO: Heap :unified (0x1)` 是重要信号** —— 说明堆描述符被库接受了，问题在更深处。

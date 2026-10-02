# 12 · SenseVoice 上 NPU 的"借壳"路线（2026-10-02 夜）

> **背景**：`docs/10` 的结论是"用 ORT EP 加速 SenseVoice 不成立"（3803 节点只认 1 个）。
> 但那只是**ORT EP 自己编译**这条路的结论。本篇记录**另一条路**：
> 用厂商**离线工具链**编出包，再让**池路径（`npu_client`）加载** —— 即"借壳"。
>
> 一句话现状：**包能编出来、能加载、能解析 IO；卡在"段 IO 声明的缓冲尺寸与库申请的尺寸不一致"。**

---

## 一、为什么"借壳"可行（与 ORT EP 路线的区别）

| | ORT EP 自己编译（docs/10，已否定） | 离线工具链编包 + 池路径加载（本篇） |
|---|---|---|
| 谁决定分段 | EP 的 `GetCapability`（**只认 CNN**，3803 节点只收 1 个） | **厂商 `model_build` 工具**（不受 EP 算子表限制） |
| 分段粒度 | 1 段（就那一个 Conv） | **1600+ 段**（实测 `tvmgen_default_npu_main_0 … _1599`） |
| 加载方式 | `session.run()` | `npu_client.load("sensevoice")` → `init_graph` |

⇒ **关键洞察：EP 的算子支持表不是硬件的限制，只是 EP 的限制。**
离线工具链能把整个 Transformer 编成 1600+ 个 NPU 段 —— 这条路**没有被否定过**。

---

## 二、包结构与已验证事实

### 四件套（与厂商预编译包逐字节同构）

```
sensevoice.json     411,959 B   图（NNVM/PHY 格式）
sensevoice.params 1,591,814 B   参数
sensevoice.so     4,340,288 B   算子库（ELF）
sensevoice.tar      589,373,440 B  元数据包（内含 MBS）
```

### `sensevoice.tar` 内部

```
__internal_io_file__          207 B   输入输出描述
__dependencies_info_file__  101,618 B  依赖信息
npu_mbs.XXXXXX  × 数十个     每个 620 B ~ 8.2 MB
```

### `__internal_io_file__`（运行时看到的 IO）

```json
[
  {"name": "x",      "shape": [1, 200, 560],   "dtype": "float32", "type": "INPUT"},
  {"name": "logits", "shape": [1, 204, 25055], "dtype": "float32", "type": "OUTPUT"}
]
```

### 图规模

- 节点 **849** 个（`tvm_op` 772 + `null` 77）
- **`tvmgen_default_npu_main_0` … `_1599`** ⇒ **1600+ 个 NPU 段**
- 另有 `__copy` / `__copy_1` / `__copy_2`（CPU 侧拷贝节点）

> ⚠️ **订正**：此前"离线工具链只支持单调 2 段、注意力与 FSMN 交错必超段"的结论**不成立** ——
> 实测 SenseVoice 被切成 **1600+ 段**并成功编出包。

---

## 三、★ 本轮修掉的真 bug：释放不真释放（CMA 泄漏）

### 症状

池路径加载 `sensevoice` 时报：

```
FATAL: failed to allocate 20444880 bytes
ERROR: (npu_phydnnAllocateMemory) Cannot allocate memory
ERROR: unable to allocate memory of size 20444880 on device npu
```

`20444880` 正是 `logits [1,204,25055] float32 = 19.50 MB`（输出张量）。

### 根因（实测计数）

```
ALLOC(alloc#) 次数: 732        REL5 释放: 0        REL8 释放: 0        free_allocs: 0
```

**732 次分配、0 次回收。** 驱动里：

```c
case VHA_RELEASE_PG8: {
    e = vha_find_by_page(idx);
    if (e)
        e->mapped = 0;        /* ← 只清标志，既不 dma_free_coherent 也不摘链 */
    ...
}
```

而真正回收的 `vha_free_allocs()` **只在 `release()`（关闭设备）时调用**；
池的 worker 是**长驻进程**，反复 `init_graph` 却从不关设备 ⇒ CMA 被吃干
（`CmaTotal 1 GB` → `CmaFree 665 MB`，累计申请 367 MB 与缺口吻合）。

### 修复（`HERMES-REALFREE`）

新增 `vha_free_one()`：按 `start_page` 找到条目 → **摘链 + `dma_free_coherent` + `kfree`**，
并把 `VHA_RELEASE_PG5` / `VHA_RELEASE_PG8` 从"只清 `mapped`"改为调用它。

```c
static void vha_free_one(struct phytium_npu_dev *npu, unsigned long page_idx)
{
    struct vha_alloc_entry *e, *tmp;
    mutex_lock(&vha_alloc_mutex);
    list_for_each_entry_safe(e, tmp, &vha_allocs, list) {
        if (e->start_page != page_idx) continue;
        list_del(&e->list);
        if (e->dma_handle)
            dma_free_coherent(e->npu->dev, PAGE_ALIGN(e->size), e->kvaddr, e->dma_handle);
        else if (e->kvaddr)
            vfree(e->kvaddr);
        kfree(e);
        break;
    }
    mutex_unlock(&vha_alloc_mutex);
}
```

### 修复效果

| 判据 | 修复前 | 修复后 |
|---|---|---|
| `sensevoice` 加载 | 分配失败 | **`load -> True`（10.6 s）** |
| 释放计数 | 0 | **`VHA-REALFREE` 12 次**（每次加载后成批回收） |
| 回归（小 CNN） | — | 3/3 `cosine=0.999394`（416/407/408 ms） |
| 回归（mobilenet） | — | argmax 111 / nonzero 1000 |

---

## 四、当前卡点：段 IO 声明的缓冲尺寸 ≠ 库申请的尺寸

```
ERROR: (getPHYDNNObject) Initialising dnn network from buffer failed because of:
       Incorrect input buffer, id: 6 Segment: 1.
       Detailed error: Buffer ID: 6 exceeds its capacity.
       It is of size: 457776, but segment IO declares size: 913920
```

### 数字关系（实测）

| 量 | 值 | 说明 |
|---|---|---|
| `x[1,200,560] float32` 实际 | **448,000** | 网络真实输入字节数 |
| 库申请 | **457,776** | ≈ 448000 × 1.0218（对齐后） |
| 段 IO 声明 | **913,920** | = 448000 × 2.04；= 457776 × 1.9964；**= 228480 × 4.0000（精确）** |

同一轮里库还申请了 **228,480**（= 457776 ÷ 2）—— 三个数都是同一块缓冲的不同计量口径。

### 候选成因（按可能性）

1. **编译时 `io.json` 声明与网络真实输入口径不一致**。
   `docs/09` 记录当初的声明是**四个输入**：
   `x[1,200,560] f32` + `x_length[1]` + `language[1]` + `text_norm[1] int32`，
   而包里 `__internal_io_file__` **只保留了 1 个输入 `x`** ⇒ **缓冲编号错位**（报错里的 `Buffer ID: 6` 对不上）。
2. **段 IO 的尺寸口径是"CNV 填充后"**（与 `docs/10` 里 `417792 vs 2445312` 同一家族）。
3. 编译时校准数据只有随机张量（`docs/09` 记录 `x 448,000 B 随机`），可能影响尺寸推导。

### 下一步（排队）

1. **重新编译**：用**工具自产的 `proposed_io.json`** 当模板（`docs/09` 已建议过），
   只声明真实存在的输入，避免四输入/一输入错位；
2. 若尺寸仍不符 ⇒ 在 `io.json` 里**显式声明段 IO 期望的尺寸口径**，或
   在驱动侧对该缓冲按声明尺寸分配（我们已有超配机制，只是此前用错了地方）；
3. 对齐后跑一次推理，与 CPU 金标比（`docs/09` 里 mobilenet 的"余弦 0.35"遗留问题
   **很可能同源** —— 都是输入口径不一致）。

---

## 五、方法记录

- **`npu_client` 的 `load()` 返回 `True` 即代表"图加载成功"**，此时才轮到 IO 缓冲校验；
  报错分阶段（分配 → 校验 → 执行）要分清。
- 池 worker 是长驻进程 ⇒ **任何"只在 close 时回收"的资源都会泄漏**；
  桥接里凡"库会反复调用的释放类 ioctl"，都必须**真释放**。
- 判断"是编译问题还是驱动问题"的一个快判据：
  **看报错发生在 `init_graph` 之前还是之后** —— 之前是驱动/内存，之后是图/IO 语义。

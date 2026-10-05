# 第八轮-18 治本候选方案：绕开 `cma_alloc → lru_add_drain_all → flush_work`

> 前置结论见 `NPU-第八轮17`：CMA 98.5% 空闲却卡在 `flush_work`，链为
> `cma_alloc → alloc_contig_range → migrate_prep → lru_add_drain_all → flush_work`。

## 现状代码（已核对）

分配（`phytium_npu_uapi.c` 约 1550 行）：

```c
gfp_t g = GFP_KERNEL;
if (vha_gfp_tune == 1)      g = GFP_KERNEL | __GFP_RETRY_MAYFAIL;
else if (vha_gfp_tune == 2) g = GFP_KERNEL | __GFP_RETRY_MAYFAIL | __GFP_NORETRY;
e->kvaddr = dma_alloc_coherent(npu->dev, vha_alloc_ask, &e->dma_handle, g);
```

释放（两处：约 293 行、314 行）：

```c
dma_free_coherent(e->npu->dev, PAGE_ALIGN(e->size), e->kvaddr, e->dma_handle);
```

**⇒ 无 IOMMU 平台上 `dma_alloc_coherent` 必然走
`dma_direct_alloc → dma_alloc_contiguous → cma_alloc`，每次都进 `migrate_prep`。**
**⇒ 只要 `lru_add_drain_all` 的 `flush_work` 排不空，这一条 ioctl 就永久 D。**

## 方案 A（推荐，风险低）：驱动侧按尺寸缓存缓冲，**减少 cma_alloc 次数**

**动机**：141 段模型 ≈ 上百次分配，且尺寸高度重复（实测 dmesg 里满是
`size=835584`、`size=229376`、`size=458752`、`size=457776` 这种同一尺寸反复出现）。
**每次 RELEASE 都真还、下次再申请 ⇒ 反复踩 `cma_alloc`。若改成"还的时候留在池里、下次同尺寸直接复用"，
`cma_alloc` 次数能从上百降到个位数。**

实现要点：

1. 新增 `static int vha_alloc_cache; module_param(vha_alloc_cache, int, 0644);`（**默认 0**，避免动到已验证的单段模型）。
2. 新增"停放池"：`struct vha_parked { struct list_head list; void *kvaddr; dma_addr_t dma_handle; size_t size; unsigned long start_page; unsigned long pages; };`
   按 `size` 由小到大挂链（或简单的 64 条数组）。
3. **RELEASE**（293/314 两处）：`vha_alloc_cache` 开 且 `e->size <= CAP` 时，
   把 `kvaddr/dma_handle/size/start_page/pages` 挪进停放池，**不调用 `dma_free_coherent`**；
   仍然做原有的摘链/清 mapped 逻辑（保持对库可见的行为不变）。
4. **ALLOC**：在 `dma_alloc_coherent` 之前先扫停放池，取**第一条 `size >= vha_alloc_ask`** 的复用；
   命中则直接用它的 `kvaddr/dma_handle/start_page/pages`，**跳过 cma_alloc**。
5. **模块退出**：把停放池里所有条目真正 `dma_free_coherent` 掉（避免 module unload 泄漏）。
6. 打印：`[VHA-CACHE] hit size=%zu asked=%zu ord=%d` / `[VHA-CACHE] park size=%zu pool=%d`，
   方便统计命中率与最终 cma_alloc 次数。

**风险点**：
- 复用缓冲的内容是脏的 ⇒ **只能复用到"库会自己写满"的缓冲上**。若库依赖"新分配即零"，会出问题。
  ⇒ 保守做法：先只在**实测反复出现的固定尺寸**上启用（用 `vha_cache_only` 指定尺寸列表），
  或复用前 `memset` 一遍（代价远小于 cma_alloc）。
- 停放内存会常驻 CMA ⇒ 池要有上限（`CAP`/条目数），退出时释放。

## 方案 B（治本但风险高）：改用非 CMA 的连续内存

```c
e->kvaddr = alloc_pages_exact(vha_alloc_ask, GFP_KERNEL | __GFP_COMP);
e->dma_handle = (dma_addr_t)virt_to_phys(e->kvaddr);   /* 无 IOMMU：物理地址即设备地址 */
```

**优点**：完全不走 CMA、不进 `migrate_prep` ⇒ 从根上避开死锁。
**风险（必须先验证，不能盲上）**：
1. **缓存一致性**：`dma_alloc_coherent` 在 aarch64 常返回**非缓存**内存，NPU DMA 直接看得到；
   `alloc_pages_exact` 给的是**可缓存**内存 ⇒ 若驱动/NPU 不做 cache 维护，NPU 会读到旧数据。
   ⇒ **上这条之前必须确认 NPU 是否有一致性端口，或驱动里已有 `dma_sync_*`。**
2. **地址窗口**：设备可能有可寻址范围限制（驱动里已有 `vha_bad_addr` 参数，说明有地址约束）
   ⇒ 需要校验 `virt_to_phys` 落在合法窗口内。
3. 高 order 请求在碎片化后可能失败（`alloc_pages_exact` 不迁移，比 CMA 更容易失败）。

**⇒ 建议顺序：先 A（低风险、可 A/B、不改内存类型），A 若命中率足够高就直接解决；B 作为后备。**

## 验证判据（任一方案都适用）

1. 同一轮里 `cma_alloc` 次数（可用 `VHA-ALLOC-DIAG` 计数）**下降一个数量级**；
2. `ps -eo stat | grep -c '^D'` 在整轮推理后**保持 0**；
3. 客户端 `c.load` / `c.infer` 返回 True 且输出 shape 正确；
4. **回归**：mobilenet / Restnet50 / ppocrv3_cls 仍然全部通过（这三个是当前的金标准）。

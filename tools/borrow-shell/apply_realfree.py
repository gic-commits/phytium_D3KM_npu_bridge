#!/usr/bin/env python3
# 修复：VHA_RELEASE_PG5 / PG8 改为真正释放（摘链 + dma_free_coherent）
import shutil, sys
T = "/home/greatwall/npudrv/tree/drivers/staging/phytium-npu/"
U = T + "phytium_npu_uapi.c"
src = open(U, encoding="utf-8", errors="replace").read()
if "HERMES-REALFREE" in src:
    print("已打过补丁"); sys.exit(0)

shutil.copy2(U, T + "phytium_npu_uapi.c.bak23_prerealfree")

# 1) 新增一个"真正释放单条"的辅助函数（放在 vha_free_allocs 之前）
anchor_fn = "static void vha_free_allocs(void)"
if anchor_fn not in src:
    print("锚点(函数)未找到"); sys.exit(1)
helper = '''/* HERMES-REALFREE: 真正释放单条分配。
 * 原 PG5/PG8 只把 e->mapped 清 0，既不 dma_free_coherent 也不摘链
 * => 库以为释放了，驱动侧内存一直占着；而 vha_free_allocs 只在
 * close() 时调用，池的 worker 是长驻进程 => 732 次分配 0 次回收，CMA 被吃干。 */
static void vha_free_one(struct phytium_npu_dev *npu, unsigned long page_idx)
{
	struct vha_alloc_entry *e, *tmp;

	mutex_lock(&vha_alloc_mutex);
	list_for_each_entry_safe(e, tmp, &vha_allocs, list) {
		if (e->start_page != page_idx)
			continue;
		list_del(&e->list);
		if (e->dma_handle)
			dma_free_coherent(e->npu->dev, PAGE_ALIGN(e->size),
					  e->kvaddr, e->dma_handle);
		else if (e->kvaddr)
			vfree(e->kvaddr);
		dev_info(npu->dev,
			 "[VHA-REALFREE] page=%lu size=%zu freed (ord=%d)\\n",
			 page_idx, e->size, e->alloc_ord);
		kfree(e);
		break;
	}
	mutex_unlock(&vha_alloc_mutex);
}

'''
src = src.replace(anchor_fn, helper + anchor_fn, 1)

# 2) PG5：把 "e->mapped = 0" 改成真正释放
old5 = """\t\te = vha_find_by_page(idx);
\t\tif (e)
\t\t\te->mapped = 0;
\t\tmutex_unlock(&vha_alloc_mutex);
\t\tdev_info(npu->dev, "[VHA-REL5] page_idx=%u %s\\n",
\t\t\t idx, e ? "released" : "absent(ok)");"""
new5 = """\t\tmutex_unlock(&vha_alloc_mutex);
\t\t/* HERMES-REALFREE: 真正释放（原来只清 mapped 标志） */
\t\tvha_free_one(npu, idx);
\t\tdev_info(npu->dev, "[VHA-REL5] page_idx=%u released(real)\\n", idx);"""
if old5 in src:
    src = src.replace(old5, new5, 1)
    print("  PG5 已改")
else:
    print("  !! PG5 锚点未命中")

# 3) PG8：同样处理
old8 = """\t\te = vha_find_by_page(idx);
\t\tif (e)
\t\t\te->mapped = 0;
\t\tmutex_unlock(&vha_alloc_mutex);
\t\tdev_info(npu->dev, "[VHA-REL8] page_idx=%u %s\\n",
\t\t\t idx, e ? "released" : "absent(ok)");"""
new8 = """\t\tmutex_unlock(&vha_alloc_mutex);
\t\t/* HERMES-REALFREE: 真正释放（原来只清 mapped 标志） */
\t\tvha_free_one(npu, idx);
\t\tdev_info(npu->dev, "[VHA-REL8] page_idx=%u released(real)\\n", idx);"""
if old8 in src:
    src = src.replace(old8, new8, 1)
    print("  PG8 已改")
else:
    print("  !! PG8 锚点未命中")

open(U, "w", encoding="utf-8").write(src)
print("已插入 HERMES-REALFREE，备份:", T + "phytium_npu_uapi.c.bak23_prerealfree")
print("  vha_free_one 出现次数:", src.count("vha_free_one"))

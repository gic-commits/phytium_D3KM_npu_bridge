# 第八轮-17 ★★★ 真根因：CMA 分配路径上的内核死锁（2026-10-05 深夜）

## 一、决定性发现：4 个 D 状态 worker 全卡在同一处

`ps -eo pid,stat,etime,comm | grep npuworker`：

```
43470 D 10:03
44334 D 08:03
45277 D 06:00
46575 D 02:51
```

**全部 D（不可中断睡眠），且 `cat /proc/<pid>/stack` 完全一致：**

```
[<0>] __switch_to+0xd4/0x138
[<0>] __flush_work+0x138/0x2c0          ← 永久等待
[<0>] flush_work+0x10/0x18
[<0>] lru_add_drain_all+0x164/0x1c8
[<0>] migrate_prep+0xc/0x18
[<0>] alloc_contig_range+0xf8/0x3c8
[<0>] cma_alloc+0x108..0x11c/0x2e8
[<0>] dma_alloc_contiguous+0x98/0xb0
[<0>] __dma_direct_alloc_pages+0x88/0x200
[<0>] dma_direct_alloc+0x4c/0x58
[<0>] dma_alloc_attrs+0x7c/0xe8
[<0>] phytium_npu_ioctl+0x5ec/0xdb8 [phytium_npu]
[<0>] do_vfs_ioctl / ksys_ioctl / sys_ioctl
```

`/proc/<pid>/syscall`：`29 0x8 0xc0207102 ...`
**⇒ `29` = ioctl，`0xc0207102` = nr=2 = `VHA_ALLOC`（我们路径上的分配 ioctl）。**

## 二、**不是**内存不够 —— CMA 几乎全空

```
CmaTotal:        1048576 kB   (1 GB)
CmaFree:         1032208 kB   (98.5% 空闲！)
MemTotal:       28496124 kB
MemAvailable:   19067012 kB
cmdline: ... cma=1024M zswap.enabled=0 cpuidle.off=1 ...
```

**⇒ CMA 只用了约 16 MB，却分配不出来 ⇒ 卡的不是"没内存"，而是 `flush_work` 等不到那个 work item。**

## 三、工作队列已被堵死（旁证）

```
kworker/u16:2+events_unbound : __synchronize_srcu → synchronize_srcu → fsnotify_mark_destroy_workfn
kworker/u16:4+events_unbound : __synchronize_srcu → synchronize_srcu_expedited → fsnotify_connector_destroy_workfn
全系统 D 状态进程数: 23      loadavg: 5.66 3.75 2.22
```

**⇒ `events_unbound` 的 kworker 卡在 `synchronize_srcu`（fsnotify 路径）⇒ 整条工作队列链路堵死 ⇒
`lru_add_drain_all` 里对每 CPU drain work 的 `flush_work` 永不返回。**
**⇒ 而 `alloc_contig_range` 一进来就无条件调 `migrate_prep() → lru_add_drain_all()` ⇒ 所有 `cma_alloc` 全部陪葬。**

## 四、这解释了什么

| 现象 | 解释 |
|---|---|
| mobilenet / Restnet50 / ppocrv3_cls **能跑通** | 单段模型分配次数少、此前队列还没被堵死 |
| sensevoice / sv0 **挂死** | 141（或 37）段 = 大量 ALLOC；一旦某次 `cma_alloc` 撞上被堵死的 flush_work，worker 就永久 D |
| 池报 `status=14 worker 响应超时` / `status=12` | worker 已经 D 了，不可能再回包 |
| `replay` 大值 ⇒ 更容易 D ⇒ 只能硬重启 | 同样是这条路径：分配次数越多越容易撞上 |
| worker 日志**没有任何错误** | 进程卡在内核里，用户态根本没机会报错 |
| `WaitForCompletion` 返回在 4/1 交替、`SetError=0` | 这是**抓取窗口内还活着**的旧 worker 的表现，不是当前卡点 |

## 五、下一步（按优先，需用户放行重启）

1. **重启设备**（清掉 4 个 D 状态 worker；这是唯一办法）。
2. **干净启动后，第一件事就跑 sensevoice**（不要在跑过别的之后跑），并在**卡住的那一刻**抓：
   - `cat /proc/<worker>/stack`（确认是不是同一处）
   - `cat /proc/<worker>/syscall`（确认 ioctl 命令号与请求尺寸）
   - `dmesg | grep VHA-ALLOC`（看最后成功的分配尺寸）
   **⇒ 目的：找到"触发堵死"的那一次分配。**
3. **评估绕开 `cma_alloc` 的可行性（治本）**：
   - 现状：`phytium_npu_uapi.c:1550` 用 `dma_alloc_coherent(npu->dev, vha_alloc_ask, ...)`
     ⇒ 无 IOMMU 时走 `dma_direct_alloc → dma_alloc_contiguous → cma_alloc` ⇒ 必经 `lru_add_drain_all`。
   - 备选：改用 `__get_free_pages` / `alloc_pages_exact` + `virt_to_phys` 直接拿物理连续内存
     （设备地址就是物理地址），**完全避开 CMA 与 `migrate_prep`**。
   - 轻量备选：`vha_gfp_tune` 调 gfp 标志；或减小/关闭 `vha_overalloc_mul` 降低分配压力。
4. **查工作队列为何被堵死**：`synchronize_srcu` 卡住说明有 SRCU 读者不退出。
   需要在干净启动后**尽早**抓 `echo w > /proc/sysrq-trigger` 的 dmesg（会打印所有 D 任务栈）。

## 六、设备状态（交接必读）

- **`/dev/npu0` 在，模块在**（`lsmod | grep -c phytium_npu` = 2），但**4 个 D 状态 worker 占着会话**。
- 各模型在池路径的实测结论（本轮）：mobilenet ✓ / Restnet50 ✓ / ppocrv3_cls ✓（形状 1,3,48,192）/
  scrfd 未测到 / sensevoice ✗ / sv0(svtest) ✗。
- `sensevoice.tar` = 改建版（能 load）；`sensevoice.tar.bak_20260929` = 原始版（load 就死）；
  `sensevoice.tar.bak_current_1005_2111` = 本次前的改建版副本；`svtest.*` = `sv0.*` 副本。
- 调参一律走 sysfs（0644），**勿 rmmod**；`vha_rsp_replay` ≤ 个位数。
- 新增脚本：`mb_client.py`、`run_baseline2.sh`、`run_vendors.sh`、`run_mb.sh`、`run_sverr.sh`、
  `gdb_segidx.py`、`run_both.sh`、`run_sv0.sh`、`run_origtar.sh`。

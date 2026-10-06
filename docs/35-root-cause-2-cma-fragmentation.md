# 第八轮-28 ★真根因之二：CMA 连续块分配失败 ⇒ 库建网失败（内存碎片化）

**一句话：库为多段模型建网时需要 ~30MB 的**连续**NPU 可见内存（TMP-xx 临时缓冲），
在 CMA 还剩 900MB 的情况下因**碎片化**分配失败（`cma_alloc ... ret: -16`），
导致 `Cannot allocate vha memory for TEMPORARY buffer` ⇒ 建网失败 ⇒ 执行停住。**

---

## 一、决定性证据链（全部实测）

### 1) 库侧错误（`/var/log/npuworker.log`）
```
FATAL: failed to allocate 31252480 bytes
ERROR: (getPHYDNNObject) Initialising dnn network from buffer failed because of:
       Cannot allocate vha memory for TEMPORARY buffer
ERROR: (getPHYDNNObject) Error when creating phydnn network object
ERROR: (npu_phydnnLoadNetworkObject) Error while creating network object
ERROR: unable to create network for function 'tvmgen_default_npu_main_140'
```
（`main_140` / `main_10` / `main_0` 都出现过 ⇒ 是**建网阶段**的失败，与提交/响应无关。）

### 2) 那一笔请求**确实到了驱动**，并且**在驱动里失败**
```
[VHA-ALLOC-ERR] phytium_npu_ioctl: alloc size=31252480 name=TMP-13
[VHA-ALLOC-DIAG] try size=31252480 gfp=0xcc0 ...
cma: cma_alloc: alloc failed, req-size: 7630 pages, ret: -16      ← ★ -EBUSY
[VHA-ALLOC-DIAG] ret=00000000877fed3f phys=0x0000000000000000     ← 失败
```
`7630 页 × 4KB = 31,252,480 B` —— 与库报的尺寸完全一致 ⇒ **是同一笔请求，卡在 cma_alloc。**

### 3) 与"容量"无关
- `CmaFree: 903508 kB / CmaTotal: 1048576 kB`（**86% 空闲**）
- 重载模块后立刻跑第一次，仍然失败 ⇒ **不是被我们自己占满**
- 设备 27.8GB 内存、无 OOM、worker 仅 236MB

### 4) 真因 = **全系统没有 32MB 连续块**（buddyinfo 实锤）
```
规整前（失败时）:
  DMA32   1752 1827 1186  665  276  665  359  336   16    5  134   ← 最大 order-10 (4MB)
  Normal 10132 7002 4538 1266  614  406  571  544  285    0    0   ← 最大 order-8  (1MB)
规整后（成功）:
  DMA32    123  187  227  175  180  144  121  107   88   75  337
  Normal 10021 8520 7933 6516 4727 3621 2712 2094 1651 1631 2926   ← 出现大量 order-9/10
```

### 5) ★ 修复验证：`drop_caches` + `compact_memory` 之后
```
TEMPORARY分配失败 = 0      cma_alloc失败 = 0
worker 日志：ERROR/FATAL = 0（"unable to create network" 全部消失）
```
**⇒ 建网不再失败 ⇒ 根因确认。**

## 二、结论与治本方案

**根因**：多段模型（141 子图）建网时需要**大块连续**NPU 可见内存；
系统运行一段时间后内存严重碎片化，`cma_alloc` 找不到 30MB 连续区 ⇒ 返回 `-EBUSY`。

**治本（按优先级）：**
1. **扩大 CMA**：设备 27.8GB 内存而 CMA 只有 1GB（cmdline `cma=1024M`）。
   建议改 `/etc/default/grub` → `cma=4096M`（或 8192M）+ 重启 —— 启动时 CMA 是**一整块连续区**。
2. **驱动侧池化（推荐）**：在模块加载/首次使用时一次性预留一大块连续内存（如 512MB），
   之后所有 ALLOC 从池内切分 ⇒ 既不碎片化 CMA，也不受后续碎片影响。
   （这正是早前文档"方案A：按尺寸缓存缓冲"的落地。）
3. **运行期缓解**：跑前执行
   ```bash
   sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
   ```
   实测可立刻造出连续块（已列为跑多段模型的**前置步骤**）。
4. 不建议用 `vha_gfp_tune`（实测 RETRY_MAYFAIL 无效，因为 failure 在 CMA 而非普通分配路径）。

## 三、顺带澄清的两个误判
- **"驱动只收到 3 次提交、其它 ioctl 一个都没有"** —— 错。清 dmesg 后实测单次运行是
  **555 次 ALLOC + 555 次 MAP_BUF + 10 次 BUF_OP**。之前的"只有 nr=9"是**日志被洪水冲掉**造成的假象。
  （又一次印证：统计前必须 `dmesg -C`。）
- **"VHA 内存申请只有 10.9MB"** —— 错，那是被冲掉后的残量。

## 四、当前状态
- 内存根因已确认并有可复现的缓解手段（drop_caches + compact）
- 修复后：**worker 日志零错误**，库能正常建网
- 剩余：仍是"提交 3 次后停住"（见第八轮-27 的分析：库的等待登记 vs 我们的推送时序）
- 三种响应键序列（常量 1 / 连续 1,2,3 / 奇数 1,3,5）在内存修好后的对照实验进行中

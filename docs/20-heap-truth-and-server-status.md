# 20 · 堆机制真相 + NPU 侧算通 + 服务端 status 卡点（2026-10-04 第六轮）

> 承接 `docs/19`。上篇定位到"库的内存堆机制"，本篇**彻底解开堆机制**，
> 并**首次证明 SenseVoice 在 NPU 上真实算完**（12ms、CRC 全通过），
> 把卡点从"驱动/内存"推进到"**服务端 status 字段**"。

---

## 一、堆机制彻底解开（推翻 docs/19 的悬疑）

### 1.1 反汇编 `VhaVaaHeapCreate@0x3f9f8`（libnpusession.so）

```asm
3fa04: mov  w20, w2          ; w20 = flags（第3参数）
3fa08: sub  w2, w2, #0x1     ; w2 = size - 1
3fa14: ands w25, w2, w20     ; w25 = (size-1) & flags
3fa18: b.ne 3fc44            ; ★ 非0 ⇒ 跳错误处理，返回 NULL
3fa1c: mov  x19, x1          ; x19 = size
3fa28: udiv x0, x19, x1      ; x0 = size / flags
3fa2c: msub x0, x0, x1, x19  ; x0 = size % flags
3fa30: cbnz x0, 3fc84        ; ★ size 不能被 flags 整除 ⇒ 失败
3fa34: mov  x0, #0x10000000000
3fa38: cmp  x19, x0
3fa3c: b.hi 3fc98            ; ★ size > 1TB ⇒ 失败
3fa40: cmp  x1, x19
3fa44: b.eq  3fcac           ; ★ flags == size ⇒ 失败
```

**判据**：`flags=1` 时要求 `(size-1) & 1 == 0` ⇒ **`size` 必须是奇数**。

| `VHA_VADDR_SIZE` | `(size-1)&1` | 结果 |
|---|---|---|
| `0x40000000`（偶数） | `1` | ❌ `No heap capable to alloc from` |
| `0x40000001`（奇数） | `0` | ✅ 堆创建成功 |

**实测**：设 `VHA_VADDR_SIZE=0x40000001` 后，`No heap capable` 与 `failed to allocate` **双双归零**。

### 1.2 库的堆由 4 个环境变量控制（`CreateVha@0x76b20` 附近）

| 环境变量 | 默认值 | 作用 |
|---|---|---|
| `VHA_VADDR_BASE` | `0x48200000` | 堆基址 |
| `VHA_VADDR_SIZE` | **`0`** | 堆大小 |
| `VHA_VADDR_OFFS` | — | 偏移 |
| `VHA_VADDR_PAGESIZE` | — | 页大小 |

**关键**：`VHA_VADDR_SIZE` **默认值是 0** ⇒ 堆大小为 0 ⇒ 库认为"没有可用堆"。
**这就是此前所有 `No heap capable` 的根源** —— 不是驱动问题，不是 CMA 问题，是**库的环境变量没设**。

### 1.3 调用链

```
CreateVha@0x76b20
  ├─ str xzr, [x19,#136]           ; 先清零 heap.base
  ├─ str w1,  [x19,#136]           ; 再写入 heap.base（来自 VHA_VADDR_BASE）
  └─ getenv("VHA_VADDR_SIZE") → strtoul(...,16) → str w0,[x19,#40]   ; 堆大小
       ↓
  VhaVaaHeapCreate(base=[x19+16], size=[x19+40], flags=1)
       ↓
  AllocateVhaMem@0x77240: ldr w4,[x24,#136]; cbz w4,77578   ; heap.base==0 ⇒ "No heap capable"
```

**实测**：`CreateVha` 被调 275 次，`No heap capable` 仅 2 次（那 2 次是 `VHA_VADDR_SIZE` 未设时的早期调用）。

### 1.4 重要运维事实

`npusvc` 服务**当前未继承**这些变量 —— `export` 只作用于当次 shell，`systemctl restart` 后丢失。
**要持久生效必须写进 systemd unit 或 `/etc/environment`。**

---

## 二、NPU 侧首次证明算通（决定性证据）

设 `VHA_VADDR_SIZE=0x40000001` 后跑 `sensevoice` 推理，`dmesg` 记录：

```
[VHA-SUBMIT] sflags=0xc stype=0x3 sid=0x10101 all=8 in=3 t=97991 soff=0 sfd=0 ssize=0
[VHA-SUBMIT]   fd[0]=97223  fd[1]=95035  fd[2]=97274  fd[3]=1439
[VHA-SUBMIT]   fd[4]=1541   fd[5]=1643   fd[6]=98150
[VHA-SUBMIT] cmd buf page=97991 iova=0x60353000 size=647328 words=20229 crc32=0xd5e41337
[VHA-SUBMIT] i=0 fd=97223 sz=208896    idx=1 iova=0x6004e000 reg=ADDR0+8  type=0x2
[VHA-SUBMIT] i=1 fd=95035 sz=4649728   idx=6 iova=0x5f7bc000 reg=ADDR0+48 type=0x1
[VHA-SUBMIT] i=2 fd=97274 sz=835584    idx=2 iova=0x60082000 reg=ADDR0+16 type=0x2
[VHA-SUBMIT] i=3 fd=1439  sz=417792    idx=3 iova=0x487ad000 reg=ADDR0+24 type=0x2
[VHA-SUBMIT] i=4 fd=1541  sz=417792    idx=4 iova=0x48814000 reg=ADDR0+32 type=0x2
[VHA-SUBMIT] i=5 fd=1643  sz=417792    idx=5 iova=0x4887b000 reg=ADDR0+40 type=0x2
[VHA-SUBMIT] i=6 fd=98150 sz=28459008  idx=7 iova=0x603f3000 reg=ADDR0+56 type=0x2
[VHA-SUBMIT] CONTROL=0x107f used=0x4000fe ctxid=1 sid=0x10101 stream_size=647328 cmd_words=20229
[VHA-RESPFIX] rsp[+2] <- 1
[VHA-SUBMIT] done=1 after 12ms CMDREQ_RD_WORD=0x4f05 MDBG_IDLE=0xffff FAULT=0x0
[VHA-CRC-after] page=98150 size=28459008 crc32=0x3a29a0e8   ← 27MB TEMPORARY
（另有 ~40 条 VHA-CRC-after，全部校验通过）
```

**结论**：
- ✅ 7 个缓冲全部映射成功（含 27MB TEMPORARY `fd=98150`）
- ✅ `FAULT=0x0`、`MDBG_IDLE=0xffff`（引擎空闲 = 已完成）
- ✅ **12ms 完成**，全部缓冲 CRC 校验通过
- ✅ 命令流 `cmd_words=20229`、`stream_size=647328` 正常提交

**⇒ 27MB 分配失败的问题（docs/17/18/19）已彻底解决 —— 根因就是堆大小为 0。**

---

## 三、新卡点：`-3 SERVER` 来自服务端 status 字段

### 3.1 反汇编 `libnpuclient.so: infer_all@0xa000`

```asm
a560: bl  do_request(...)      ; 发请求给服务端
a568: str w0, [sp, #172]       ; 存 do_request 返回值
a580: ldr w0, [sp, #172]
a584: cbnz w0, ac4c            ; do_request 失败 ⇒ 透传该错误码

a588: ldr w0, [sp, #180]       ; ★ 载入服务端响应里的 status
a58c: str w0, [sp, #172]
a590: cbnz w0, af78            ; ★ status != 0 ⇒ w0 = -3 ⇒ 返回 -3 SERVER
...
af78: mov w0, #0xfffffffd      ; -3
af7c: str w0, [sp, #172]
af80: b   ac4c
```

### 3.2 判定

- `-3` **不是** `do_request` 返回的（那条路走 `ac4c` 透传原错误码）
- `-3` 是 `[sp,#180]` 里的**服务端 status 字段**非 0 触发的
- ⇒ **`npuworker` 执行了推理（dmesg 有 CRC 证据），但自己判定失败并回了错误 status**
- ⇒ 且 `npuworker.log` **无任何报错** ⇒ 服务端是**静默**置错

### 3.3 排除项

- ❌ 客户端内存不足：`npu_infer_ex@0xb630` 的 `-3` 是 `malloc` 返回 NULL 时的返回值，但设备 `MemAvailable=16GB` ⇒ 排除
- ❌ 参数校验：`npu_infer_ex` 的 `-5`（`b60c/b61c/b624`）是参数错，不是 `-3`

---

## 四、下一步（第七轮）

1. **查 `npuworker` 为何静默置 status 非 0**
   - 反汇编 `npuworker` 的响应组装路径
   - 或给 `npuworker` 加日志，打印 status 被置非 0 的位置
2. **追 `[sp,#180]` 的写入来源** —— `a540: str w6, [sp, #180]`，需确认 `w6` 是请求参数还是响应字段
3. **持久化环境变量** —— 把 `VHA_VADDR_SIZE=0x40000001` 等写进 systemd unit（否则每次重启服务都丢）
4. **备选**：`OUTPUT_SYNC`(nr=0xa) / `BUF_OP`(nr=9) 的驱动侧实现是否影响 status

---

## 五、设备状态快照（2026-10-04 停机前）

| 项 | 值 |
|---|---|
| `npusvc` | active |
| `vha_sim_mode` | 0 |
| 驱动 `.ko` 补丁 | `HERMES-RESP-FIX` + `HERMES-REALFREE` + `HERMES-OVERALLOC` + `HERMES-HEAP-TUNE` + `HERMES-CMDSIZE-FIX` + `HERMES-GFP-TUNE` |
| `npusvc` 环境变量 | **未继承** `VHA_VADDR_*`（需重新 export 或写 unit） |
| 遗留进程 | 无 |

**回归基线**：`ten_runs.py` 10/10 cosine=0.999394 @~410ms；`verify_npu.py` 3/3；mobilenet argmax 111。

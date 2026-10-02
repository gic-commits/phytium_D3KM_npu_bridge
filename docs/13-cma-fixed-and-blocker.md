# 13 · SenseVoice 借壳路线：CMA 泄漏已修 + 卡点定位（2026-10-02 深夜）

> 承接 `docs/12`。本篇记录两件事：**① CMA 泄漏彻底修好（含"不是我们占的"这一澄清）**；
> **② 当前卡点的精确成因与重编所需的工具链现状**。

---

## 一、★ CMA 泄漏：已彻底修好（并澄清一个误判）

### 修复前（`docs/12` 记录）

```
ALLOC 732 次   REL5 释放 0 次   REL8 释放 0 次   free_allocs 0 次
```

### 修复后实测（连跑 3 次 `sensevoice` 加载）

```
基线:          CmaFree 657996 kB
第 1 次 load:  657996 → 193208 kB   (用掉 464788 kB = 454 MB)   ← 首次加载占住
第 2 次 load:  193208 → 193208 kB   (差 0)                      ← 不再增长
第 3 次 load:  193208 → 193208 kB   (差 0)                      ← 稳定
```

⇒ **只降一次、之后纹丝不动** —— 泄漏消除（修复前是单调下降直到分配失败）。

### ⚠️ 澄清：那 373 MB 常驻**不是我们占的**

排查中发现"重载模块后 `CmaFree` 仍停在 ~666 MB"，一度怀疑回收不彻底。实测：

```
卸载模块后 CmaFree: 666188 kB     ← rmmod 之后仍是 666 MB（纹丝不动）
```

⇒ 说明这部分**不是**我们驱动 `dma_alloc_coherent` 占的（否则 `rmmod` 会全部归还）。
占用者是**系统里其它组件**：

```
ps: /usr/bin/kytensor  RSS 1,998,888 KB (2 GB)      ← 麒麟 AI 运行时
vmalloc: gckOS_AllocateMemory (Vivante GPU 驱动) 4100 KB ×N
         iommu_dma_alloc 4100 KB ×N
```

⇒ **373 MB 是环境基线**（GPU/AI 运行时常驻），不是 bug。**判断 CMA 是否泄漏的正确方法**：
看"连续多次加载后是否单调下降"，而不是"重载后是否回到满值"。

---

## 二、当前卡点：段 IO 声明尺寸 vs 库申请尺寸（2 倍关系）

```
ERROR: (getPHYDNNObject) Initialising dnn network from buffer failed because of:
       Incorrect input buffer, id: 6 Segment: 1.
       Detailed error: Buffer ID: 6 exceeds its capacity.
       It is of size: 457776, but segment IO declares size: 913920
```

| 量 | 值 | 关系 |
|---|---|---|
| `x[1,200,560] float32` 真实 | 448,000 | — |
| 库申请 | **457,776** | ≈ ×1.0218（对齐后） |
| 段 IO 声明 | **913,920** | = 457776 × **1.9964**；= 228480 × **4.0000**（精确） |

### 成因（已定位到编译配置）

编译命令里的量化配置是：

```
-mc $TOOLS/in32out32_d16_w16b16.json
```

`docs/09` 记录其语义为：**输入/输出 32bit 浮点、数据 16bit、系数 16bit**。

⇒ **编译器内部按 16bit 处理数据，对外声明输入输出是 32bit** ⇒ **2 倍口径差**，
正好对应 `913920 / 457776 ≈ 2`。这个配置对图像模型（`docs/09` 的 mobilenet）合适，
但用在 ASR 的 `x[1,200,560] f32` 上就产生了段 IO 与运行时申请的口径冲突。

> ### ★ 就地订正（2026-10-02 深夜）：上面这个归因**站不住**
>
> 深挖后查明：**`913920` 不在任何编译产物里**（`sensevoice.json` / `.params` / `npu_mbs.*`
> 三处、十进制与小端十六进制都搜过，**0 次命中**）⇒ 它是**库运行时算出来的**。
> 而报错是"**库自己申请的** 457776 **小于** 库自己校验要的 913920"
> ⇒ **同一块缓冲，库有两套口径**（一套申请、一套校验）。
>
> 数字关系也更支持"两套口径"而非"简单倍数"：
> ```
> 228480 = 2^7 × 3 × 5 × 7 × 17
> 913920 = 228480 × 4.000000    ← 精确 4 倍
> 457776 = 228480 × 2.003571    ← 不精确
> ```
> ⇒ **结论：这是库内部尺寸口径不一致，不是我们编译配置的问题** ⇒
> **"重编包"大概率不能解决它**（方向应改为"让库按校验口径分配"或反汇编库的 IO 校验路径）。
> 详见 `docs/14`。

### 包结构（实测，用于理解段与拷贝的关系）

```
fname_to_nid: 772 项
  __copy 节点:  421 个    ← CPU 侧段间拷贝
  npu_main 段:  141 个    ← 实际 NPU 段数
consumers:    1128 项
dependency:   849 项（每节点的输入依赖）
```

⇒ TVM 把 Transformer 切成 **141 个 NPU 段 + 421 个段间拷贝**。
**段间拷贝的缓冲尺寸由相邻两段的口径决定** —— 这正是 16bit/32bit 冲突的暴露点。

---

## 三、重编所需的工具链现状（关键约束）

| 项 | 现状 |
|---|---|
| 厂商编译工具链 Docker 镜像 `npu-ftn300-tools` | **2.7 GB**，在 NAS（`npu_ftn300_tools.tar.bz2`），**设备上没有**；仓库明确"不转发" |
| 设备侧 `libnpucompiler.so` | **已有**！`/usr/local/lib/libnpucompiler.so`，11.6 MB，**ARM aarch64**、**not stripped**、**13,670 个符号** |
| `model_build` / `npu_compiler` 可执行前端 | **设备上没有**；demo 包（303 MB）里也没有 |
| 库依赖 | 全是标准库（`libcrypto/libz/libstdc++/libm/libgcc/libc/libdl/libpthread`）⇒ **能在设备上原生跑** |

### 库里的关键符号（说明它具备段处理能力）

```
is_input_node / is_output_node / is_memcpy / is_mmm / is_mmm_dsc_node
is_reshape / is_concat_or_op / is_hw_crop / is_non_q8a_act_node
has_segments_data / has_in_strides / has_out_strides / has_interleave_data
nop_or_io_segbegin / nop_or_io_segend / nop_or_io_netend
linesize_gradient_weights / deconv_dy_split
```

⇒ **两条可选路线**：
- **A**：把 2.7 GB 镜像传到设备（`docker load`），用镜像里的 x86 `model_build` 交叉编译（`docs/09` 的原路）；
- **B**：**直接在设备上调用 aarch64 的 `libnpucompiler.so`**（需自己写一个前端，或找到厂商的 aarch64 CLI）。

> B 的可行性待验证；A 是已验证过的原路，只是要传 2.7 GB。

---

## 四、下一步（排队）

1. **确认重编要改什么**：`-mc` 换成与 ASR 输入口径匹配的配置（或确认是否存在"全 32bit"的配置）；
   同时核对 `io.json` 是否应只声明真实存在的输入（`docs/09` 记当初声明了 4 个输入，包里只留 1 个）。
2. **选 A 或 B 拿到编译前端**（A 稳、B 省）。
3. 重编后按 `docs/12` 的判据验证：`load -> True` → `infer` 成功 → 与 CPU 金标比数值。

---

## 五、方法记录

- **判断"内存泄漏"要看趋势，不要看绝对值**：`rmmod` 后不归零 ≠ 泄漏（可能是环境常驻）；
  正确判据是"连续多次操作后是否单调下降"。
- **`libnpucompiler.so` 是 aarch64 且未 strip** ⇒ 设备侧具备原生编译能力，
  "工具链只能在 x86 容器跑"这个印象**至少对库不成立**（对 CLI 前端成立）。
- 包内 `__dependencies_info_file__` 的三个键（`consumers` / `dependency` / `fname_to_nid`）
  是理解"段如何切、拷贝如何插"的直接材料，值得在改编译配置时对照。

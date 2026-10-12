# 43 — 2026-10-07 ~ 10-12 进展：从「驱动桥接」到「工具链缺陷定性」

> 承接 `42-retrospective-2026-10-06.md`。这六天的主线从「驱动/ABI 桥接」转向
> **「厂商模型编译工具链的数值与图约束缺陷」**，并最终给出**工程最优解**。

---

## 一、结论速览（TL;DR）

| 问题 | 结论 |
|---|---|
| SenseVoice（ASR transformer）能否在 NPU 上跑通？ | **不能**（在当前工具链下），卡点是**工具链缺陷**，非我们的用法 |
| 坏点在哪？ | **attention 的 QK^T / AV**（动态×动态矩阵乘），占真实段 **31.5%** 节点 |
| 为什么绕不过？ | `MatMul` 无 NPU 实现；`Conv` 只能吃**常量权重** ⇒ 动态×动态**数学上无等价实现** |
| 工具链缺陷有哪些？ | ① LUT 超越函数固定标度错位；② mapper 不允许改融合区设备归属；③ 定点精度在真实数据下崩 |
| 工程最优解？ | **CPU**：`50.6 ms`、精度 100%（vs NPU `1472 ms`、精度 `0.80`）⇒ **CPU 快 29 倍** |

---

## 二、关键实测数据（全部一手）

### 2.1 算子支持边界（11 个单算子探针，全部上机 vs ORT）

| 算子 | 落点 | cosine | 判定 |
|---|---|---|---|
| `sqrt` / `div` | HOST 回退 | **1.00000000** | ✅ 精确 |
| `erf` / `Pow(x,2)` / `Pow(2,x)` / `ReduceMean` | NPU | **1.00000000** | ✅ 精确 |
| `exp` | NPU(LUT) | 0.8984 | ❌ |
| `log` | NPU(LUT) | **-0.551** | ❌ |
| `tanh` | NPU(LUT) | 0.9938 | ❌ |
| `sigmoid` | NPU(LUT) | 0.9758 | ❌ |
| `ELU` | NPU(LUT) | 0.6487 | ❌ |
| `MatMul` / `Concat` / `Pad` / `Tile` / `Expand` | 无实现 | — | ❌ |

### 2.2 LUT 超越函数的固定标度缺陷（已定量）

**设备实际计算 `f(x · 2^(E-7))`**，`E = ceil(log2(max|x|))`（该张量在标定样本上的量程档位）：

| 探针输入范围 | 反推有效系数 k | `log2(k)` | 预测 `2^(E-7)` |
|---|---|---|---|
| `[-1, 0.5]` | 0.007833 | **-6.996** | E=0 → `2^-7` ✅ |
| `[-4, 0.5]` | 0.031242 | **-5.000** | E=2 → `2^-5` ✅ |
| `[-12, 0.5]` | 0.124932 | **-3.001** | E=4 → `2^-3` ✅ |

Exp 探针（输入 max=1.62572 → E=1）：
- vs 正确的 `exp(x)`：**max|Δ| = 2.597**
- vs `exp(x·2^-6)`：**max|Δ| = 1.3e-4** ← 铁证

**厂商表佐证**：`phy_nc_sdk/relay_op_to_x100_device.csv` 里 **`elu` 不在表中** ⇒ 走兜底行
`unimplemented,custom,custom,custom,custom` ⇒ 落到日志里的 `customlut`。

### 2.3 矩阵乘重建：真实数据下精度崩

因 `MatMul` 无实现，用 `K 分块广播乘 + Conv(1×1) 常量权重求和` 替代：

| 结构 | 数据 | cosine |
|---|---|---|
| 单块（c=64） | **随机** | **0.999941** |
| 单块（c=64） | **真实** | **0.816183** |
| 8 块并行 | 真实 | 0.796874 |
| 8 块串行累加 | 真实 | 0.801077 |
| 2 块（c=256） | 真实 | 0.486536 |

### 2.4 已排除的 9 个候选（全部实测）

| 候选 | 实测证据 | 结论 |
|---|---|---|
| 16 位定点量化本身 | 按真实档位全张量模拟得 `0.999999` | ❌ |
| 量化标定旋钮 `-wo`/`-nb` | 4 份字节不同产物给出小数 6 位相同的分数 | ❌ |
| 标定样本（单/包络/多段平均） | `0.995222` / `0.994026` / `0.993547` | ❌ |
| LUT 超越函数 | 真缺陷，但只占误差 ~27%、与台阶不相关 | 非主因 |
| 块数 N（1/2/8） | 1 块 0.816、8 块 0.797、2 块 0.487 | ❌ |
| 并行 vs 串行累加 | 0.7969 vs 0.8011 | ❌ |
| 输入整体缩放（1/8×~4×） | 单调变差，s=1 最好 | ❌ |
| 每块通道 c | c=64 优于 c=256 | 次要（保持 ≤64） |
| **权重吸收缩放**（量级放大 16 倍） | CPU 等价 `1.00000000`、编译单段通过、上机 **0.801077** | ❌ **推翻「有效位不足」假设** |

---

## 三、三条硬约束（叠在一起导致无解）

| # | 约束 | 实测证据 |
|---|---|---|
| 1 | **坏点不是"一点"** | 矩阵乘重建占真实段 117/372 = **31.5%** 节点，每个 encoder 层都有 |
| 2 | **按算子改设备归属会崩** | Conv 划 CPU / 换 ELU / 插 Mul → **同一个** `Interleaving mismatch (join:64/output:16)` |
| 3 | **按段分被结构锁死** | 残差结构 `out = in + f(...)` + 客户端单输入 ⇒ 最多切 2 块，切完坏点仍在块内 |

### 3.1 `Interleaving mismatch` 的定性

```
ERROR: (CnnHwBufferAllocator.cpp:991) Interleaving mismatch (join: 64 / output node: 16)
ERROR: While setting join from output: 'layer_reshape_303_crop_to_split_1_bypass_layer_multiply_357'
ERROR: during step: kBuffOffs
```

- 报错里的 **`16` 不是通道数**（实测图里没有任何通道=16 的张量）⇒ 是 **mapper 内部的内存交错粒度**
- **图层面无着力点**（不知道要对齐什么）
- **唯一已知的绕法**：**只改常量/权重、不增删节点**（权重吸收缩放就是这么绕过去的）

### 3.2 ★ 工具链缺陷的「双重坐实」（给厂商的黄金证据）

用**厂商自带的 ORT EP**（`PHYNPUExecutionProvider`，设备自带 onnxruntime 1.20.1）
加载**原始 ONNX**（未经我们任何改写），报出**完全相同的错误**：

```
(NNA_INTERNAL_FUNC) Interleaving mismatch (join: 64 / output node: 16)
While setting join from output: 'img_reshape7_crop_to_split_1_bypass_img_binary63'
during step: kBuffOffs
```

⇒ **最小复现 = 原始 ONNX + 厂商自带 EP，无需我们任何改写** ⇒ 缺陷在厂商侧，与我们的用法无关。

---

## 四、数学结论：动态×动态无等价 NPU 实现

`Conv` 的形式 `out[o,h,w] = Σ_{c,kh,kw} W[o,c,kh,kw]·in[c,h+kh,w+kw]` **要求 W 是常量**。

- 把 K 当权重、Q 当输入 ⇒ 要求 K 常量（但 K 动态）❌
- 把 Q 当权重、K 当输入 ⇒ 要求 Q 常量（但 Q 动态）❌

⇒ **`Conv` 能表达 `QK^T` 当且仅当其中一个操作数是常量**。
⇒ attention 的 QK^T/AV **两个操作数都是动态** ⇒ **没有数学上等价的 NPU 实现**
（除非改模型语义做低秩近似 —— 属"改目标"）。

**对照实测**：
- `Conv` 直接投影（**动态×常量**）：`cosine = 1.000000`、`max|Δ| = 0.00088` ✅
- 广播乘 + `Conv` 求和（**动态×动态**）：真实数据 `0.797~0.816` ❌

---

## 五、性能实测：CPU 快 29 倍

**设备：飞腾 D3000M HL8-C，8 核，麒麟 V10 SP1，自带 ORT 1.20.1**

| 方案 | 实测耗时 |
|---|---|
| **全 CPU（ORT 8 线程）** | **50.6 ms** |
| 全 CPU（单线程） | 124.6 ms |
| NPU 整段（372 节点） | **1472.1 ms** |
| NPU 150 节点 | 1352.0 ms |
| NPU 58 节点 | 488.1 ms |
| **NPU 15 节点** | **467.7 ms** ← **固定开销 ≈450 ms** |

⇒ **CPU 比 NPU 快 29.1 倍**（单线程也快 12 倍）。
⇒ **NPU 每次推理有 ~450 ms 固定开销**（进程/建图/内存分配），与模型大小几乎无关
⇒ **NPU 在 SenseVoice 这个模型规模上完全没有优势**。
⇒ **推论**：当模型在 CPU 上跑得比 450 ms 快时，NPU 就是负收益；
   分段（无论按算子还是按段）每多一段就多付一次固定开销 ⇒ **混合分段通常是负收益**。

---

## 六、给厂商的最小复现（可直接提交）

### 复现 1：`Interleaving mismatch`（无需我们的任何改写）

```bash
# 设备自带 onnxruntime 1.20.1，provider 列表含 PHYNPUExecutionProvider
python3 -c "
import onnxruntime as ort
print(ort.get_available_providers())          # ['PHYNPUExecutionProvider', 'CPUExecutionProvider']
sess = ort.InferenceSession('model.onnx', providers=['PHYNPUExecutionProvider'])
sess.run(None, {'input': data})
"
# 期望：报 (NNA_INTERNAL_FUNC) Interleaving mismatch (join: 64 / output node: 16)
#       While setting join from output: 'img_reshape7_crop_to_split_1_bypass_img_binary63'
#       during step: kBuffOffs
```

### 复现 2：LUT 超越函数固定标度（单算子探针）

```
ELU 探针：输入斜坡 x∈[-12, 0.5]
  期望输出（ORT）：Elu(x)
  实际输出（设备）：Elu(x · 2^-3)     ← 反推有效系数 k = 0.124932 = 2^-3.001
  输入范围改成 [-1, 0.5] ⇒ k = 2^-7；改成 [-4, 0.5] ⇒ k = 2^-5
  ⇒ 规律：k = 2^(E-7)，E = ceil(log2(max|x|))
```

### 复现 3：定点精度在真实数据下崩

```
同一张单块模型，四种同量程输入：
  真实数据（输出满量程 2.94）  → cosine 0.816183
  真实打乱（20.43）            → 0.597339
  均匀随机（819.08）           → 0.386663
⇒ 精度与输出动态范围强相关；但「权重吸收缩放把量级放大 16 倍」无效（0.801 vs 0.797）
```

---

## 七、下一步（可选方向）

1. **工程落地**：SenseVoice 走 CPU（ORT）—— 50.6 ms、精度 100%、无需分段/改图
2. **向厂商反馈**：上述三个最小复现（工具链缺陷，非用法问题）
3. **若必须上 NPU**：需要厂商提供「LUT 输入标度正确」或「动态权重 Conv」的支持
4. **改模型语义**（需拍板）：attention 低秩近似，把 K 固化成常量 ⇒ 可用 `Conv` 表达

---

*本文档由 Hermes 于 2026-10-12 整理，数据全部来自真机实测。*

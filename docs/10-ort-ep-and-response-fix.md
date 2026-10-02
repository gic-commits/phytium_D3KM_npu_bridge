# 10 · 定制 ONNX Runtime 路径：从"数值对但库报错"到定案（2026-10-01 ~ 10-02）

> 承接 `docs/09-model-compile-pipeline.md`。09 讲的是**用厂商工具链离线编包**；
> 本篇讲**另一条路**：用厂商的**定制 ONNX Runtime**（`PHYNPUExecutionProvider`）直接跑 ONNX，
> 以及这条路上我们踩到的**一个真根因**和**一个不可行结论**。
>
> 一句话结论：
> **① 响应里必须回填 task-id（`rsp->ursp +2` 的 u16 = 1 或 4），否则库丢弃整条响应** ——
> 这一个 bug 同时制造了"池路径 `-3 SERVER`"与"ORT 路径 5 秒超时"两种完全不同的症状。
> **② 厂商 NPU 后端只支持 CNN**：SenseVoice（Transformer 编码器）3803 个节点里只有 1 个能上 NPU，
> 用 ORT EP 加速它**不成立**。

---

## 一、这条路的定位

| | 离线工具链（docs/09） | 定制 ORT EP（本篇） |
|---|---|---|
| 输入 | ONNX | ONNX |
| 编译时机 | 你手动跑 `model_build` | **运行时由 EP 自动编译** |
| 产物 | `.json` + `.params` + `.so` | 内存里的网络二进制 + 命令流 |
| 适用 | 想部署固定模型 | 想"直接 `session.run()` 就跑" |
| 限制（厂商手册 §1.1） | 分段限制（见 docs/09） | **只支持静态 shape 的 CNN；只支持静态量化 QDQ（S8S8 优先）** |

**厂商手册**（设备上自带，值得先读）：
`/home/greatwall/下载/kylin/D3000M_NPU/`
- `P-S20250321-D3000M_NPU基于定制onnxruntime的模型部署使用手册.pdf`
- `基于定制onnxruntime模型部署demo.pdf`

手册里最有用的三条：
1. **§2.3 调试开关**：`ort.set_default_logger_severity(0)` 打开 NPU 后端 VERBOSE 日志 ——
   **这是判断"编译到底产出了什么"的唯一可靠依据**（见 §四）。
2. **§4 `unspported_nodes_file`**：把不支持的节点划到 CPU，做 NPU+CPU 异构。
3. **§3.3**：编译/运行报错时，处置办法就是"逐节点划到 CPU 缩小范围"。

---

## 二、★ 真根因：响应里的 task-id 必须回填（一行修复，两个症状）

### 症状（看起来毫不相干，其实是同一个 bug）

| 路径 | 表现 |
|---|---|
| **厂商模型池**（`npu_client` + 预编译包） | `(npu_phydnnWaitForEvent) Error waiting for event! Error reading response from VHA device.` → `phydnnWaitForEvent failed ... nid = -1` → 建图失败 → 客户端看到 **`-3 SERVER`**。**连厂商自己预编译的 mobilenet 都跑不起来。** |
| **ORT EP 路径** | 提交后**死等 5 秒超时**（`[VHA-SUBMIT] done=0 after 5002ms`），**但输出数值仍然正确** ⇒ 极易被误判成"中断/时序问题"而绕远路 |

### 根因

厂商库 `libnpusession` 的 `GetVhaResponse` 取响应 payload（`rsp->ursp`）**偏移 +2 的 u16** 当 task/事件 id，
**`<= 0` 就直接构造 `"Error reading response from VHA device."` 并丢弃整条响应**（实测库只接受 **1** 或 **4**）。
我们的桥接没填这个字段 ⇒ 一直是 0。

### 修复（单行级）

在响应回填处（**必须在计算 `ret_len` 之后、`copy_to_user` 之前**）：

```c
/* HERMES-RESP-FIX */
{
    u16 *ridp = (u16 *)&rsp->ursp;
    ridp[1] = 1;          /* 库只接受 1 或 4 */
}
```

### 修复后实测（一次修复同时治好两处）

| 判据 | 修复前 | 修复后 |
|---|---|---|
| 池路径 mobilenet | `-3 SERVER` | `INFER mobilenet ok: 1 输出 4000 B`，argmax 111、nonzero 1000，**连跑 3 次一致** |
| ORT `verify_npu.py` | run1/run2 5004/5003 ms 超时 | 3/3 **cosine=0.999394**、416/416/407 ms |
| `ten_runs.py` | 0/10 | **10/10 数值全对**（每次 cosine=0.999394、408~428 ms） |
| `done=0 after 5002ms` | 每次都有 | **消失** |
| `Error reading response` / parser 错误 | 有 | **0 / 0** |

> **排查提示**：只要看到"**输出数值是对的、但库报读响应失败或等待超时**"，
> 直接去看响应里那个 id 字段，**不要改中断/时序**。
> 反汇编 `libnpusession.so` 的 `GetVhaResponse` 即可确认它取哪个偏移、接受哪些取值。

---

## 三、★ 不可行结论：**ORT EP** 加速 SenseVoice 不成立（仅限本路径，见文末订正）

### 证据（开 VERBOSE 后一行日志定案）

```
PHYNPUExecutionProvider::GetCapability, number of partitions supported by PHYNPU: 1;
number of nodes in the graph: 3803; number of nodes supported by PHYNPU: 1
```

**全图 3803 个节点，只有 1 个能被 NPU 后端接纳**：

```
唯一被支持的节点: /encoder/encoders0.0/self_attn/fsmn_block/Conv_conv2d
```

其余 3802 个全部回退 CPU，清一色是 Transformer 结构
（`self_attn/MatMul|Softmax|Transpose|Split`、`norm1|norm2/*`、`feed_forward/*`、`gemm_input_reshape_token_*`）。
⇒ 与厂商手册 §1.1 第 5 条**完全吻合：NPU 后端只支持 CNN 模型**。

### 那个"绑不上输出"的报错，两个数都是编译器自己声明的

```
subgraph input  : /encoder/encoders0.0/self_attn/fsmn_block/Conv_to4d : <1,512,204,1>
subgraph output : /encoder/encoders0.0/self_attn/fsmn_block/Conv_conv2d : <1,512,204,1>
Adding node: [Conv]  →  【Generate Binary Stream】→  Build success.
  BUFF 1 :   16384 : Coefficients
  BUFF 2 :  417792 : Network Input
  BUFF 3 : 2445312 : Network Output
  BUFF 4 : 4931584 : Temporary
  BUFF 5 :    8000 : Command Stream
```

报错是 `(npu_phydnnBindingAddOutput) insufficient size of memory buffer (417792 < 2445312)`：

- `417792 = 512×204×1×4` —— **ONNX 声明形状的 F32 字节数**（EP 按它分配输出缓冲）；
- `2445312` —— **厂商 NNA 编译器的 CNV 填充格式**要求的尺寸（≈5.85×）。

⇒ **这是 EP 侧张量分配与厂商编译器声明不一致，内核驱动/桥接不参与。**

### 结论

- **用 ORT EP 加速 SenseVoice 主体（Transformer 编码器）不成立**：能上 NPU 的只有一个 FSMN Conv，占比可忽略。
  这与 `docs/09` 里"离线工具链只支持单调 2 段、注意力与 FSMN 交错必超段"的结论**同向**，两条路指向同一结论。

  > ### ★ 就地订正（2026-10-02 夜）：上面这句里的"同向"**只对了一半**
  >
  > - **对的部分**：**ORT EP 自己编译**这条路确实不行（EP 的算子表只认 CNN，3803 节点只收 1 个）。
  > - **错的部分**：把"`docs/09` 离线工具链也只支持 2 段"当作佐证 —— **该结论已被实测推翻**。
  >   实测：厂商 `model_build` 把 SenseVoice 切成 **1600+ 个 NPU 段**
  >   （`tvmgen_default_npu_main_0 … _1599`）并**成功编出包**（589 MB 四件套），
  >   用**池路径 `npu_client` 加载**即可（`load -> True`）。
  >
  > ⇒ **EP 的算子支持表只是 EP 的限制，不是硬件的限制。**
  > 非 CNN 模型上 NPU 的正确路线是"**离线工具链编包 + 池路径加载**"（"借壳"），见 `docs/12`。
  > 本文档的"不可行结论"**仅适用于 ORT EP 这条路径**，不要外推为"SenseVoice 不能上 NPU"。
- 把那个 Conv 也写进 `unspported_nodes_file` ⇒ 全图回 CPU，模型能跑但**无 NPU 加速**。
- **NPU 的合理用武之地是纯 CNN 负载**（厂商池路径 mobilenet 已验证；ORT 路径小 CNN `cosine=0.999394`）。

---

## 四、常备工具（这几轮新增，以后每次都用）

### 1. 开厂商 VERBOSE 日志（手册 §2.3）

```python
import onnxruntime as ort
ort.set_default_logger_severity(0)          # 0=VERBOSE
so = ort.SessionOptions(); so.log_severity_level = 0
s = ort.InferenceSession(M, so, providers=["PHYNPUExecutionProvider", "CPUExecutionProvider"])
```

它会打印**整条编译流水**与**缓冲清单**，是判断"编译是否真产出"的唯一可靠依据：

```
【Convert to CnnModel】【图预处理】【硬件抽象内存优化】【图优化】【内存分配方案】【Lower to IR】【Generate Binary Stream】
  BUFF 1..5 = Coefficients / Network Input / Network Output / Temporary / Command Stream  (+ TOTAL)
```

**实测缓冲清单对照**（同一套驱动）：

| 模型 | Coefficients | Network Input | Network Output | Temporary | Command Stream |
|---|---|---|---|---|---|
| tiny_cnn（未量化） | 6400 | 49152 | 64 | 33280 | **832** |
| tiny_cnn（QDQ int8） | 3328 | 12288 | 16 | 32768 | **1056**（另有第二个子图 352 B） |
| SenseVoice 的那个 Conv | 16384 | 417792 | **2445312** | 4931584 | 8000 |

### 2. 模型二分脚本

`model_bisect.py`：生成 5 个递进复杂度的 ONNX（单 Conv → +Relu → +MaxPool → 两层 Conv → 全结构），
跑完汇总 `cosine / 写回 / irq / 命令流大小`。用于快速回答"是不是某个算子/某种结构的问题"。

> ⚠️ **命名别叫 `bisect.py`** —— 会遮蔽 Python 标准库 `bisect`，导致 `random`/`numpy` 循环导入报错。

### 3. 命令流全文 dump

驱动里把 `print_hex_dump` 的长度从 64 改成 `e->req_size`（一次性诊断，验完即删），
可拿到完整命令流做逐字节比对。

---

## 五、★ 方法论教训（本轮最大的坑，务必读）

### 1. 跨两次运行做内容比对，**必须先清日志缓冲**

我们曾用"tiny_cnn 的流与 mobilenet 的流逐字节相同"得出**"832 B 只是公共前导块"的错误结论**，
成因是**第二次采集没有 `dmesg -C`**，文件里混进了第一次的内容 —— 比对到的是"自己的影子"。
清干净后重做，两条流**第一个字就不同**。

> 判据：比对前先确认两份数据里的**运行标识**（缓冲地址/页号/计数）不同，否则就是自己的影子。

### 2. "编译 → 重载 → 验证"的脚本**必须断言构建成功**

一套"替换源码 → 编译 → `cp` 到 `/lib/modules` → 重载 → 跑验收"的循环里，
**若编译失败，`cp` 会静默地把上一次遗留的旧 `.ko` 又装一遍** ⇒ 每次"验证"结果都一样，
看上去"每档配置都通过/都失败"，**实际测的是同一个旧模块**。我们因此白饶数小时并发布了错误结论。

每个循环必须断言三件事（缺一不可）：

1. 构建 **0 error**（捕获完整输出，不能只看最后一行 —— 成功时它也会打印 `Leaving directory`）；
2. **`.ko` 确实重新生成**（先 `rm -f` 再判断存在）；
3. **已加载模块的指纹与磁盘一致**：
   `cat /sys/module/<mod>/srcversion` == `modinfo /lib/modules/$(uname -r)/extra/<mod>.ko | awk '/srcversion/{print $2}'`；
   外加**参数表指纹**（`ls /sys/module/<mod>/parameters/`）—— 最能一眼看出装的是哪一版。

**高频构建失败原因**：把一个函数从 `static` 去掉给另一个文件用，却**忘了同步另一个文件**：

```
ERROR: "<symbol>" [<mod>.ko] undefined!
```

⇒ **换源码备份时要整组换（成对的 `.c` 一起），不要混搭。**

### 3. 不要轻信"某个成绩不可复现"的结论，**先用当时刻的源码备份回测**

我们曾拿"两个都晚于成功时刻的构建"做 A/B，然后宣称"老版本也不行 ⇒ 是既有问题"，
把一次**回归**误判成"从未成功"，白绕好几轮。
**A/B 的"旧版"必须是成功时刻那一版。**

### 4. 判据不能只看完成位

坏配置照样能给出 `done=1` 10/10 的"绿色"回归，但 `cosine=0`。
**必须同时看输出数值 / 写回 CRC。**

---

## 六、症状 → 根因速查（本篇相关）

| 症状 | 根因方向 |
|---|---|
| 数值对、但库报 `Error reading response` / 等待超时 | **响应里的 task-id 未回填**（§二） |
| 池路径 `-3 SERVER`，`nid = -1` | 同上（库建图时等响应失败） |
| `insufficient size of memory buffer (A < B)` | **EP 张量分配 vs 编译器 CNF 填充尺寸不一致**（§三）；`B` 来自编译器缓冲清单 |
| `Wrong command stream parser data` | 库解析网络二进制失败 —— 检查**回报给库的缓冲尺寸是否与请求一致**（不要自作主张放大） |
| 缓冲 CRC 前后一致、写回计数全 0、无任何错误标志 | **驱动写入/映射层**；先把"曾能跑"的备份回测排除回归（§五·3） |

---

## 七、本轮结束时设备状态（可复现基线）

- 源码 = **18:00 自洽基线（`bak2_180835` + `bak_1801`）+ 单处 `HERMES-RESP-FIX`**；
- `clean` 构建 + `srcversion` 校验一致（`A7A9539367CE5A3F4B37D5C`）；
- 模块参数表：`vha_bad_addr vha_cmd_page vha_debug vha_int_fixup vha_int_fixup_mode
  vha_reset_each_run vha_settle_ms vha_sim_mode vha_use_repeat`（**无实验参数残留**）；
- `verify_npu.py` 3/3 `cosine=0.999394`；`ten_runs.py` 10/10 数值全对；`mobilenet` argmax 111 / nonzero 1000。

### 已排除的实验方向（留档，别重复走）

| 假设 | 实验 | 结论 |
|---|---|---|
| 库自选地址撞车导致 parser 错误 | 加 `vha_iova_mode`，驱动自算唯一 iova（实测重复数 0） | ❌ parser 错误依旧 ⇒ 撞车不是真因 |
| 回报放大尺寸能让 EP 容量检查通过 | 加 `vha_boost_min`，只放大"大"缓冲 | ❌ 报错一字未变 ⇒ 那个 417792 不是我们回报的尺寸 |
| 回报超配尺寸（6×）能兼顾两边 | 全缓冲回报超配尺寸 | ❌ 任何缓冲被放大都会让库解析失败 ⇒ **回报尺寸必须与请求一致** |
| MMU 上下文号（ctxid）不对 | 强制 `ctxid=0` 重编译 | ❌ 照样失败 ⇒ 无关 |
| 硬件有可解码错误码 | IRQ 里转储一批错误寄存器 | ❌ 全为 0；`err_no=17` 是桥接硬编码的占位值 |
| 模型太复杂/某算子不支持 | 模型二分（单 Conv 起） | ❌ 连单个 Conv 都失败（该结论后被 §二 的真根因解释） |

---

## 八、本文档的订正记录

- **2026-10-02 夜**：第三节的"不可行结论"**仅适用于 ORT EP 这条路径**。
  它曾被用来佐证"离线工具链也只支持 2 段"，而后者**已被实测推翻**
  （SenseVoice 被切成 **1600+ 段**并成功编包，池路径可加载）⇒ 见 `docs/12` 的"借壳"路线。
- **2026-10-02**：本文档曾把"832 B 是公共前导块"当作结论 —— 那是**取证错误**
  （跨运行比对没清 `dmesg`，比对到自己的影子），已在 `docs/11` 的"取证纪律"里记录。

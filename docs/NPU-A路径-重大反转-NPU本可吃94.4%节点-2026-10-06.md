# NPU-A路径 ★★★★★★★ 重大反转：NPU 本可吃下 94.4% 节点（2026-10-06）

## 一、反转的核心事实

| 配置 | EP 认领节点数 | 结果 |
|---|---|---|
| **带** `unspported_nodes_file=/home/greatwall/asr/npu_unsupported_nodes.txt`（**4083 行=全量节点**） | **1 / 3803** | 唯一 1 个节点还在输出绑定处崩（`417792 < 2445312`） |
| **不带**该文件 | **3591 / 3803（94.4%）**，213 个分区 | 认领成功，但**编译器建网失败** |

```
[无文件] PHYNPUExecutionProvider::GetCapability, number of partitions supported by PHYNPU: 213;
         number of nodes in the graph: 3803; number of nodes supported by PHYNPU: 3591

[无文件·运行] (NNA_INTERNAL_FUNC) Failure initialising layer 'img_binary6'
              Failure to initialise dimensions of network
              CNN Model generation failed: std::exception
              (phydnnGenerateMBS) Error when creating phydnn network binary
              Failed to call phydnnCreateNetworkObject!  ⇒ network_object_ is nullptr
              (npu_phydnnBindingAddInput) One or more input to function is null  ⇒ dumped core
```

## 二、由此推翻的旧结论

1. **"NPU 只支持 CNN / 只认领 1 个节点"** —— 这是**我们自己的清单造成的假象**。
   `npu_unsupported_nodes.txt` 有 **4083 行、把全部节点都标为"交 CPU"**，
   等于手工把 NPU 关掉了。（该文件生成于 10-01 19:28，就在"1/3803"结论之前。）
2. **"MatMul 完全不支持"** —— 实测：**单个 MatMul 也能被 EP 认领**（`bk_probe.py` m2，1/1）。
3. **"NPU 上限极低"** —— 实际认领 **94.4%**，真正的限制在**厂商编译器的建网能力**，不在 EP 认领。

## 三、正确做法 = 官方工作流的"逐节点迭代削减"

手册给的流程：
> **先跑 → 看 fallback/失败日志 → 把失败节点写入 `unspported_nodes_file` → 重跑 → 直到全通。**

之前是**一次性把 4083 个节点全写进去**（等于全弃 NPU），应是**每轮只挪最少量的节点**，
让尽量多的节点留在 NPU。

### 迭代算法（建议）
```
清单 = []                       # 从空开始
for round in 1..N:
    跑模型（带清单）
    if 建网成功 and 执行成功: 结束
    从失败日志取出"编不过的节点名"（如 img_binary6）
    把它（及其无法独立编译的邻居）加入清单
```
**注意**：日志里的名字（`img_binary6`、`G*_img_depthconv1`）是**编译器的内部层名**，
需要建立"内部层名 ↔ ONNX 节点名"的映射（可从 `graph_node.txt` / verbose 日志的
subgraph input/output 段落对齐）。

## 四、另外两条已确认的独立缺陷（不依赖上面的迭代）

1. **`11×1` 卷积（FSMN 形态）触发 5.85× 输出缓冲口径错**
   （`bk_probe.py` m4/m5：`409600 < 2396160`、`6400 < 37440`）；
   而 **`1×1` 卷积正常**（m1/m3 都 OK）。⇒ 该形态应优先外包给 CPU。
2. **`MatMul → 1×1 Conv` 改造可被认领且能执行**（m3：2/4 认领 + 执行 OK）
   ⇒ 若迭代后仍有算子不被认领，可用此"借壳"改造。

## 五、文件与证据
- 探针：`/tmp/bk_probe.py`（5 形态建图+跑）、`/tmp/bk_cap.py`（认领数）、`matmul2conv.py`（图手术，**待修**：
  直接改写会破坏拓扑序，checker 报 `input ... is not output of any previous nodes`，需按节点顺序原位替换）
- 模型：`/home/greatwall/model_final2.onnx`（4084 节点）
- 清单：`/home/greatwall/asr/npu_unsupported_nodes.txt`（**4083 行，应当清空重来**）
- 环境：ORT 1.20.1 + `PHYNPUExecutionProvider`

## 六、下一步（最小步，可立刻做）
1. **备份并清空** `npu_unsupported_nodes.txt`（保留原文件为 `.bak_all`）。
2. 带**空清单**重跑，拿到"第一个编不过的层名"与完整错误链。
3. 建立内部层名 → ONNX 节点名映射，把该节点写入清单，重跑；**每轮只加最少节点**。
4. 同时把 `11×1` 卷积（FSMN 的 70 个）**预先**放入清单（已知必然失败）。

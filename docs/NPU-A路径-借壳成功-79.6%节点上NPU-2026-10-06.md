# NPU-A路径 ★★★★★★★ 借壳初步成功：79.6% 节点上 NPU 且零编译错误（2026-10-06）

## 一、方法（"借壳"= 挑对节点集合，让编译器成功，其余全部留给 NPU）

用 `unspported_nodes_file` 作为"白名单的反面"：**只把"编译器处理不了的算子类"交给 CPU，
其余全部留给 NPU**。逐类加回，观察三件事：EP 认领数 / 广播错 / 建网错。

```
NPU 保留的算子                                                  认领数  广播错 建网错
Conv,Relu                                                        140     0     0
+Add                                                             985     0     0
+Mul                                                             1338    0     0
+Sub,Div,Sqrt,Pow                                                1764    0     0
+ReduceMean                                                      2048    0     0
+Reshape,Transpose,Identity                                      3099    0     0   ★
+MatMul                                                          3520    141   211  ✗ MatMul 引爆
```

**⇒ 结论：`MatMul` 是唯一的"编译毒药"；除掉它，其余算子（含 284 个 ReduceMean、
845 个 Add、631 个 Reshape、420 个 Transpose）编译器全部接受。**

## 二、★ 最优配置（配置 A）实测

```
KEEP = Relu,Add,Mul,Sub,Div,Sqrt,Pow,ReduceMean,Reshape,Transpose,Identity
（即：MatMul 与 Conv 交 CPU，其余留给 NPU）
CPU节点=632   NPU候选=3452   EP实际认领=3029/3803 = 79.6%

错误统计：insufficient size=0  BindingAddOutput=0  Model generation failed=0  broadcasted=0   ← ★ 全零
NPU 分区实际执行：Process cost 950809us / 957223us / 1874531us …，累计 4.70 s   ← ★ NPU 真的在算
```

**⇒ ⇒ 相比此前的 `1/3803`，NPU 占比从 **0.03% 提升到 79.6%**。**

## 三、当前唯一残留问题：执行末尾**段错误**

- `dmesg` 中**没有** segfault/oops 记录（是用户态 abort）
- `MemAvailable=17.5 GB`、`CmaFree=1.03 GB` ⇒ **不是内存问题**
- EP 把图切成 **564 个分区**（NUMA 往返多），并出现一个 **1.87 s 的超大分区**

**⇒ 怀疑方向（待验证）**
1. 分区数过多（564）导致 EP 收尾阶段出错；
2. 某个超大分区的中间缓冲超出 EP 的分配能力；
3. 输出张量回收路径的空指针（日志里多处 `SetPhyOutputML nullptr`）。

## 四、下一步
1. **抓崩溃现场的 C 栈**（gdb / core / `faulthandler`）—— 定位到具体函数。
2. **降低分区数**：把 `Reshape/Transpose/Identity` 交回 CPU（它们只是搬运，不贡献算力），
   看崩溃是否消失、NPU 占比是否仍可接受（预计仍有 ~2000 节点）。
3. **把 Conv 留在 NPU 的对照**（配置 B：认领 3099）—— 若 11×1 绑定错消失则更好。

## 五、重要更正（承接回溯）
- `npu_unsupported_nodes.txt` 原为 **4083 行 = 全量节点全部外包** ⇒ 造成"NPU 只认 1 个节点"的假象。
  已备份为 `.bak_all`。
- 本文件提出的"逐类加回"策略已实测有效，是**当前唯一被验证能大幅提高 NPU 占比的方法**。

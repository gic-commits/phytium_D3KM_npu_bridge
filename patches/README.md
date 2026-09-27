# 补丁说明（内核驱动侧）

## 文件

- `0001-vha-bridge.patch` — **唯一必需**的补丁：对上游 `phytium_npu_uapi.c` 的完整修改
  （VHA 兼容桥接 + 提交描述符解析 + 寄存器编程 + 完成判定/看门狗 + 取证打点）
  - 规模：**1216 行（+1137 / −4）**，40055 字节
  - 目标文件：`drivers/staging/phytium-npu/phytium_npu_uapi.c`

## 基线核对（打补丁前先验 md5，防止版本错配）

| 状态 | 字节 | md5 |
|---|---|---|
| 上游基线 `phytium_npu_uapi.c` | 11260 | `9112ba15693d38bafb784ba8e1aedaaa` |
| 打补丁后（本项目） | 48123 | `acdff075f00d0b5ae3e182c02794ff78` |

```bash
md5sum drivers/staging/phytium-npu/phytium_npu_uapi.c     # 应为 9112ba15…
patch -p1 --dry-run < 0001-vha-bridge.patch               # 先干跑
patch -p1 < 0001-vha-bridge.patch                         # 若基线一致则干净应用
# 或直接覆盖（等价）：cp ../src/phytium_npu_uapi.c drivers/staging/phytium-npu/
```

若你的上游文件 md5 不同（不同内核/发行版快照），**不要强行 `patch`**：
拿 `src/phytium_npu_uapi.c` 与本补丁对照着移植，重点看补丁里 `[VHA-*]` 打点所在的函数
（它们标出了所有改动点）。

## 已知未包含的改动

- `phytium_npu_common.c` 里曾加 **一行 IRQ 日志**（`[VHA-IRQ] tick=%d status=%#x activated=%p`），
  用于证明"事件每次都到、是 top-half 抢读清掉的"。它**不影响功能**，
  diff 待设备在线时从设备侧生成（设备路径见 `docs/08-reproduce.md`）。
- 除上述两个文件外，其余驱动文件**未改动**。

## 补丁内容速览（按函数）

| 区域 | 作用 |
|---|---|
| `vha_*` ioctl 兼容层 | 把 VHA（`type='q'`）命令映射到驱动等价操作：属性 / 分配 / 映射 / `SET_BUF` / `SYNC_BUF` / 取消 |
| `vha_real_submit()` | 解析 272/328 字节提交描述符 → 编程 `CMD_BASE`/`ADDR*`/`CONTROL`/事件寄存器 |
| `vha_install_dummy()` | 合成"持久 stream"以复用官方 IRQ 完成路径（`is_use_repeat=1`，避免官方 UAF） |
| `vha_out_crc()` / 等待循环 | 完成判定：真实 `ktime` 截止 + **累计响应数** `vha_rsp_served` |
| `vha_int_fixup`（默认关）| 交付补齐的**内核侧实验**（触发点在用户态 `mmap` 时刻；生产用用户态 compat）|
| `[VHA-*]` 打点 | 取证日志：`ALLOC`/`MMAP`/`SUBMIT`/`TIME`/`SETTLE`/`IRQ`/`INTFIX`/`CRC` |

原理与每一处的来龙去脉见 `../docs/03-bridge-fixes.md` 与 `../docs/04-response-protocol-and-multigraph.md`。

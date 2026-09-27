# 许可与第三方材料边界（NOTICE）

本仓库分三部分，许可不同，分发前请对照：

## 1. `src/` 与 `patches/`（内核驱动相关）—— **GPL-2.0**

这两个目录是**对开源内核驱动**（Linux kernel 的 `drivers/staging/phytium-npu`，deepin 内核源码树）
的修改，属于 Linux 内核的派生作品，因此**同样以 GPL-2.0 分发**。

- 基线：上游 `phytium_npu_uapi.c`，11260 B，md5 `9112ba15693d38bafb784ba8e1aedaaa`
- 打补丁后：48123 B，md5 `acdff075f00d0b5ae3e182c02794ff78`
- 若你要把本补丁并入你自己内核树，请遵守 GPL-2.0（保留版权头、附许可文本）。

## 2. `svc/`、`tools/`、`scripts/`、`docs/`（本项目自建部分）—— **MIT**

```
Copyright (c) 2026 gic-commits

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## 3. **未包含**的第三方材料（发布时务必不要误加）

| 材料 | 性质 | 说明 |
|---|---|---|
| `npu-ftn300-rt-lib-*`（运行时 `.deb` / `libphydnn.so` / `libnpusession.so` …） | 厂商专有 | **不得**随仓库分发；本仓库所有"厂商库行为"的描述均为**观测与互操作研究**结论（黑盒测试、系统调用观测、公开 uapi 头比对），不含其代码 |
| 模型包（`.json/.params/.so/.tar`、`.onnx`） | 厂商/第三方 | 含权重，许可不明 |
| OS 镜像、厂商工具链 Docker 镜像 | 体积大且属他人 | 只给获取途径（见 `UPLOAD-MANIFEST.md`）|
| `synset_words.txt`、官方 ONNX 金标 | 第三方 | 用于验收比对，请从各自官方来源获取 |

## 4. 声明

- 本项目**与飞腾、麒麟、deepin、长城的官方无关**，是第三方互操作研究；
- 文中的机型、寄存器、命令编码、结构体布局均来自**公开资料与实测**；
  如厂商认为某处描述不当，请联系更正；
- 使用本项目造成的任何后果由使用者承担（尤其**内核模块**：装载前请确认可回滚，
  本项目保留的单进程版与旧 `.ko` 备份即为回退手段）。

# 自编模型包（model_build / npu_compiler 工具集）

**先读 [`../../docs/09-model-compile-pipeline.md`](../../docs/09-model-compile-pipeline.md)** —— 那里有完整原理、
两份配置文件的 schema、全部踩坑与错误信息对照表。本目录只放可直接改用的模板与示例。

## 文件

| 文件 | 用途 |
|---|---|
| `run_build.template.sh` | 容器内编译脚本模板（已内含 `mkdir -p /home/lib64` 这个必需修复） |
| `example_io_image.json` | 图像模型 io.json 示例（1 输入 1 输出，含 `layout`) |
| `example_test_image.json` | 图像模型 test.json 示例（指向图片**目录**，`-mi` 限张数） |
| `example_io_tensor.json` | **非图像/多输入** io.json 示例（ASR 型：`x[1,T,560]f32` + 3 个 int32 标量） |
| `example_test_tensor.json` | 非图像 test.json 示例（**`extension: f32/data` 原始张量路径**） |
| `gen_calib.py` | 生成原始张量校准文件（尺寸/dtype 必须与 io.json 一致） |

## 三步走

```bash
# 1) 生成校准数据（非图像模型）
python gen_calib.py --spec x=float32:1,200,560 x_length=int32:1 language=int32:1 text_norm=int32:1 \
                    --values language=0 text_norm=14 --out-dir ./calib

# 2) 容器内编译（把模型/配置/校准数据放进挂载到 /out 的目录）
bash run_build.template.sh <name> <model.onnx> io.json test.json <校准张数>

# 3) 部署：4 件套 → 推理服务实际使用的模型目录，chmod a+rX，重启服务
```

## 判据速查

- 编译成功标志：`RC=0` + 目录里出现 `<name>.{json,params,so,tar}`（`.params` 只有 32 B 是正常的，权重在 `.tar` 里）
- 部署成功标志：worker 日志出现 `init_graph(<dir>/<name>) -> 0`
- **`init_graph=-1` 通常是拷错目录**，不是包坏了
- 数值是否可信：必须与 CPU 参考实现（同预处理口径）比 top-k 与余弦，别只看"跑通"

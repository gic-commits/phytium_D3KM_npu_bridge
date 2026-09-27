# 用自己的模型编出可部署包（model_build / npu_compiler 全流程）

> 本文解决的问题：**厂商预编译的模型只有 5 个，想跑自己的模型（如 ASR 的 SenseVoice）就必须自己编包。**
> 本文是 2026-09-27 在 `npu-ftn300-tools`（NAS 侧 Docker 镜像）上**实测打通**的记录：
> 从"连命令都不知道"到"编出的包在 NPU 上真跑起来"。
> **门槛不在模型本身，而在两份配置文件的 schema 与一个缺失目录。**

## 一、工具链在哪、由什么组成

厂商把工具链打成了 Docker 镜像（本项目用的是 NAS 上的 `npu-ftn300-tools:v2`，约 9 GB）。
容器里工具在 **`/home/npu_ftn300_tools/`**：

| 文件 | 作用 |
|---|---|
| `model_build`（36 MB，PyInstaller 冻结的 Python） | **ONNX/TF/TFLite/Caffe/Paddle/PyTorch → PHY 中间表示**，内含 TVM + `phy_quantize` 校准量化，并**自己编排调用 mapper** |
| `npu_compiler`（1.4 MB） | **PHY 中间表示 → MBS**（`-n <imgir> -p <params> -m <mapconfig> -f <out.mbs>`） |
| `libphydnn.so` / `libnpucompiler.so` | 上述两者的依赖 |
| `in32out32_d16_w16b16.json` | 量化配置：输入/输出 32bit 浮点、数据 16bit、系数 16bit |

`npu_compiler` 不在 PATH 上，且缺 `LD_LIBRARY_PATH` 会报 `libphydnn.so: cannot open shared object file`。

## 二、★ 两个必需的前置修复（踩过才会知道）

### 1. `mkdir -p /home/lib64` + 放入三个文件
`model_build` 内部把环境变量 `NPU_MAPPER_INSTALL_PATH` **自己拼**成
`<cv2 所在目录>/../../lib64:<工具目录>:<工具目录>:/usr/local/lib:`，
首元素在当前容器里解析成 **`/home/lib64`——不存在** ⇒ 走到 mapper 阶段必定失败，且报错被截断：

```
[ERROR] NPU_MAPPER_INSTALL_PATH='…/cv2/../../lib64:/home/npu_ftn300_tools:…:/usr/local/lib:' does no…
[CRITICAL] NameError: name 'exit' is not defined      ← 冻结程序的 exit() 缺失，掩盖了真实错误
```

修法（放在编译脚本开头）：
```bash
mkdir -p /home/lib64
cp -f /home/npu_ftn300_tools/{libphydnn.so,npu_compiler,libnpucompiler.so} /home/lib64/
```

### 2. ONNX 必须能被解析
大模型下载**极易截断**。症状：`Error parsing message with type 'onnx.ModelProto'`。
务必与源站 `Content-Length` 比对（例：SenseVoice fp32 正确大小 **937,617,178** B；
一次截断到 929,604,800 B 就报了这个错），下载用 `curl -C -` 续传。
另外 ONNX 里**动态维度**会让工具警告 `variables with undefined shapes … Please provide shapes`
并在直方图分析阶段抛 TVMError；解法是用 io.json 给出**固定形状**（见下），或先自行静态化。

## 三、两份配置文件的 schema（★本文的核心，实测逆向自工具自身与 TVM 源码）

### `io.json`（`-nf`，网络输入输出声明）
**顶层是列表**，每项一个张量：

```json
[
  {"name": "input",  "shape": [1,3,224,224], "dtype": "float32", "type": "INPUT",  "layout": "NCHW"},
  {"name": "output", "shape": [1,1000],      "dtype": "float32", "type": "OUTPUT"}
]
```

- `type` **必须是大写** `INPUT`/`OUTPUT`（小写会被判为"0 个有效输入"）
- `dtype` **必须能当 numpy dtype 用**：`float32` / `int32` …（`float`/`f32` 均报错）
- `layout` 可选；**若给出，其字符数必须等于 shape 维度数**，图像输入的 `C` 必须 1 或 3
- **输出可以完全不声明**：工具会自己生成 `proposed_io.json` 并把所有网络输出收录进来
  （所以最省事的做法是先跑一次，把工具自产的 `proposed_io.json` 当模板）

错误信息对照：
| 报错 | 原因 |
|---|---|
| `TypeError: string indices must be integers` | 顶层写成了 dict（应为 list） |
| `KeyError: type` | 张量项缺 `type` 键 |
| `Network requires N inputs but 0 valid inputs are provided` | `type` 不是大写 `INPUT` |
| `Every input must have (name,shape,dtype) fields` | 缺 `dtype`（或拼写不是 `float32`） |

### `test.json`（`-tf`，校准/测试数据声明）
**顶层是列表**，每个网络输入一项：

```json
[
  {"name": "input", "image_path": "/work/imgs", "mean": [0,0,0],
   "extension": "jpg", "raw_scale": 255, "input_scale": 1}
]
```

- 每项**必须有 `name` 与 `image_path`**；`name` 必须与 io.json 的输入名一致
- 项数必须等于网络输入数（否则 `Number of inputs from test file and network file don't match`）
- `mean` **必须是 list**（`channel_swap` 同理）
- `extension ∈ {None, jpeg, jpg, png, bmp, gif, f32, data, npy}`（**不带点**，写成 `.jpg` 会报错）
- `image_path` 可以是**文件**，也可以是**目录**（目录时按 `extension` 过滤，`-mi` 限制取几张）
- ★**非图像模型的正确姿势**：`extension` 用 **`f32` / `data` / `npy`** ⇒ 走原始张量路径，
  跳过全部图像预处理。加载方式是：
  ```python
  if extension in ['f32','data']:
      data = np.fromfile(filename, dtype=<io.json 里的 dtype>)   # 再 resize 到网络 shape
  elif extension == 'npy':
      data = np.load(filename)   # 形状必须与网络 shape 对齐
  ```
  ⇒ **int32 输入也照此喂**（`dtype` 由 io.json 决定），ASR 的 `x_length/language/text_norm` 就是这么过的。
- 图像路径的预处理公式：`(rgb2gray(channel_swap(x)) * raw_scale - mean) * input_scale`

## 四、编译命令（完整形态）

```bash
TOOLS=/home/npu_ftn300_tools
export LD_LIBRARY_PATH="$TOOLS:/usr/local/lib:$LD_LIBRARY_PATH"
mkdir -p /home/lib64 && cp -f $TOOLS/{libphydnn.so,npu_compiler,libnpucompiler.so} /home/lib64/

$TOOLS/model_build -ll INFO -d npu -mf onnx -i model.onnx -o out/<name> \
    -nf io.json -tf test.json -mi <每输入取几张校准数据> \
    -mc $TOOLS/in32out32_d16_w16b16.json \
    [-es]        # 启用内置 onnx-simplifier（消除动态形状很有效）
    [-b1]        # 强制 batch=1
    [-sn]        # 额外保存 PHY-NNVM IR 的 json
    -so out/<name>.so -tm out/<name>.tar -op out/<name>.params
```

关键参数（`-h` 才看得到完整帮助，`--help` 无效）：

| 参数 | 含义 |
|---|---|
| `-d npu` | 目标设备（决定是否做 NPU 标注与直方图分析） |
| `-mi N` | 每输入取几张校准数据（默认 50） |
| `-idm <x.n2d>` | 传入已有的设备映射 ⇒ **跳过设备标注**（也就跳过直方图分析） |
| `-es` / `-b1` / `-sn` | 内置简化器 / 强制 batch=1 / 保存 NNVM json |
| `-so/-tm/-op` | 自定义输出库名 / 元数据 tar 名 / 参数名 |

## 五、产物与包结构

编译成功后（`RC=0`）得到 **4 件套**：

```
<name>.json     图（NNVM/PHY 格式，约 1–3 KB）
<name>.params   参数（通常只有 32 B —— 真正权重在 tar 里，别被吓到）
<name>.so       算子库（约 100–130 KB）
<name>.tar      元数据包（内含 MBS，体积 = 模型规模）
```

tar 内部**三条目**（与厂商预编译包逐字节同构，MBS 魔数 `42 ef be 42` 完全一致）：

```
__internal_io_file__        输入输出描述
npu_mbs.XXXXXX              真正的 MBS（命令流 + 权重）
__dependencies_info_file__  依赖信息
```

## 六、部署与验证（含一个必踩的坑）

1. 把 4 件套拷到**推理服务实际使用的模型目录**（本项目 `/opt/npu/model/`），并 `chmod a+rX`。
   ★**拷错目录的症状**：`init_graph = -1` / 客户端 `-3`——包没问题，只是服务在别的目录找模型。
2. 重启服务让 supervisor 重新扫描：`systemctl restart npusvc`
3. 判活与真跑：
   ```bash
   npu_cli load <name>                       # 期望 OK
   npu_cli infer <name> img.jpg 224 224 1 /tmp/out   # 期望输出 shape/非零合理
   ```
   worker 日志里应出现 **`init_graph(<dir>/<name>) -> 0`** 与 **`INFER <name> ok`**。
4. 数值核验（重要，别只看"跑通"）：用 **CPU 参考实现**（如 onnxruntime 跑同一 ONNX），
   输入用**与客户端完全相同的预处理口径**（本例：BGR→RGB / resize / `/255` / NCHW），
   比 top-1/top-5 与余弦相似度。

## 七、本项目的实测结论与遗留

- ✅ **自编 mobilenet 已部署并真跑**：`init_graph -> 0`、`out[0] [1,1000]` 非零 2753、425.9 ms
  （同参数厂商 `Restnet50` 为 600 ms 作对照）。
- ⚠️ **数值尚未对齐**：NPU top-5 `[111,418,623,844,892]` vs CPU 参考 `[903,629,551,589,457]`，余弦 0.35。
  已排除的：
  - 客户端预处理与 CPU 参考**逐行一致**（BGR→RGB / resize / `/255` / NCHW）
  - **管线本身正确**：厂商自带 `yunet_npu` 经同一条服务管线数值是准的（IoU 0.939 / score 0.9553）
  ⇒ 问题在"我们编出的包"。候选因：① io.json 里多写的 `layout:"NCHW"`（工具自产模板**不含** layout）
  ② 校准数据太少/不代表性（本次仅 2 张图）。**排队实验**：用工具自产 `proposed_io.json` + 多张校准图重编再比。
- ⏳ **SenseVoice-Small（ASR）编译进行中**：fp32 ONNX 937,617,178 B；
  io.json 四个输入固定形状 `x[1,200,560]f32` + `x_length[1]/language[1]/text_norm[1] int32`，
  校准数据用 `f32`/`data` 原始张量（x 448,000 B 随机；三个标量 4 B）。
  导出侧已知事实：`logits` 输出形状为 `[N, T+4, vocab]`（语言/事件/文本规整三个 query 会前置拼到序列上）。

## 八、把这套流程固化下来的判断

- 工具链**只在 x86 容器里跑**（镜像内是 x86-64 的 `model_build`）；目标是 aarch64 设备 —— 交叉编译在工具内部完成，**不需要在设备上装工具链**。
- 整个流程**可完全脚本化**（本项目脚本：`sv_build.sh`、`mb_build2.sh`、`bg.sh`、`run_build.template.sh`），
  长任务务必 `nohup` 脱离 ssh 会话并落日志；容器内 Python 输出会被块缓冲，需看**最终文件**而不是实时日志。
- 编一个 100 MB 级模型约 10 分钟；930 MB 级（SenseVoice）预计 30 分钟以上。

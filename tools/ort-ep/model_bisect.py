import os, subprocess, re, time, numpy as np
import onnx
from onnx import helper, TensorProto, numpy_helper
import onnxruntime as ort

D = "/home/greatwall/npu_harness/bisect"
os.makedirs(D, exist_ok=True)
os.chdir(D)

N, C, H, W = 1, 3, 64, 64
rng = np.random.RandomState(7)


def mk(name, nodes, inits, outs):
    g = helper.make_graph(nodes, name,
                          [helper.make_tensor_value_info("x", TensorProto.FLOAT, [N, C, H, W])],
                          outs, inits)
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 8
    p = os.path.join(D, name + ".onnx")
    onnx.checker.check_model(m)
    onnx.save(m, p)
    return p


def wi(name, shape):
    return numpy_helper.from_array(rng.randn(*shape).astype(np.float32), name)


MODELS = []
# 1) 单 Conv
MODELS.append(mk("m1_conv",
    [helper.make_node("Conv", ["x", "w1", "b1"], ["y"], name="conv1", pads=[1, 1, 1, 1])],
    [wi("w1", (8, C, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b1")],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [N, 8, H, W])]))
# 2) Conv+Relu
MODELS.append(mk("m2_conv_relu",
    [helper.make_node("Conv", ["x", "w1", "b1"], ["c1"], name="conv1", pads=[1, 1, 1, 1]),
     helper.make_node("Relu", ["c1"], ["y"], name="relu1")],
    [wi("w1", (8, C, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b1")],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [N, 8, H, W])]))
# 3) Conv+Relu+MaxPool
MODELS.append(mk("m3_conv_relu_pool",
    [helper.make_node("Conv", ["x", "w1", "b1"], ["c1"], name="conv1", pads=[1, 1, 1, 1]),
     helper.make_node("Relu", ["c1"], ["r1"], name="relu1"),
     helper.make_node("MaxPool", ["r1"], ["y"], name="pool1", kernel_shape=[2, 2], strides=[2, 2])],
    [wi("w1", (8, C, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b1")],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [N, 8, H // 2, W // 2])]))
# 4) 两层 Conv
MODELS.append(mk("m4_two_conv",
    [helper.make_node("Conv", ["x", "w1", "b1"], ["c1"], name="conv1", pads=[1, 1, 1, 1]),
     helper.make_node("Relu", ["c1"], ["r1"], name="relu1"),
     helper.make_node("MaxPool", ["r1"], ["p1"], name="pool1", kernel_shape=[2, 2], strides=[2, 2]),
     helper.make_node("Conv", ["p1", "w2", "b2"], ["y"], name="conv2", pads=[1, 1, 1, 1])],
    [wi("w1", (8, C, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b1"),
     wi("w2", (8, 8, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b2")],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [N, 8, H // 2, W // 2])]))
# 5) 全结构 = tiny_cnn 形状
MODELS.append(mk("m5_full",
    [helper.make_node("Conv", ["x", "w1", "b1"], ["c1"], name="conv1", pads=[1, 1, 1, 1]),
     helper.make_node("Relu", ["c1"], ["r1"], name="relu1"),
     helper.make_node("MaxPool", ["r1"], ["p1"], name="pool1", kernel_shape=[2, 2], strides=[2, 2]),
     helper.make_node("Conv", ["p1", "w2", "b2"], ["c2"], name="conv2", pads=[1, 1, 1, 1]),
     helper.make_node("Relu", ["c2"], ["r2"], name="relu2"),
     helper.make_node("GlobalAveragePool", ["r2"], ["g1"], name="gap"),
     helper.make_node("Flatten", ["g1"], ["y"], name="flatten")],
    [wi("w1", (8, C, 3, 3)), numpy_helper.from_array(np.zeros(8, np.float32), "b1"),
     wi("w2", (16, 8, 3, 3)), numpy_helper.from_array(np.zeros(16, np.float32), "b2")],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [N, 16])]))

MODELS.append("/home/greatwall/npu_harness/tiny_cnn.onnx")

X = rng.rand(*[N, C, H, W]).astype(np.float32)


def dmesg_clear():
    subprocess.run(["sudo", "dmesg", "-C"], capture_output=True)


def dmesg_txt():
    return subprocess.run(["sudo", "dmesg"], capture_output=True, text=True).stdout


print("%-18s %-8s %-10s %-8s %-9s %s" % ("模型", "cosine", "引擎写回", "irq", "命令流B", "缓冲清单"))
print("-" * 100)
for p in MODELS:
    name = os.path.basename(p).replace(".onnx", "")
    try:
        y_cpu = ort.InferenceSession(p, providers=["CPUExecutionProvider"]).run(None, {"x": X})[0]
    except Exception as e:
        print("%-18s CPU 失败 %s" % (name, str(e)[:60])); continue
    dmesg_clear()
    so = ort.SessionOptions(); so.log_severity_level = 3
    try:
        s = ort.InferenceSession(p, so, providers=["PHYNPUExecutionProvider", "CPUExecutionProvider"])
        y = s.run(None, {"x": X})[0]
        a, b = y.flatten().astype(np.float64), y_cpu.flatten().astype(np.float64)
        cos = float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    except Exception as e:
        cos = -1.0
    d = dmesg_txt()
    cb = re.findall(r"VHA-CRC-before.*crc32=(\w+)", d)
    ca = re.findall(r"VHA-CRC-after.*crc32=(\w+)", d)
    chg = sum(1 for i in range(min(len(cb), len(ca))) if cb[i] != ca[i])
    irq = re.findall(r"irq status \((0x[0-9a-f]+)\)", d)
    cs = re.findall(r"size=(\d+) words=", d)
    print("%-18s %-8.4f %-10s %-8s %-9s %s" % (name, cos, chg, ",".join(irq), ",".join(cs), ""))

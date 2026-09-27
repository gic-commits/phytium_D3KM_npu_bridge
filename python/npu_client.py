"""npu_client.py — NPU 推理服务的极简 Python 客户端（ctypes 直连 libnpuclient.so）

适用：**所有新应用都走张量级 `infer()`**（含语音/ASR：输入 shape 任意 ndim）。
图像级 `detect_yunet()` 只是薄封装（按厂商口径解码），不要当通用接口用。

用法:
    import npu_client as npu
    c = npu.connect()                       # 默认读 $NPU_SOCK，再退到 /tmp/npu.sock
    outs = c.infer("yunet_npu", arr)        # arr: numpy float32，任意 shape
    faces = c.detect_yunet("yunet_npu", "a.jpg", 112, 112, 0)
    print(c.status())

依赖：numpy；libnpuclient.so（默认 /opt/npu/lib/，可用 $NPU_LIB 覆盖）
"""
import ctypes
import os

import numpy as np

NPU_OK = 0
NPU_E_SOCKET = -1
NPU_E_PROTO = -2
NPU_E_SERVER = -3
NPU_E_NOSPACE = -4
NPU_E_BADARG = -5
NPU_E_TIMEOUT = -6
NPU_E_QUEUE_FULL = -7
_ERRNAME = {
    NPU_E_SOCKET: "SOCKET(连接失败/服务未启动)",
    NPU_E_PROTO: "PROTO(协议错)",
    NPU_E_SERVER: "SERVER(服务端错误)",
    NPU_E_NOSPACE: "NOSPACE(输出空间不足)",
    NPU_E_BADARG: "BADARG(参数错/图片读不到)",
    NPU_E_TIMEOUT: "TIMEOUT(超时)",
    NPU_E_QUEUE_FULL: "QUEUE_FULL(队列满)",
}


class _Tensor(ctypes.Structure):
    _fields_ = [
        ("ndim", ctypes.c_int),
        ("shape", ctypes.c_int * 8),
        ("bytes", ctypes.c_size_t),
        ("data", ctypes.c_void_p),
    ]


def _load(lib_path=None):
    p = lib_path or os.environ.get("NPU_LIB", "/opt/npu/lib/libnpuclient.so")
    lib = ctypes.CDLL(p)
    lib.npu_open.restype = ctypes.c_int
    lib.npu_open.argtypes = [ctypes.c_char_p]
    lib.npu_load.restype = ctypes.c_int
    lib.npu_load.argtypes = [ctypes.c_int, ctypes.c_char_p]
    lib.npu_infer_ex.restype = ctypes.c_int
    lib.npu_infer_ex.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(_Tensor), ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.npu_infer.restype = ctypes.c_int
    lib.npu_infer.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_int),
        ctypes.c_int, ctypes.POINTER(ctypes.c_int),
    ]
    lib.npu_infer_image.restype = ctypes.c_int
    lib.npu_infer_image.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(_Tensor), ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.npu_image_detect_yunet.restype = ctypes.c_int
    lib.npu_image_detect_yunet.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_int, ctypes.c_int,
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
    ]
    lib.npu_status.restype = ctypes.c_int
    lib.npu_status.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t]
    lib.npu_close.restype = ctypes.c_int
    lib.npu_close.argtypes = [ctypes.c_int]
    lib.npu_free.restype = None
    lib.npu_free.argtypes = [ctypes.c_void_p]
    return lib


def _err(r):
    return "%d %s" % (r, _ERRNAME.get(r, "UNKNOWN"))


class Client(object):
    def __init__(self, sock=None, lib_path=None):
        self._lib = _load(lib_path)
        s = sock or os.environ.get("NPU_SOCK")
        self._h = self._lib.npu_open(s.encode() if s else None)
        if self._h < 0:
            raise RuntimeError("npu_open 失败: " + _err(self._h))

    # ---------- 张量级（推荐） ----------
    def load(self, model):
        r = self._lib.npu_load(self._h, model.encode())
        if r != NPU_OK:
            raise RuntimeError("load(%s) 失败: %s" % (model, _err(r)))
        return True

    def infer(self, model, arr, prio=1, timeout_ms=0, max_outputs=8):
        """一次推理，返回**全部输出**（numpy float32 数组列表，按服务端报的形状 reshape）。
        输入 arr：任意 ndim 的 numpy 数组（内部转 float32 连续内存）。
        语音/ASR 例：mel 特征 (1, 80, T)，token logits 直接取输出。
        """
        a = np.ascontiguousarray(arr, dtype=np.float32)
        if a.ndim > 8:
            raise ValueError("ndim>8 不支持")
        shape = (ctypes.c_int * 8)(*list(a.shape))
        ts = (_Tensor * max_outputs)()
        arena = ctypes.c_void_p()
        abytes = ctypes.c_size_t()
        r = self._lib.npu_infer_ex(
            self._h, model.encode(), a.ctypes.data_as(ctypes.c_void_p), a.nbytes,
            shape, a.ndim, b"f32", prio, timeout_ms, max_outputs,
            ts, ctypes.byref(arena), ctypes.byref(abytes))
        if r < 0:
            raise RuntimeError("infer(%s) 失败: %s" % (model, _err(r)))
        n = r
        try:
            outs = []
            for i in range(n):
                nb = int(ts[i].bytes)
                buf = ctypes.string_at(ts[i].data, nb)          # 拷出，避免 arena 生命周期问题
                v = np.frombuffer(buf, dtype=np.float32)
                dims = [int(ts[i].shape[k]) for k in range(int(ts[i].ndim))]
                if dims and all(d > 0 for d in dims) and int(np.prod(dims)) == v.size:
                    v = v.reshape(dims)
                outs.append(v)
            return outs
        finally:
            if arena.value:
                self._lib.npu_free(arena)

    def infer_one(self, model, arr, prio=1, timeout_ms=0, out_cap=64 << 20):
        """只取第 0 个输出（省一次拷贝；返回 (ndarray, shape)）"""
        a = np.ascontiguousarray(arr, dtype=np.float32)
        shape = (ctypes.c_int * 8)(*list(a.shape))
        buf = ctypes.create_string_buffer(out_cap)
        ob = ctypes.c_size_t()
        oshape = (ctypes.c_int * 8)()
        ond = ctypes.c_int()
        r = self._lib.npu_infer(
            self._h, model.encode(), a.ctypes.data_as(ctypes.c_void_p), a.nbytes,
            shape, a.ndim, b"f32", prio, timeout_ms, buf, out_cap,
            ctypes.byref(ob), oshape, 8, ctypes.byref(ond))
        if r != NPU_OK:
            raise RuntimeError("infer_one(%s) 失败: %s" % (model, _err(r)))
        v = np.frombuffer(buf.raw[: int(ob.value)], dtype=np.float32).copy()
        dims = [int(oshape[k]) for k in range(int(ond.value))]
        if dims and all(d > 0 for d in dims) and int(np.prod(dims)) == v.size:
            v = v.reshape(dims)
        return v

    # ---------- 图像 → 张量级（推荐给"图片类"应用；Python 侧无需 opencv） ----------
    def infer_image(self, model, img_path, W, H, norm=1, prio=1, timeout_ms=0, max_outputs=8):
        """读图 + 按厂商口径预处理 + 一次推理，返回全部输出（numpy float32 数组列表）。
        norm: 0=裸 0-255（yunet）/ 1=/255（yolov5s、分类）/ 2=(x-127.5)/128（scrfd）
        预处理在 C++ 侧完成（口径与厂商一致），因此 Python 不需要 cv2。"""
        ts = (_Tensor * max_outputs)()
        arena = ctypes.c_void_p()
        abytes = ctypes.c_size_t()
        r = self._lib.npu_infer_image(
            self._h, model.encode(), str(img_path).encode(), int(W), int(H), int(norm),
            prio, timeout_ms, max_outputs, ts, ctypes.byref(arena), ctypes.byref(abytes))
        if r < 0:
            raise RuntimeError("infer_image(%s, %s) 失败: %s" % (model, img_path, _err(r)))
        try:
            outs = []
            for i in range(r):
                nb = int(ts[i].bytes)
                v = np.frombuffer(ctypes.string_at(ts[i].data, nb), dtype=np.float32)
                dims = [int(ts[i].shape[k]) for k in range(int(ts[i].ndim))]
                if dims and all(d > 0 for d in dims) and int(np.prod(dims)) == v.size:
                    v = v.reshape(dims)
                outs.append(v)
            return outs
        finally:
            if arena.value:
                self._lib.npu_free(arena)

    # ---------- 图像级（薄封装） ----------
    def detect_yunet(self, model, img_path, W=112, H=112, norm=0, max_faces=64):
        """返回 [{'box':(x,y,w,h),'score':float,'kps':[(x,y)*5]}, ...]"""
        buf = (ctypes.c_float * (max_faces * 15))()
        n = self._lib.npu_image_detect_yunet(
            self._h, model.encode(), str(img_path).encode(), W, H, norm, buf, max_faces)
        if n < 0:
            raise RuntimeError("detect_yunet 失败: " + _err(n))
        out = []
        for i in range(n):
            b = buf[i * 15: i * 15 + 15]
            out.append({
                "box": (b[0], b[1], b[2], b[3]),
                "score": b[4],
                "kps": [(b[5 + 2 * k], b[6 + 2 * k]) for k in range(5)],
            })
        return out

    def status(self):
        buf = ctypes.create_string_buffer(4096)
        r = self._lib.npu_status(self._h, buf, len(buf))
        if r != NPU_OK:
            raise RuntimeError("status 失败: " + _err(r))
        d = {}
        for line in buf.value.decode("utf-8", "replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k] = v
        return d

    def close(self):
        if self._h is not None and self._h >= 0:
            self._lib.npu_close(self._h)
            self._h = -1

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def connect(sock=None, lib_path=None):
    return Client(sock, lib_path)

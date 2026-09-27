// npuclient.h — NPU 服务客户端接口（应用唯一需要链接的东西）
// 传输：unix domain socket；协议 NPU1 = 文本头(key=value) + 二进制张量载荷
// 语义：输出已由服务按模型元数据完成"交付 + 激活"（逐模型口径见服务端 <model>.meta.txt）
#ifndef NPUCLIENT_H
#define NPUCLIENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 打开连接（默认 /run/npu/npu.sock；失败时自动尝试 /tmp/npu.sock）。返回句柄 >=0 或负错误码 */
int npu_open(const char *sock_path /* 可为 NULL */);

/* 预加载模型（幂等；服务端缓存）。model_prefix 例 "model/yunet_npu" */
int npu_load(int h, const char *model_prefix);

/* 张量描述（npu_infer_ex 用） */
typedef struct {
    int ndim;
    int shape[8];
    size_t bytes;
    const unsigned char *data;   /* 指向 arena 内部，勿单独释放 */
} npu_tensor_t;

/* ★张量级通用接口（推荐所有新应用走这条，含语音/ASR：输入 shape 任意 ndim）
 * 一次推理取回全部输出：tensors 由调用方提供数组，*arena 由服务端侧分配、调用方用 npu_free 释放 */
int npu_infer_ex(int h, const char *model_prefix,
                 const void *in, size_t in_bytes, const int *in_shape, int in_ndim,
                 const char *dtype, int prio, int timeout_ms, int max_outputs,
                 npu_tensor_t *tensors, unsigned char **arena, size_t *arena_bytes);
void npu_free(void *p);

/* 便捷：只取第 0 个输出（内部仍是一次推理） */
int npu_infer(int h, const char *model_prefix,
              const void *in, size_t in_bytes, const int *in_shape, int in_ndim,
              const char *dtype, int prio, int timeout_ms,
              void *out, size_t out_cap, size_t *out_bytes,
              int *out_shape, int max_ndim, int *out_ndim);

/* ★图像→张量级：读图 + 按口径预处理 + 送张量 + 取回全部输出（一次调用）。
 * 存在的理由：**让非 C/C++ 应用（Python 等）不必自己装 opencv**，且预处理口径与厂商一致。
 * norm: 0=裸 0-255 / 1=/255 / 2=(x-127.5)/128；返回输出个数或负错误码（语义同 npu_infer_ex） */
int npu_infer_image(int h, const char *model_prefix, const char *img_path,
                    int W, int H, int norm, int prio, int timeout_ms, int max_outputs,
                    npu_tensor_t *tensors, unsigned char **arena, size_t *arena_bytes);

/* 图像级（CV 便利封装，薄）：读图→按模型口径预处理→推理→按模型解码
 * out_faces 由调用方提供，格式与厂商 YuNetModel 一致：{x,y,w,h,score, 10 个关键点}
 * max_faces 上限，返回检出数或负错误码 */
int npu_image_detect_yunet(int h, const char *model_prefix, const char *img_path,
                           int W, int H, int norm, float *out_faces, int max_faces);

/* 服务状态：写回文本（连接数/队列/已加载模型/统计） */
int npu_status(int h, char *buf, size_t cap);

int npu_close(int h);

/* 错误码 */
#define NPU_OK            0
#define NPU_E_SOCKET     -1
#define NPU_E_PROTO      -2
#define NPU_E_SERVER     -3
#define NPU_E_NOSPACE    -4
#define NPU_E_BADARG     -5
#define NPU_E_TIMEOUT    -6
#define NPU_E_QUEUE_FULL -7

#ifdef __cplusplus
}
#endif
#endif

// npu_det.cpp — 按厂商口径跑模型并 dump 原始输出（用于数值/框级验收）
// 用法: npu_det <模型前缀> <图片> <W> <H> <norm255:0|1> <outbytes|0=auto> [dump前缀]
//   norm255=1 时按厂商 yolov5s 口径除以 255（0-1），否则 0-255 裸值（yunet 口径）
//   outbytes>0 时，每个输出 dump outbytes 字节（库返回的 Mat 无 dims，须外部给尺寸）
#include <phyAIEngine.h>
#include <opencv2/opencv.hpp>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 7) { printf("用法: %s <模型前缀> <图片> <W> <H> <norm255> <outbytes> [dump前缀]\n", argv[0]); return 1; }
    std::string model = argv[1];
    int W = atoi(argv[3]), H = atoi(argv[4]), norm = atoi(argv[5]);
    size_t outbytes = (size_t)strtoul(argv[6], nullptr, 0);
    const char *dumpp = (argc >= 8) ? argv[7] : nullptr;
    printf("  [cfg] model=%s W=%d H=%d norm255=%d outbytes=%zu\n", model.c_str(), W, H, norm, outbytes);

    phyAIEngine eng;
    int r = eng.init_graph(model);
    printf("  init_graph -> %d %s\n", r, r ? "FAIL" : "OK");
    if (r) return 2;

    cv::Mat img = cv::imread(argv[2]);
    if (img.empty()) { printf("[图片] 读取失败\n"); return 3; }
    printf("  [img] %dx%d\n", img.cols, img.rows);

    cv::Mat rgb, resized, f32;
    cv::cvtColor(img, rgb, cv::COLOR_BGR2RGB);
    cv::resize(rgb, resized, cv::Size(W, H));
    resized.convertTo(f32, CV_32FC3);

    std::vector<cv::Mat> ch(3);
    cv::split(f32, ch);
    std::vector<float> data;
    for (auto &c : ch) {
        if (norm == 1) c /= 255.0;
        else if (norm == 2) c = (c - 127.5) / 128.0;   /* scrfd 厂商口径: blobFromImage(1/128, mean=127.5) */
        std::vector<float> v = std::vector<float>(c.reshape(1, 1));
        data.insert(data.end(), v.begin(), v.end());
    }
    cv::Mat t(W, H, CV_32FC3);
    memcpy(t.data, data.data(), data.size() * sizeof(float));
    int shape[] = {1, 3, H, W};
    cv::Mat input = t.reshape(1, 4, shape);

    std::vector<cv::Mat> ins{input}, outs;
    r = eng.execute_graph(ins, outs);
    printf("  execute_graph -> %d, 输出 %zu 个\n", r, outs.size());
    for (size_t i = 0; i < outs.size(); ++i)
        printf("    out[%zu]: data=%p rows=%d cols=%d total=%zu\n",
               i, (void *)outs[i].data, outs[i].rows, outs[i].cols,
               (size_t)outs[i].total());

    /* 可选：按 NPU_DET_SOFTMAX=<index>|all 对输出做 2 类 softmax。
     * 动机(2026-09-27 实测)：厂商运行时本该在"拷进 dnn_buf_"时做这步激活(软链里 softmax@213)，
     * 却整步跳过 ⇒ NPU 侧的 conf 是 pre-softmax logits，直接送厂商后处理会误检(13 张 vs 金标 1 张)。
     * 内核补不了（arm64 内核 -mgeneral-regs-only 禁 float）⇒ 在用户态补。
     * 注意：库的 mmap 是只读的 ⇒ 必须先拷到本地缓冲再改，不能就地写。
     */
    const char *sm = getenv("NPU_DET_SOFTMAX");

    if (dumpp) {
        for (size_t i = 0; i < outs.size(); ++i) {
            size_t nbytes = outbytes;
            if (nbytes == 0) {   /* auto: 用 Mat 的 total*elemSize（库的 total 是对的） */
                nbytes = (size_t)outs[i].total() * outs[i].elemSize();
                printf("    (auto out[%zu] = %zu elements x %zu B)\n",
                       i, (size_t)outs[i].total(), outs[i].elemSize());
            }
            if (!outs[i].data || !nbytes) { printf("  [dump] out[%zu] 跳过 (data=%p n=%zu)\n", i, (void *)outs[i].data, nbytes); continue; }
            std::vector<unsigned char> buf(nbytes);
            memcpy(buf.data(), outs[i].data, nbytes);
            if (sm && (!strcmp(sm, "all") || (size_t)atoi(sm) == i)) {
                if (nbytes % 8) {
                    printf("  [softmax] out[%zu] %zu B 非 8 的倍数, 跳过激活\n", i, nbytes);
                } else {
                    float *q = (float *)buf.data();
                    size_t np = nbytes / 8;
                    for (size_t k = 0; k < np; k++) {
                        float c0 = q[2 * k], c1 = q[2 * k + 1];
                        float p1 = 1.0f / (1.0f + expf(c0 - c1));
                        q[2 * k] = 1.0f - p1;
                        q[2 * k + 1] = p1;
                    }
                    printf("  [softmax] out[%zu] 已做 2 类 softmax (%zu 对)\n", i, np);
                }
            }
            char fn[512];
            snprintf(fn, sizeof(fn), "%s_%zu.bin", dumpp, i);
            FILE *f = fopen(fn, "wb");
            if (!f) { printf("  [dump] %s 打不开\n", fn); continue; }
            fwrite(buf.data(), 1, nbytes, f);
            fclose(f);
            printf("  [dump] %s %zu bytes\n", fn, nbytes);
        }
    }
    return r;
}

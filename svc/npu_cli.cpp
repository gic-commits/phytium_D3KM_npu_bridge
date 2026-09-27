// npu_cli.cpp — 服务示例/测试客户端
// 用法:
//   npu_cli status
//   npu_cli load   <模型>
//   npu_cli infer  <模型> <图片> <W> <H> <norm> <dump前缀> [prio]   # 张量级（自己预处理，dump 全部输出）
//   npu_cli face   <模型> <图片> <W> <H> <norm> [prio]              # 图像级（直接给人的结果）
//   npu_cli bench  <模型> <图片> <W> <H> <norm> <次数> [prio]        # 连续压力
// norm: 0=裸 0-255(yunet) 1=/255(yolov5s/分类) 2=(x-127.5)/128(scrfd)
#include "npuclient.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <opencv2/opencv.hpp>

static int preprocess(const char *path, int W, int H, int norm, std::vector<float> &data)
{
    cv::Mat img = cv::imread(path);

    if (img.empty())
        return -1;
    cv::Mat rgb, rs, f32;

    cv::cvtColor(img, rgb, cv::COLOR_BGR2RGB);
    cv::resize(rgb, rs, cv::Size(W, H));
    rs.convertTo(f32, CV_32FC3);
    std::vector<cv::Mat> ch(3);

    cv::split(f32, ch);
    data.clear();
    for (auto &c : ch) {
        if (norm == 1) c /= 255.0;
        else if (norm == 2) c = (c - 127.5) / 128.0;
        std::vector<float> v = std::vector<float>(c.reshape(1, 1));
        data.insert(data.end(), v.begin(), v.end());
    }
    return 0;
}

static size_t nonzero(const unsigned char *p, size_t n)
{
    size_t c = 0;

    for (size_t i = 0; i < n; i++)
        if (p[i]) c++;
    return c;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        printf("用法: %s status | load <模型> | infer <模型> <图> <W> <H> <norm> <dump前缀> [prio]\n"
               "       | face <模型> <图> <W> <H> <norm> [prio] | bench <模型> <图> <W> <H> <norm> <次数> [prio]\n", argv[0]);
        return 1;
    }
    int h = npu_open(nullptr);

    if (h < 0) { printf("[cli] 连不上服务: %d\n", h); return 2; }
    std::string cmd = argv[1];

    if (cmd == "status") {
        char buf[2048];

        if (npu_status(h, buf, sizeof(buf)) < 0) { printf("[cli] status 失败\n"); return 3; }
        printf("%s", buf);
        npu_close(h);
        return 0;
    }
    if (cmd == "load" && argc >= 3) {
        int r = npu_load(h, argv[2]);

        printf("[cli] load %s -> %s\n", argv[2], r ? "FAIL" : "OK");
        npu_close(h);
        return r ? 4 : 0;
    }
    if (cmd == "face" && argc >= 7) {
        int W = atoi(argv[4]), H = atoi(argv[5]), norm = atoi(argv[6]);
        float faces[64 * 15];
        auto t0 = std::chrono::steady_clock::now();
        int n = npu_image_detect_yunet(h, argv[2], argv[3], W, H, norm, faces, 64);
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

        if (n < 0) { printf("[cli] face 失败: %d\n", n); npu_close(h); return 5; }
        printf("[cli] 检出 %d 张脸（含网络+解析 %.1f ms）\n", n, ms);
        for (int i = 0; i < n; i++) {
            float *f = faces + (size_t)i * 15;

            printf("   #%d: box=(%.1f,%.1f,%.1f,%.1f) score=%.4f kps=[", i, f[0], f[1], f[2], f[3], f[4]);
            for (int t = 0; t < 10; t++)
                printf("%.0f%s", f[5 + t], t == 9 ? "]\n" : ",");
        }
        npu_close(h);
        return 0;
    }
    if (cmd == "infer" && argc >= 8) {
        int W = atoi(argv[4]), H = atoi(argv[5]), norm = atoi(argv[6]);
        int prio = argc >= 9 ? atoi(argv[8]) : 1;
        std::vector<float> data;

        if (preprocess(argv[3], W, H, norm, data)) { printf("[cli] 读图失败\n"); return 3; }
        int shape[4] = {1, 3, H, W};
        npu_tensor_t ts[16];
        unsigned char *arena = nullptr;
        size_t abytes = 0;
        auto t0 = std::chrono::steady_clock::now();
        int n = npu_infer_ex(h, argv[2], data.data(), data.size() * sizeof(float), shape, 4,
                             "f32", prio, 0, 16, ts, &arena, &abytes);
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

        if (n < 0) { printf("[cli] infer 失败: %d\n", n); npu_close(h); return 5; }
        printf("[cli] 输出 %d 个（往返 %.1f ms）\n", n, ms);
        for (int i = 0; i < n; i++) {
            printf("   out[%d] bytes=%zu ndim=%d shape=[", i, ts[i].bytes, ts[i].ndim);
            for (int k = 0; k < ts[i].ndim; k++)
                printf("%d%s", ts[i].shape[k], k + 1 < ts[i].ndim ? "," : "");
            printf("] 非零=%zu\n", nonzero(ts[i].data, ts[i].bytes));
            char fn[512];
            snprintf(fn, sizeof(fn), "%s_%d.bin", argv[7], i);
            FILE *f = fopen(fn, "wb");

            if (f) { fwrite(ts[i].data, 1, ts[i].bytes, f); fclose(f); printf("   → %s\n", fn); }
        }
        npu_free(arena);
        npu_close(h);
        return 0;
    }
    if (cmd == "bench" && argc >= 8) {
        int W = atoi(argv[4]), H = atoi(argv[5]), norm = atoi(argv[6]), cnt = atoi(argv[7]);
        int prio = argc >= 9 ? atoi(argv[8]) : 1;
        std::vector<float> data;

        if (preprocess(argv[3], W, H, norm, data)) { printf("[cli] 读图失败\n"); return 3; }
        int shape[4] = {1, 3, H, W};
        auto t0 = std::chrono::steady_clock::now();
        int fail = 0;
        for (int i = 0; i < cnt; i++) {
            npu_tensor_t ts[16];
            unsigned char *arena = nullptr;
            size_t abytes = 0;
            int n = npu_infer_ex(h, argv[2], data.data(), data.size() * sizeof(float), shape, 4,
                                 "f32", prio, 0, 16, ts, &arena, &abytes);
            if (n < 0) { printf("   第 %d 次失败: %d\n", i, n); fail++; }
            npu_free(arena);
        }
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("[cli] bench %d 次: 失败 %d, 总 %.1f ms, 平均 %.2f ms, %.1f fps\n",
               cnt, fail, ms, ms / cnt, cnt * 1000.0 / ms);
        npu_close(h);
        return fail ? 6 : 0;
    }
    printf("[cli] 未知命令或参数不足\n");
    npu_close(h);
    return 1;
}

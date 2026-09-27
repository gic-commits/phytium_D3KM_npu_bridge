// npu_gen.cpp — 通用 phyAIEngine 运行器（v0x0f / v0x10 包都可跑）
// 用法: npu_gen <模型前缀> <图片> [W] [H] [dump前缀]
//   模型前缀同 npu_test：会在同目录找 <前缀>.json/.params/.so/.tar
//   默认 W=H=112（与 npu_test 一致）；dump前缀 给了就导出每个输出到 <前缀>_<i>.bin
#include <phyAIEngine.h>
#include <opencv2/opencv.hpp>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 3) { printf("用法: %s <模型前缀> <图片> [W] [H] [dump前缀]\n", argv[0]); return 1; }
    std::string model = argv[1];
    int W = (argc >= 4) ? atoi(argv[3]) : 112;
    int H = (argc >= 5) ? atoi(argv[4]) : 112;
    const char *dumpp = (argc >= 6) ? argv[5] : nullptr;
    printf("  [cfg] model=%s image=%s W=%d H=%d\n", model.c_str(), argv[2], W, H);

    phyAIEngine eng;
    int r = eng.init_graph(model);
    printf("  init_graph -> %d %s\n", r, r ? "FAIL" : "OK");
    if (r) return 2;

    cv::Mat img = cv::imread(argv[2]);
    if (img.empty()) { printf("[图片] 读取失败\n"); return 3; }

    cv::Mat rgb, resized, f32;
    cv::cvtColor(img, rgb, cv::COLOR_BGR2RGB);
    cv::resize(rgb, resized, cv::Size(W, H));
    resized.convertTo(f32, CV_32FC3);

    std::vector<cv::Mat> ch(3);
    cv::split(f32, ch);
    std::vector<float> data;
    for (auto &c : ch) {
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
    for (size_t i = 0; i < outs.size() && i < 8; ++i)
        printf("    out[%zu]: %dx%d type=%d\n", i, outs[i].cols, outs[i].rows, outs[i].type());

    if (dumpp) {
        for (size_t i = 0; i < outs.size(); ++i) {
            char fn[512];
            snprintf(fn, sizeof(fn), "%s_%zu.bin", dumpp, i);
            FILE *f = fopen(fn, "wb");
            if (!f) { printf("  [dump] %s 打不开\n", fn); continue; }
            cv::Mat m = outs[i].isContinuous() ? outs[i] : outs[i].clone();
            int rows = m.rows, cols = m.cols, type = m.type();
            fwrite(&rows, sizeof(int), 1, f);
            fwrite(&cols, sizeof(int), 1, f);
            fwrite(&type, sizeof(int), 1, f);
            fwrite(m.data, 1, (size_t)m.total() * m.elemSize(), f);
            fclose(f);
            printf("  [dump] %s rows=%d cols=%d type=%d\n", fn, rows, cols, type);
        }
    }
    return r;
}

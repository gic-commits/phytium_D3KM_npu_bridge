// rep_test.cpp — 同一进程内连续 N 次 execute_graph，逐步计时（判定"反复推理是否退化"）
// 用法: rep_test <模型前缀> <图片> <W> <H> <norm> <次数>
#include <phyAIEngine.h>
#include <opencv2/opencv.hpp>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char **argv)
{
    if (argc < 7) { printf("用法: %s <模型前缀> <图片> <W> <H> <norm> <次数>\n", argv[0]); return 1; }
    std::string model = argv[1];
    int W = atoi(argv[3]), H = atoi(argv[4]), norm = atoi(argv[5]), N = atoi(argv[6]);
    auto ms = [](std::chrono::steady_clock::time_point a) {
        return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - a).count();
    };

    phyAIEngine eng;
    auto t0 = std::chrono::steady_clock::now();
    int r = eng.init_graph(model);

    printf("init_graph -> %d (%.1f ms)\n", r, ms(t0));
    if (r) return 2;

    cv::Mat img = cv::imread(argv[2]);
    if (img.empty()) { printf("读图失败\n"); return 3; }
    cv::Mat rgb, rs, f32;

    cv::cvtColor(img, rgb, cv::COLOR_BGR2RGB);
    cv::resize(rgb, rs, cv::Size(W, H));
    rs.convertTo(f32, CV_32FC3);
    std::vector<cv::Mat> ch(3);

    cv::split(f32, ch);
    std::vector<float> data;
    for (auto &c : ch) {
        if (norm == 1) c /= 255.0;
        else if (norm == 2) c = (c - 127.5) / 128.0;
        std::vector<float> v = std::vector<float>(c.reshape(1, 1));
        data.insert(data.end(), v.begin(), v.end());
    }
    cv::Mat t(W, H, CV_32FC3);

    memcpy(t.data, data.data(), data.size() * sizeof(float));
    int shape[] = {1, 3, H, W};
    cv::Mat input = t.reshape(1, 4, shape);

    for (int i = 0; i < N; i++) {
        std::vector<cv::Mat> ins{input}, outs;
        auto a = std::chrono::steady_clock::now();
        int rr = eng.execute_graph(ins, outs);
        double d = ms(a);
        size_t nz = 0;

        for (size_t k = 0; k < outs.size(); k++) {
            size_t nb = (size_t)outs[k].total() * outs[k].elemSize();
            const unsigned char *p = outs[k].data;

            for (size_t j = 0; j < nb; j++)
                if (p[j]) nz++;
        }
        printf("run %d: rc=%d %.1f ms  输出 %zu 个 合计非零=%zu\n", i + 1, rr, d, outs.size(), nz);
        std::fflush(stdout);
    }
    return 0;
}

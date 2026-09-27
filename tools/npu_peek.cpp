// npu_peek.cpp — 同一进程内按页号直读 NPU 交换缓冲（验证 page93 是否真有 conf）
// 用法: npu_peek <模型前缀> <图片> <W> <H> <norm> <page...>
// 先跑一次 execute_graph（建立会话），再 mmap /dev/npu0 offset=page*4096
#include <phyAIEngine.h>
#include <opencv2/opencv.hpp>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cmath>
#include <vector>
#include <string>

static void show(const char *tag, unsigned char *p, size_t n)
{
    size_t nz = 0;
    float mn = 1e30f, mx = -1e30f;
    const float *f = (const float *)p;
    for (size_t i = 0; i < n; i++) if (p[i]) nz++;
    for (size_t i = 0; i + 4 <= n; i += 4) {
        float v; memcpy(&v, p + i, 4);
        if (std::isfinite(v)) { if (v < mn) mn = v; if (v > mx) mx = v; }
    }
    printf("  %s: %zu B, 非零=%zu\n", tag, n, nz);
    printf("      head f32: %.6f %.6f %.6f %.6f | %.6f %.6f %.6f %.6f\n",
           f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]);
    printf("      有限值范围: min=%.6f max=%.6f\n", mn, mx);
}

int main(int argc, char **argv)
{
    if (argc < 7) {
        printf("用法: %s <模型前缀> <图片> <W> <H> <norm> <page...>\n", argv[0]);
        return 1;
    }
    std::string model = argv[1];
    int W = atoi(argv[3]), H = atoi(argv[4]), norm = atoi(argv[5]);

    phyAIEngine eng;
    int r = eng.init_graph(model);
    printf("init_graph -> %d %s\n", r, r ? "FAIL" : "OK");
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
        if (norm == 1) c /= 255.0;
        else if (norm == 2) c = (c - 127.5) / 128.0;
        std::vector<float> v = std::vector<float>(c.reshape(1, 1));
        data.insert(data.end(), v.begin(), v.end());
    }
    cv::Mat t(W, H, CV_32FC3);
    memcpy(t.data, data.data(), data.size() * sizeof(float));
    int shape[] = {1, 3, H, W};
    cv::Mat input = t.reshape(1, 4, shape);

    std::vector<cv::Mat> ins{input}, outs;
    r = eng.execute_graph(ins, outs);
    printf("execute_graph -> %d, 输出 %zu 个\n", r, outs.size());
    for (size_t i = 0; i < outs.size(); ++i) {
        size_t nb = (size_t)outs[i].total() * outs[i].elemSize();
        printf("  out[%zu] data=%p total=%zu (%zu B)\n", i, (void *)outs[i].data,
               (size_t)outs[i].total(), nb);
        if (outs[i].data) show("out[]", outs[i].data, nb);
    }

    int fd = open("/dev/npu0", O_RDWR);
    printf("open /dev/npu0 -> fd=%d%s\n", fd, fd < 0 ? " (失败)" : "");
    if (fd < 0) return 4;

    for (int i = 6; i < argc; ++i) {
        unsigned long page = strtoul(argv[i], nullptr, 0);
        size_t len = 8192;
        off_t off = (off_t)page << 12;   /* 库的口径: pgoff = page 号 */
        void *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, off);
        if (p == MAP_FAILED) {
            printf("  page=%lu mmap 失败 off=%lld errno=%d (%s)\n",
                   page, (long long)off, errno, strerror(errno));
            continue;
        }
        char tag[64];
        snprintf(tag, sizeof(tag), "page=%lu", page);
        show(tag, (unsigned char *)p, len);
        char fn[128];
        snprintf(fn, sizeof(fn), "/tmp/peek_p%lu.bin", page);
        FILE *f = fopen(fn, "wb");
        if (f) { fwrite(p, 1, len, f); fclose(f); printf("      已存 %s\n", fn); }
        /* 与 out[1] 逐字节比（若有） */
        if (outs.size() > 1 && outs[1].data) {
            size_t nb = (size_t)outs[1].total() * outs[1].elemSize();
            if (nb == len) {
                size_t same = 0;
                unsigned char *q = (unsigned char *)outs[1].data;
                for (size_t k = 0; k < nb; k++) if (q[k] == ((unsigned char *)p)[k]) same++;
                printf("      与 out[1] 相同字节 %zu/%zu\n", same, nb);
            }
        }
        munmap(p, len);
    }
    close(fd);
    return 0;
}

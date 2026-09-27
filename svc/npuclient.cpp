// npuclient.cpp — NPU 服务客户端实现
// 协议 NPU1：首行 `NPU1 <op|status> <hdrlen> <payloadlen>\n` + 文本头(k=v\n) + 二进制载荷
#include "npuclient.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <opencv2/opencv.hpp>

namespace {
/* 前向声明：定义在文件后半（图像级助手区内） */
int infer_all(int fd, const std::string &model, const std::vector<float> &data,
              const int *shape, int ndim, int prio, int timeout_ms,
              std::vector<std::vector<unsigned char> > &outs,
              std::vector<std::vector<int> > &shapes);
}

namespace {

int send_all(int fd, const void *p, size_t n)
{
    const char *q = (const char *)p;
    size_t off = 0;

    while (off < n) {
        ssize_t k = ::send(fd, q + off, n - off, MSG_NOSIGNAL);
        if (k <= 0) {
            if (k < 0 && errno == EINTR) continue;
            return -1;
        }
        off += (size_t)k;
    }
    return 0;
}

int recv_all(int fd, void *p, size_t n)
{
    char *q = (char *)p;
    size_t off = 0;

    while (off < n) {
        ssize_t k = ::recv(fd, q + off, n - off, 0);
        if (k <= 0) {
            if (k < 0 && errno == EINTR) continue;
            return -1;
        }
        off += (size_t)k;
    }
    return 0;
}

/* 请求： hdr 为 "k=v\n" 拼接；返回 0/负 */
int do_request(int fd, const std::string &op, const std::string &hdr,
               const void *payload, size_t payload_len,
               std::map<std::string, std::string> &rhdr, std::vector<unsigned char> &rpayload,
               int *status_out)
{
    char line[128];
    int n = snprintf(line, sizeof(line), "NPU1 %s %zu %zu\n", op.c_str(), hdr.size(), payload_len);

    if (send_all(fd, line, n) || send_all(fd, hdr.data(), hdr.size()) ||
        (payload_len && send_all(fd, payload, payload_len)))
        return NPU_E_SOCKET;
    /* 读响应首行 */
    std::string head;
    char c;

    for (;;) {
        if (recv_all(fd, &c, 1))
            return NPU_E_SOCKET;
        if (c == '\n')
            break;
        head += c;
        if (head.size() > 200)
            return NPU_E_PROTO;
    }
    char magic[16], st[16];
    size_t hl = 0, pl = 0;
    int status = -1;

    if (sscanf(head.c_str(), "%15s %d %zu %zu", magic, &status, &hl, &pl) != 4)
        return NPU_E_PROTO;
    if (strcmp(magic, "NPU1"))
        return NPU_E_PROTO;
    std::vector<char> hb(hl + 1);

    if (hl && recv_all(fd, hb.data(), hl))
        return NPU_E_SOCKET;
    hb[hl] = 0;
    char *save = nullptr;
    for (char *t = strtok_r(hb.data(), "\n", &save); t; t = strtok_r(nullptr, "\n", &save)) {
        char *eq = strchr(t, '=');

        if (eq) { *eq = 0; rhdr[t] = eq + 1; }
    }
    rpayload.resize(pl);
    if (pl && recv_all(fd, rpayload.data(), pl))
        return NPU_E_SOCKET;
    if (status_out)
        *status_out = status;
    return NPU_OK;
}

}  // namespace

int npu_open(const char *sock_path)
{
    /* 解析顺序：显式参数 > 环境变量 NPU_SOCK > 默认 /tmp/npu.sock
     * （systemd 部署时 socket 通常在 /run/npu/npu.sock，用 NPU_SOCK 指过去） */
    const char *envs = getenv("NPU_SOCK");
    const char *paths[3] = {sock_path, envs, "/tmp/npu.sock"};
    int n = sock_path ? 1 : (envs ? 2 : 3);

    for (int i = 0; i < n; i++) {
        const char *p = paths[i];
        int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);

        if (fd < 0)
            return NPU_E_SOCKET;
        struct sockaddr_un a;
        memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof(a.sun_path), "%s", p);
        if (::connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0)
            return fd;
        ::close(fd);
    }
    return NPU_E_SOCKET;
}

int npu_load(int h, const char *model_prefix)
{
    if (h < 0 || !model_prefix)
        return NPU_E_BADARG;
    std::string hdr = std::string("MODEL=") + model_prefix + "\n";
    std::map<std::string, std::string> rh; std::vector<unsigned char> rp; int st = -1;
    int r = do_request(h, "LOAD", hdr, nullptr, 0, rh, rp, &st);

    if (r)
        return r;
    return st == 0 ? NPU_OK : NPU_E_SERVER;
}

int npu_infer(int h, const char *model_prefix,
              const void *in, size_t in_bytes, const int *in_shape, int in_ndim,
              const char *dtype, int prio, int timeout_ms,
              void *out, size_t out_cap, size_t *out_bytes,
              int *out_shape, int max_ndim, int *out_ndim)
{
    if (h < 0 || !model_prefix || !in || !in_shape || in_ndim <= 0)
        return NPU_E_BADARG;
    npu_tensor_t ts[16];
    unsigned char *arena = nullptr;
    size_t abytes = 0;
    int n = npu_infer_ex(h, model_prefix, in, in_bytes, in_shape, in_ndim, dtype, prio,
                         timeout_ms, (int)(sizeof(ts) / sizeof(ts[0])), ts, &arena, &abytes);
    if (n < 0)
        return n;
    size_t nb = ts[0].bytes;
    if (out_bytes)
        *out_bytes = nb;
    if (!out || nb > out_cap) {
        npu_free(arena);
        return NPU_E_NOSPACE;
    }
    memcpy(out, ts[0].data, nb);
    if (out_shape && out_ndim) {
        int k = ts[0].ndim < max_ndim ? ts[0].ndim : max_ndim;
        for (int i = 0; i < k; i++)
            out_shape[i] = ts[0].shape[i];
        *out_ndim = k;
    }
    npu_free(arena);
    return NPU_OK;
}

void npu_free(void *p)
{
    free(p);
}

/* ★张量级通用接口：一次推理取回全部输出；返回输出个数(>=1) 或负错误码 */
int npu_infer_ex(int h, const char *model_prefix,
                 const void *in, size_t in_bytes, const int *in_shape, int in_ndim,
                 const char *dtype, int prio, int timeout_ms, int max_outputs,
                 npu_tensor_t *tensors, unsigned char **arena, size_t *arena_bytes)
{
    if (h < 0 || !model_prefix || !in || !in_shape || in_ndim <= 0 || max_outputs <= 0 || !tensors)
        return NPU_E_BADARG;
    if (dtype && strcmp(dtype, "f32"))     /* MVP：输入只支持 f32 */
        return NPU_E_BADARG;
    std::vector<float> fdata(in_bytes / 4);
    memcpy(fdata.data(), in, (in_bytes / 4) * 4);
    std::vector<std::vector<unsigned char> > outs;
    std::vector<std::vector<int> > shapes;
    int r = infer_all(h, model_prefix, fdata, in_shape, in_ndim, prio, timeout_ms, outs, shapes);
    if (r)
        return r;
    size_t total = 0;
    for (size_t i = 0; i < outs.size(); i++)
        total += outs[i].size();
    unsigned char *a = (unsigned char *)malloc(total ? total : 1);
    if (!a)
        return NPU_E_SERVER;
    size_t off = 0;
    int n = 0;
    for (size_t i = 0; i < outs.size() && n < max_outputs; i++, n++) {
        memcpy(a + off, outs[i].data(), outs[i].size());
        tensors[n].bytes = outs[i].size();
        tensors[n].data = a + off;
        tensors[n].ndim = 0;
        for (size_t k = 0; k < shapes[i].size() && tensors[n].ndim < 8; k++)
            tensors[n].shape[tensors[n].ndim++] = shapes[i][k];
        off += outs[i].size();
    }
    if (arena)
        *arena = a;
    else
        free(a);
    if (arena_bytes)
        *arena_bytes = total;
    return n;
}

int npu_status(int h, char *buf, size_t cap)
{
    if (h < 0 || !buf)
        return NPU_E_BADARG;
    std::map<std::string, std::string> rh; std::vector<unsigned char> rp; int st = -1;
    int r = do_request(h, "STATUS", "", nullptr, 0, rh, rp, &st);

    if (r)
        return r;
    std::string s;

    for (auto &kv : rh)
        s += kv.first + "=" + kv.second + "\n";
    snprintf(buf, cap, "%s", s.c_str());
    return st == 0 ? NPU_OK : NPU_E_SERVER;
}

int npu_close(int h)
{
    if (h >= 0)
        ::close(h);
    return NPU_OK;
}

/* ---------- 图像级（CV 便利封装）：YuNet 人脸 ---------- */
namespace {
const float kMinSizes[4][3] = {{10, 16, 24}, {32, 48, -1}, {64, 96, -1}, {128, 192, 256}};
const int   kNa[4] = {3, 2, 2, 3};
const float kSteps[4] = {8, 16, 32, 64};

void gen_priors(std::vector<float> &pri, int inwh)
{
    pri.clear();
    for (int k = 0; k < 4; k++) {
        int g = inwh / (int)kSteps[k];
        for (int i = 0; i < g; i++)
            for (int j = 0; j < g; j++)
                for (int m = 0; m < kNa[k]; m++) {
                    pri.push_back((j + 0.5f) * kSteps[k] / inwh);
                    pri.push_back((i + 0.5f) * kSteps[k] / inwh);
                    pri.push_back(kMinSizes[k][m] / (float)inwh);
                    pri.push_back(kMinSizes[k][m] / (float)inwh);
                }
    }
}

/* 一次 INFER，把全部输出按 COUNT 顺序拼好交给调用方 */
int infer_all(int fd, const std::string &model, const std::vector<float> &data,
              const int *shape, int ndim, int prio, int timeout_ms,
              std::vector<std::vector<unsigned char>> &outs,
              std::vector<std::vector<int>> &shapes)
{
    std::string hdr = "MODEL=" + model + "\nDTYPE=f32\nPRIO=" + std::to_string(prio) +
                      "\nTIMEOUT=" + std::to_string(timeout_ms) + "\nSHAPE=";
    for (int i = 0; i < ndim; i++)
        hdr += std::to_string(shape[i]) + (i + 1 < ndim ? "," : "");
    hdr += "\n";
    std::map<std::string, std::string> rh; std::vector<unsigned char> rp; int st = -1;
    int r = do_request(fd, "INFER", hdr, data.data(), data.size() * sizeof(float), rh, rp, &st);

    if (r) return r;
    if (st != 0) return NPU_E_SERVER;
    int cnt = rh.count("COUNT") ? atoi(rh["COUNT"].c_str()) : 0;

    outs.clear(); shapes.clear();
    size_t off = 0;
    for (int i = 0; i < cnt; i++) {
        std::string ks = "SHAPE" + std::to_string(i), kb = "BYTES" + std::to_string(i);
        size_t nb = rh.count(kb) ? (size_t)atoll(rh[kb].c_str()) : 0;
        if (off + nb > rp.size()) return NPU_E_PROTO;
        outs.push_back(std::vector<unsigned char>(rp.begin() + off, rp.begin() + off + nb));
        off += nb;
        std::vector<int> sh;
        if (rh.count(ks)) {
            char *dup = strdup(rh[ks].c_str()), *save = nullptr;
            for (char *t = strtok_r(dup, ",", &save); t; t = strtok_r(nullptr, ",", &save))
                sh.push_back(atoi(t));
            free(dup);
        }
        shapes.push_back(sh);
    }
    return NPU_OK;
}
}  // namespace

/* 图像 → 张量级推理（读图 + 预处理 + 一次取回全部输出） */
int npu_infer_image(int h, const char *model_prefix, const char *img_path,
                    int W, int H, int norm, int prio, int timeout_ms, int max_outputs,
                    npu_tensor_t *tensors, unsigned char **arena, size_t *arena_bytes)
{
    if (h < 0 || !model_prefix || !img_path || W <= 0 || H <= 0)
        return NPU_E_BADARG;
    cv::Mat img = cv::imread(img_path);
    if (img.empty())
        return NPU_E_BADARG;
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
    int shape[4] = {1, 3, H, W};
    return npu_infer_ex(h, model_prefix, data.data(), data.size() * sizeof(float),
                        shape, 4, "f32", prio, timeout_ms, max_outputs,
                        tensors, arena, arena_bytes);
}

int npu_image_detect_yunet(int h, const char *model_prefix, const char *img_path,
                           int W, int H, int norm, float *out_faces, int max_faces)
{
    if (h < 0 || !model_prefix || !img_path)
        return NPU_E_BADARG;
    cv::Mat img = cv::imread(img_path);

    if (img.empty())
        return NPU_E_BADARG;
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
    int shape[4] = {1, 3, H, W};
    std::vector<std::vector<unsigned char>> outs;
    std::vector<std::vector<int>> shapes;
    int r = infer_all(h, model_prefix, data, shape, 4, 1, 0, outs, shapes);

    if (r)
        return r;
    if (outs.size() < 3)
        return NPU_E_PROTO;
    int n = shapes[0].size() >= 2 ? shapes[0][0] : (int)(outs[0].size() / (14 * 4));
    std::vector<float> pri;

    gen_priors(pri, W);
    if ((int)(pri.size() / 4) != n)
        return NPU_E_PROTO;
    const float *loc = (const float *)outs[0].data();
    const float *conf = (const float *)outs[1].data();
    const float *iou = (const float *)outs[2].data();
    std::vector<cv::Rect2d> boxes;
    std::vector<float> scores;
    std::vector<std::vector<float>> kps;

    for (int i = 0; i < n; i++) {
        float cx = pri[4 * i], cy = pri[4 * i + 1], pw = pri[4 * i + 2], ph = pri[4 * i + 3];
        float cls = conf[1 + 2 * i];
        float obj = iou[i] < 0 ? 0 : (iou[i] > 1 ? 1 : iou[i]);
        float sc = sqrtf(cls > 0 ? cls * obj : 0);
        float bx = (cx + loc[0 + 14 * i] * 0.1f * pw) * W;
        float by = (cy + loc[1 + 14 * i] * 0.1f * ph) * H;
        float bw = pw * expf(loc[2 + 14 * i] * 0.1f) * W;
        float bh = ph * expf(loc[3 + 14 * i] * 0.2f) * H;

        boxes.push_back(cv::Rect2d(bx - bw / 2, by - bh / 2, bw, bh));
        scores.push_back(sc);
        std::vector<float> kp;
        for (int t = 0; t < 5; t++) {
            kp.push_back((cx + loc[4 + 2 * t + 14 * i] * 0.1f * pw) * W);
            kp.push_back((cy + loc[5 + 2 * t + 14 * i] * 0.1f * ph) * H);
        }
        kps.push_back(kp);
    }
    std::vector<int> keep;

    cv::dnn::NMSBoxes(boxes, scores, 0.6f, 0.3f, keep, 1, 5000);
    int cnt = 0;
    for (int idx : keep) {
        if (cnt >= max_faces) break;
        float *o = out_faces + (size_t)cnt * 15;
        o[0] = boxes[idx].x; o[1] = boxes[idx].y; o[2] = boxes[idx].width; o[3] = boxes[idx].height;
        o[4] = scores[idx];
        for (int t = 0; t < 10; t++) o[5 + t] = kps[idx][t];
        cnt++;
    }
    return cnt;
}

// npusvc.cpp — NPU 推理服务（M1）
// 设计要点（对应方案文档《NPU-多应用服务化方案-MVP-2026-09-27.md》）：
//  ① 独占 /dev/npu0 + phyAIEngine（唯一进程；NPU 单实例 ⇒ 串行执行）
//  ② 单工作线程 + 优先级队列（0 最高 / 1 普通 / 2 最低，同级 FIFO）+ 每请求超时
//  ③ 模型缓存（init_graph 一次，多请求复用；超过上限按 LRU 淘汰）
//  ④ 元数据后处理：读引擎写的设备页 → 施加激活 → 写进 App 的 Mat（= 补上厂商运行时漏掉的那步）
//  ⑤ 协议 NPU1：首行 `NPU1 <op|status> <hdrlen> <payloadlen>\n` + 文本头(k=v\n) + 二进制载荷
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <opencv2/core.hpp>
#include <phyAIEngine.h>

/* ---------------- 配置 ---------------- */
static std::string g_sock = "/run/npu/npu.sock";
static size_t      g_max_payload = 64u * 1024 * 1024;   /* 单请求最大输入 64MB */
static int         g_max_models = 4;
static int         g_default_timeout_ms = 20000;
static int         g_queue_cap = 64;
static std::string g_model_dir = "";                    /* 模型目录前缀（客户端可用短名） */
static int         g_fresh = 0;                         /* 0=用缓存引擎（2026-09-27 根因修好后已不需要每请求重建；置 1 可回到绕过模式） */

/* ---------------- 状态 ---------------- */
struct Rule {
    int index;
    int src_page;
    std::string op;   /* none | softmax2 | sigmoid */
};

struct ModelEntry {
    std::shared_ptr<phyAIEngine> eng;
    std::vector<Rule> rules;
    uint64_t last_used = 0;
    uint64_t runs = 0;
};

std::map<std::string, ModelEntry> g_models;
std::mutex g_mtx;
std::condition_variable g_cv_q;
std::deque<std::shared_ptr<struct Job> > g_q[3];
uint64_t g_seq = 0;
bool g_stop = false;
int g_fd_npu = -1;

/* 统计 */
uint64_t g_n_req = 0, g_n_err = 0, g_n_timeout = 0, g_n_drop = 0;
std::chrono::steady_clock::time_point g_t0 = std::chrono::steady_clock::now();

static uint64_t now_ms()
{
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now() - g_t0).count();
}

static void logf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[npusvc %8llu ms] %s\n", (unsigned long long)now_ms(), buf);
    fflush(stderr);
}

struct Job {
    std::string op;                              /* LOAD | INFER */
    std::string model, dtype;
    std::vector<int> shape;
    std::vector<unsigned char> in;
    int prio = 1;
    int timeout_ms = 0;
    uint64_t enq = 0;

    int status = -1;
    std::string msg;
    std::vector<std::pair<std::string, std::string> > rh;  /* 响应头 */
    std::vector<unsigned char> payload;

    std::mutex m;
    std::condition_variable cv;
    bool done = false;
};

/* ---------------- 工具 ---------------- */
static size_t nonzero(const void *p, size_t n)
{
    const unsigned char *q = (const unsigned char *)p;
    size_t c = 0;

    for (size_t i = 0; i < n; i++)
        if (q[i]) c++;
    return c;
}

static void apply_op(const std::string &op, unsigned char *p, size_t sz)
{
    if (op == "none" || op.empty())
        return;
    if (op == "softmax2") {
        if (sz % 8) {
            logf("[post] WARN softmax2 但 size=%zu 非 8 倍数, 不动", sz);
            return;
        }
        float *q = (float *)p;
        size_t n = sz / 8;

        for (size_t i = 0; i < n; i++) {
            float s = 1.0f / (1.0f + expf(q[2 * i] - q[2 * i + 1]));
            q[2 * i] = 1.0f - s;
            q[2 * i + 1] = s;
        }
        return;
    }
    if (op == "sigmoid") {
        float *q = (float *)p;
        for (size_t i = 0; i < sz / 4; i++)
            q[i] = 1.0f / (1.0f + expf(-q[i]));
        return;
    }
    logf("[post] WARN 未知 op=%s, 不动", op.c_str());
}

/* 读元数据 <model>.meta.txt：<输出下标> <引擎页号> <op> */
static std::vector<Rule> load_rules(const std::string &model)
{
    std::vector<Rule> rs;
    std::string path = g_model_dir + model + ".meta.txt";
    FILE *f = fopen(path.c_str(), "r");

    if (!f)
        return rs;
    char line[256];

    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n')
            continue;
        int idx, pg;
        char op[32];

        if (sscanf(line, "%d %d %31s", &idx, &pg, op) == 3)
            rs.push_back(Rule{idx, pg, op});
    }
    fclose(f);
    logf("[post] 模型 %s 载入 %zu 条后处理规则", model.c_str(), rs.size());
    return rs;
}

/* 应用后处理：读引擎页 → op → 写进 Mat（App 读的就是这个 Mat） */
static void postproc(std::vector<cv::Mat> &outs, const std::vector<Rule> &rules)
{
    for (size_t i = 0; i < outs.size(); i++) {
        size_t sz = (size_t)outs[i].total() * outs[i].elemSize();
        bool ruled = false;

        for (size_t k = 0; k < rules.size(); k++)
            if (rules[k].index == (int)i) ruled = true;
        if (!ruled && outs[i].data && sz && nonzero(outs[i].data, sz) == 0)
            logf("[post] WARN out[%zu] 全 0 且无规则（疑似库未交付）size=%zu", i, sz);
    }
    for (size_t k = 0; k < rules.size(); k++) {
        const Rule &r = rules[k];

        if (r.index < 0 || (size_t)r.index >= outs.size())
            continue;
        cv::Mat &m = outs[r.index];
        size_t sz = (size_t)m.total() * m.elemSize();

        if (!m.data || !sz)
            continue;
        size_t len = (sz + 4095UL) & ~4095UL;

        if (g_fd_npu < 0)
            g_fd_npu = open("/dev/npu0", O_RDWR);
        if (g_fd_npu < 0) {
            logf("[post] ERR 无法打开 /dev/npu0: %s", strerror(errno));
            continue;
        }
        void *src = mmap(nullptr, len, PROT_READ, MAP_SHARED, g_fd_npu, (off_t)r.src_page << 12);

        if (src == MAP_FAILED) {
            logf("[post] ERR mmap page=%d 失败: %s（该模型页号可能已变，需重新探）",
                 r.src_page, strerror(errno));
            continue;
        }
        size_t nz0 = nonzero(m.data, sz);

        memcpy(m.data, src, sz);
        apply_op(r.op, (unsigned char *)m.data, sz);
        munmap(src, len);
        logf("[post] out[%d] <- page=%d op=%s size=%zu 非零 %zu->%zu",
             r.index, r.src_page, r.op.c_str(), sz, nz0, nonzero(m.data, sz));
    }
}

static void add_hdr(Job &j, const std::string &k, const std::string &v)
{
    j.rh.push_back(std::make_pair(k, v));
}

static void run_job(std::shared_ptr<Job> j)
{
    uint64_t t0 = now_ms();

    if (j->timeout_ms > 0 && t0 - j->enq > (uint64_t)j->timeout_ms) {
        j->status = 4;
        j->msg = "timeout in queue";
        g_n_timeout++;
        return;
    }
    /* 取/建模型 */
    ModelEntry *me = nullptr;

    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_models.find(j->model);

        if (it == g_models.end()) {
            if ((int)g_models.size() >= g_max_models) {
                auto victim = g_models.begin();
                for (auto p = g_models.begin(); p != g_models.end(); ++p)
                    if (p->second.last_used < victim->second.last_used) victim = p;
                logf("[cache] 淘汰模型 %s", victim->first.c_str());
                g_models.erase(victim);
            }
            ModelEntry ne;
            ne.eng = std::shared_ptr<phyAIEngine>(new phyAIEngine(), [](phyAIEngine *p) { delete p; });
            std::string prefix = g_model_dir.empty() ? j->model : (g_model_dir + j->model);
            uint64_t ti = now_ms();
            int r = ne.eng->init_graph(prefix);

            logf("[cache] init_graph(%s) -> %d (%llu ms)", prefix.c_str(), r,
                 (unsigned long long)(now_ms() - ti));
            if (r) {
                j->status = 10;
                j->msg = "init_graph failed";
                return;
            }
            ne.rules = load_rules(j->model);
            g_models[j->model] = ne;
            it = g_models.find(j->model);
        }
        me = &it->second;
        me->last_used = ++g_seq;
    }
    /* MVP 绕过（实测 2026-09-27）：同一进程内第 2 次起，提交前会被卡住 ~35s 再吃 5s 看门狗
     * （dmesg: [VHA-SUBMIT] done=0 after 5000ms / CMDREQ_RD_WORD=0x0 / MDBG_IDLE=0x0，
     *  而首跑 done=1 after 0ms、CMDREQ_RD_WORD 取满）⇒ 根因是 is_use_repeat=TRUE 下
     *  stream/response 列表堆积陈旧条目（"摘链清理"待做）。init_graph 仅 7ms、首跑 421ms
     *  ⇒ 每请求重建引擎比等 40s 划算得多。修好桥接清理后可关掉本开关。
     */
    if (g_fresh) {
        std::string prefix = g_model_dir.empty() ? j->model : (g_model_dir + j->model);
        me->eng = std::shared_ptr<phyAIEngine>(new phyAIEngine(), [](phyAIEngine *p) { delete p; });
        uint64_t ti = now_ms();
        int r0 = me->eng->init_graph(prefix);
        logf("[eng] fresh init_graph(%s) -> %d (%llu ms)", prefix.c_str(), r0,
             (unsigned long long)(now_ms() - ti));
        if (r0) {
            j->status = 10;
            j->msg = "init_graph failed(fresh)";
            return;
        }
    }
    if (j->op == "LOAD") {
        j->status = 0;
        add_hdr(*j, "MSG", "loaded");
        logf("[req#%llu] LOAD %s ok", (unsigned long long)j->enq, j->model.c_str());
        return;
    }
    /* 构造输入 Mat（引用请求缓冲；任意 ndim） */
    cv::Mat in;

    if (j->shape.size() == 1)
        in = cv::Mat(1, &j->shape[0], CV_32F, (void *)j->in.data());
    else
        in = cv::Mat((int)j->shape.size(), j->shape.data(), CV_32F, (void *)j->in.data());
    std::vector<cv::Mat> ins{in}, outs;
    int r = me->eng->execute_graph(ins, outs);

    if (r) {
        j->status = 11;
        j->msg = "execute_graph=" + std::to_string(r);
        logf("[req#%llu] INFER %s execute_graph -> %d FAIL", (unsigned long long)j->enq,
             j->model.c_str(), r);
        return;
    }
    postproc(outs, me->rules);
    add_hdr(*j, "COUNT", std::to_string(outs.size()));
    for (size_t i = 0; i < outs.size(); i++) {
        size_t nb = (size_t)outs[i].total() * outs[i].elemSize();

        add_hdr(*j, "BYTES" + std::to_string(i), std::to_string(nb));
        if (outs[i].dims > 0 && outs[i].data) {
            std::string sh;

            bool ok = true;
            for (int d = 0; d < outs[i].dims; d++) {
                int v = outs[i].size[d];
                if (v <= 0) { ok = false; break; }
                sh += std::to_string(v) + (d + 1 < outs[i].dims ? "," : "");
            }
            if (ok)
                add_hdr(*j, "SHAPE" + std::to_string(i), sh);
        }
        if (nb)
            j->payload.insert(j->payload.end(), outs[i].data, outs[i].data + nb);
    }
    me->runs++;
    j->status = 0;
    logf("[req#%llu] INFER %s prio=%d ok: %zu 输出 %zu B, 耗时 %llu ms", (unsigned long long)j->enq,
         j->model.c_str(), j->prio, outs.size(), j->payload.size(),
         (unsigned long long)(now_ms() - t0));
}

/* ---------------- 工作线程 ---------------- */
static void worker()
{
    for (;;) {
        std::shared_ptr<Job> j;

        {
            std::unique_lock<std::mutex> lk(g_mtx);
            g_cv_q.wait(lk, [] {
                return g_stop || g_q[0].size() || g_q[1].size() || g_q[2].size();
            });
            for (int p = 0; p < 3; p++)
                if (!g_q[p].empty()) { j = g_q[p].front(); g_q[p].pop_front(); break; }
            if (!j && g_stop)
                return;
        }
        if (!j)
            continue;
        run_job(j);
        {
            std::lock_guard<std::mutex> lk(j->m);
            j->done = true;
        }
        j->cv.notify_all();
    }
}

/* ---------------- 协议 ---------------- */
static int read_line(int fd, std::string &out, size_t max = 512)
{
    out.clear();
    char c;

    for (;;) {
        ssize_t k = ::recv(fd, &c, 1, 0);
        if (k <= 0)
            return -1;
        if (c == '\n')
            return 0;
        out += c;
        if (out.size() > max)
            return -1;
    }
}

static int read_all(int fd, void *p, size_t n)
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

static int write_all(int fd, const void *p, size_t n)
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

static std::map<std::string, std::string> parse_hdr(const std::string &s)
{
    std::map<std::string, std::string> m;
    size_t p = 0;

    while (p < s.size()) {
        size_t e = s.find('\n', p);
        std::string line = s.substr(p, e == std::string::npos ? std::string::npos : e - p);

        p = (e == std::string::npos) ? s.size() : e + 1;
        size_t eq = line.find('=');

        if (eq != std::string::npos)
            m[line.substr(0, eq)] = line.substr(eq + 1);
    }
    return m;
}

static void send_resp(int fd, int status, const std::vector<std::pair<std::string, std::string> > &rh,
                      const std::vector<unsigned char> &payload)
{
    std::string h;

    for (size_t i = 0; i < rh.size(); i++)
        h += rh[i].first + "=" + rh[i].second + "\n";
    char line[128];
    int n = snprintf(line, sizeof(line), "NPU1 %d %zu %zu\n", status, h.size(), payload.size());

    if (write_all(fd, line, n) || (h.size() && write_all(fd, h.data(), h.size())) ||
        (payload.size() && write_all(fd, payload.data(), payload.size())))
        logf("[conn] 写响应失败: %s", strerror(errno));
}

static void handle_conn(int fd)
{
    for (;;) {
        std::string first;

        if (read_line(fd, first) < 0)
            return;
        char magic[16], op[16];
        size_t hl = 0, pl = 0;

        if (sscanf(first.c_str(), "%15s %15s %zu %zu", magic, op, &hl, &pl) != 4 ||
            strcmp(magic, "NPU1")) {
            send_resp(fd, 2, {{"MSG", "bad header"}}, {});
            return;
        }
        if (pl > g_max_payload || hl > 8192) {
            send_resp(fd, 2, {{"MSG", "too large"}}, {});
            return;
        }
        std::string hdr(hl, 0);

        if (hl && read_all(fd, &hdr[0], hl))
            return;
        std::vector<unsigned char> payload(pl);

        if (pl && read_all(fd, payload.data(), pl))
            return;
        auto hm = parse_hdr(hdr);

        if (!strcmp(op, "STATUS")) {
            std::lock_guard<std::mutex> lk(g_mtx);
            std::vector<std::pair<std::string, std::string> > rh;
            std::string ms;

            for (auto &kv : g_models)
                ms += kv.first + ":" + std::to_string(kv.second.runs) + " ";
            rh.push_back({"MODELS", ms.empty() ? "-" : ms});
            rh.push_back({"Q0", std::to_string(g_q[0].size())});
            rh.push_back({"Q1", std::to_string(g_q[1].size())});
            rh.push_back({"Q2", std::to_string(g_q[2].size())});
            rh.push_back({"REQS", std::to_string(g_n_req)});
            rh.push_back({"ERRS", std::to_string(g_n_err)});
            rh.push_back({"TIMEOUTS", std::to_string(g_n_timeout)});
            rh.push_back({"UPTIME_MS", std::to_string(now_ms())});
            rh.push_back({"PID", std::to_string(getpid())});
            send_resp(fd, 0, rh, {});
            continue;
        }
        auto j = std::make_shared<Job>();

        j->op = op;
        j->model = hm.count("MODEL") ? hm["MODEL"] : "";
        j->dtype = hm.count("DTYPE") ? hm["DTYPE"] : "f32";
        j->prio = hm.count("PRIO") ? atoi(hm["PRIO"].c_str()) : 1;
        j->timeout_ms = hm.count("TIMEOUT") ? atoi(hm["TIMEOUT"].c_str()) : 0;
        if (j->timeout_ms <= 0)
            j->timeout_ms = g_default_timeout_ms;
        if (j->prio < 0 || j->prio > 2)
            j->prio = 1;
        if (hm.count("SHAPE")) {
            char *dup = strdup(hm["SHAPE"].c_str()), *save = nullptr;
            for (char *t = strtok_r(dup, ",", &save); t; t = strtok_r(nullptr, ",", &save))
                j->shape.push_back(atoi(t));
            free(dup);
        }
        j->in = std::move(payload);
        if (j->model.empty() || (j->op == "INFER" && (j->shape.empty() || j->in.empty()))) {
            send_resp(fd, 2, {{"MSG", "missing MODEL/SHAPE/payload"}}, {});
            continue;
        }
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            size_t qd = g_q[0].size() + g_q[1].size() + g_q[2].size();

            if (qd >= (size_t)g_queue_cap) {
                g_n_drop++;
                send_resp(fd, 5, {{"MSG", "queue full"}}, {});
                continue;
            }
            j->enq = ++g_seq;
            g_n_req++;
            g_q[j->prio].push_back(j);
        }
        g_cv_q.notify_one();
        {
            std::unique_lock<std::mutex> lk(j->m);
            j->cv.wait(lk, [&] { return j->done; });
        }
        if (j->status != 0)
            g_n_err++;
        send_resp(fd, j->status, j->rh, j->payload);
    }
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sock") && i + 1 < argc) g_sock = argv[++i];
        else if (!strcmp(argv[i], "--models") && i + 1 < argc) g_model_dir = argv[++i];
        else if (!strcmp(argv[i], "--max-models") && i + 1 < argc) g_max_models = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) g_default_timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--queue") && i + 1 < argc) g_queue_cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fresh-per-request") && i + 1 < argc) g_fresh = atoi(argv[++i]);
        else { fprintf(stderr, "用法: %s [--sock PATH] [--models PREFIX] [--max-models N] [--timeout-ms N] [--queue N] [--fresh-per-request 0|1]\n", argv[0]); return 1; }
    }
    /* 建目录（/run/npu 需 root；失败则退到 /tmp） */
    std::string dir = g_sock.substr(0, g_sock.rfind('/'));

    if (!dir.empty() && access(dir.c_str(), F_OK) && mkdir(dir.c_str(), 0775) && errno != EEXIST) {
        logf("建目录 %s 失败(%s)，退到 /tmp/npu.sock", dir.c_str(), strerror(errno));
        g_sock = "/tmp/npu.sock";
    }
    ::unlink(g_sock.c_str());
    int srv = ::socket(AF_UNIX, SOCK_STREAM, 0);

    if (srv < 0) { logf("socket: %s", strerror(errno)); return 1; }
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", g_sock.c_str());
    if (::bind(srv, (struct sockaddr *)&a, sizeof(a)) || ::listen(srv, 32)) {
        logf("bind/listen %s: %s", g_sock.c_str(), strerror(errno));
        return 1;
    }
    ::chmod(g_sock.c_str(), 0666);   /* MVP：放开权限；产品化改按组 */
    logf("npusvc 启动: sock=%s models前缀=%s 队列上限=%d 默认超时=%dms pid=%d",
         g_sock.c_str(), g_model_dir.c_str(), g_queue_cap, g_default_timeout_ms, getpid());
    logf("运行模式: 每请求重建引擎=%s", g_fresh ? "是(绕过同进程+40s)" : "否(用缓存)");
    std::thread w(worker);

    for (;;) {
        int fd = ::accept(srv, nullptr, nullptr);

        if (fd < 0) {
            if (errno == EINTR) continue;
            logf("accept: %s", strerror(errno));
            break;
        }
        std::thread([fd] { handle_conn(fd); ::close(fd); }).detach();
    }
    g_stop = true;
    g_cv_q.notify_all();
    w.join();
    logf("npusvc 退出");
    return 0;
}

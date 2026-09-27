// npuworker.cpp — 进程池 worker：独占 /dev/npu0，为一个模型跑多次推理（M1.5）
// 为什么需要独立进程（2026-09-27 实测定案）：
//   厂商库 libnpusession.so 只用 npu_user_rsp.sid 匹配完成响应，而同进程内不同图的提交 sid
//   恒为 0x10101 ⇒ 第 2 个图的任务永远等不到响应（WaitForCompletion 永久挂死）；
//   实测"切模型时析构旧 phyAIEngine"（--max-models 1）**无效** ⇒ 映射活在进程级。
//   ⇒ 隔离边界必须是"进程"：每个模型一个 worker，由 npusvc(supervisor) 按需拉起、切模型即换。
// 协议：与 supervisor 相同的 NPU1 帧，但走管道 fd0/fd1（不用 socket，无需额外权限）：
//   请求: "NPU1 <op> <hdrlen> <payloadlen>\n" + 文本头(k=v\n) + 二进制载荷
//   响应: "NPU1 <status> <hdrlen> <payloadlen>\n" + 文本头(k=v\n) + 二进制载荷
//   op = LOAD | INFER | STATUS | QUIT   （status: 0 成功 / 2 坏请求 / 10 init 失败 / 11 执行失败）
// 用法: npuworker --models /path/to/model/ [--log /tmp/npuworker.log]
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include <opencv2/core.hpp>
#include <phyAIEngine.h>

static std::string g_model_dir = "";
static FILE       *g_log = nullptr;
/* ★协议通道：厂商库会往 stdout 打 INFO 行（INFO: NPU clock / Loading xxx.json 等），
 * 而 stdout 正是我们的协议通道 ⇒ 必须把协议 fd 复制到高位，再把 0/1 让给库（否则首行被污染）。 */
static int         g_in_fd = 0;
static int         g_out_fd = 1;
static int         g_fd_npu = -1;
static uint64_t    g_runs = 0;

static void logf(const char *fmt, ...)
{
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static size_t nonzero(const void *p, size_t n)
{
    const unsigned char *b = (const unsigned char *)p;
    size_t c = 0;
    for (size_t i = 0; i < n; i++) if (b[i]) c++;
    return c;
}

/* ---------------- 后处理（与 npusvc 同口径：读引擎页 → 激活 → 写进 App 的 Mat） ---------------- */
struct Rule { int index; int src_page; std::string op; };

static std::vector<Rule> load_rules(const std::string &model)
{
    std::vector<Rule> rs;
    std::string path = g_model_dir + model + ".meta.txt";
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return rs;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        int idx, pg; char op[32];
        if (sscanf(line, "%d %d %31s", &idx, &pg, op) == 3)
            rs.push_back(Rule{idx, pg, op});
    }
    fclose(f);
    logf("[post] 模型 %s 载入 %zu 条后处理规则", model.c_str(), rs.size());
    return rs;
}

static void apply_op(const std::string &op, unsigned char *p, size_t sz)
{
    if (op == "none") return;
    if (op == "softmax2") {
        if (sz % 8) { logf("[post] WARN softmax2 但 size=%zu 非 8 倍数, 不动", sz); return; }
        float *q = (float *)p;
        for (size_t i = 0; i < sz / 8; i++) {
            float s = 1.0f / (1.0f + expf(q[2 * i] - q[2 * i + 1]));
            q[2 * i] = 1.0f - s;
            q[2 * i + 1] = s;
        }
        return;
    }
    if (op == "sigmoid") {
        float *q = (float *)p;
        for (size_t i = 0; i < sz / 4; i++) q[i] = 1.0f / (1.0f + expf(-q[i]));
        return;
    }
    logf("[post] WARN 未知 op=%s, 不动", op.c_str());
}

static void postproc(std::vector<cv::Mat> &outs, const std::vector<Rule> &rules)
{
    for (size_t k = 0; k < rules.size(); k++) {
        const Rule &r = rules[k];
        if (r.index < 0 || (size_t)r.index >= outs.size()) continue;
        cv::Mat &m = outs[r.index];
        size_t sz = (size_t)m.total() * m.elemSize();
        if (!m.data || !sz) continue;
        size_t len = (sz + 4095UL) & ~4095UL;
        if (g_fd_npu < 0) g_fd_npu = open("/dev/npu0", O_RDWR);
        if (g_fd_npu < 0) { logf("[post] ERR 无法打开 /dev/npu0: %s", strerror(errno)); continue; }
        void *src = mmap(nullptr, len, PROT_READ, MAP_SHARED, g_fd_npu, (off_t)r.src_page << 12);
        if (src == MAP_FAILED) {
            logf("[post] ERR mmap page=%d 失败: %s（页号可能已变，需重探）", r.src_page, strerror(errno));
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

/* ---------------- 管道 IO ---------------- */
static int read_all(int fd, void *p, size_t n)
{
    char *q = (char *)p; size_t off = 0;
    while (off < n) {
        ssize_t k = ::read(fd, q + off, n - off);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        off += (size_t)k;
    }
    return 0;
}

static int write_all(int fd, const void *p, size_t n)
{
    const char *q = (const char *)p; size_t off = 0;
    while (off < n) {
        ssize_t k = ::write(fd, q + off, n - off);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        off += (size_t)k;
    }
    return 0;
}

static int read_line(int fd, std::string &out, size_t max = 1024)
{
    out.clear(); char c;
    for (;;) {
        ssize_t k = ::read(fd, &c, 1);
        if (k <= 0) return -1;
        if (c == '\n') return 0;
        out += c;
        if (out.size() > max) return -1;
    }
}

static std::string hdrs_to_text(const std::vector<std::pair<std::string, std::string> > &h)
{
    std::string s;
    for (size_t i = 0; i < h.size(); i++) s += h[i].first + "=" + h[i].second + "\n";
    return s;
}

static std::map<std::string, std::string> parse_hdr(const std::string &s)
{
    std::map<std::string, std::string> m;
    size_t p = 0;
    while (p < s.size()) {
        size_t e = s.find('\n', p);
        std::string line = s.substr(p, e == std::string::npos ? std::string::npos : e - p);
        size_t eq = line.find('=');
        if (eq != std::string::npos) m[line.substr(0, eq)] = line.substr(eq + 1);
        if (e == std::string::npos) break;
        p = e + 1;
    }
    return m;
}

static int send_rsp(int status, const std::vector<std::pair<std::string, std::string> > &h,
                    const std::vector<unsigned char> &pl)
{
    std::string ht = hdrs_to_text(h);
    char head[128];
    int n = snprintf(head, sizeof(head), "NPU1 %d %zu %zu\n", status, ht.size(), pl.size());
    if (write_all(g_out_fd, head, (size_t)n)) return -1;
    if (!ht.empty() && write_all(g_out_fd, ht.data(), ht.size())) return -1;
    if (!pl.empty() && write_all(g_out_fd, pl.data(), pl.size())) return -1;
    return 0;
}

/* ---------------- 主循环 ---------------- */
int main(int argc, char **argv)
{
    std::string logpath = "/tmp/npuworker.log";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--models") && i + 1 < argc) g_model_dir = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
    }
    if (!g_model_dir.empty() && g_model_dir[g_model_dir.size() - 1] != '/') g_model_dir += "/";
    signal(SIGPIPE, SIG_IGN);
    /* ★关键：协议通道与"库的 stdout"必须隔离 */
    g_in_fd  = dup(0);
    g_out_fd = dup(1);
    if (g_in_fd < 0) g_in_fd = 0;
    if (g_out_fd < 0) g_out_fd = 1;
    {
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) { dup2(dn, 0); if (dn != 0 && dn != 1) close(dn); }
        /* 库的 stdout 噪音保留到日志文件，便于排障（不要再指回协议通道） */
        int lf = open(logpath.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (lf >= 0) { dup2(lf, 1); if (lf > 2) close(lf); }
    }
    g_log = fopen(logpath.c_str(), "a");
    /* 注意：**不要**在这里预先 open("/dev/npu0") 或 init_graph —— 设备与引擎留给第一次请求，
     * 这样 worker 的空闲进程不占用设备，supervisor 可以按需切模型。 */
    logf("[worker %d] 启动 models=%s", (int)getpid(), g_model_dir.c_str());

    std::shared_ptr<phyAIEngine> eng;
    std::vector<Rule> rules;
    std::string cur_model;

    for (;;) {
        std::string line;
        if (read_line(g_in_fd, line)) break;
        /* 首行: NPU1 <op> <hdrlen> <payloadlen> */
        char op[32] = {0};
        size_t hl = 0, pl = 0;
        if (sscanf(line.c_str(), "NPU1 %31s %zu %zu", op, &hl, &pl) != 3) {
            send_rsp(2, std::vector<std::pair<std::string, std::string> >(),
                     std::vector<unsigned char>());
            continue;
        }
        std::string htxt(hl, '\0'), payload(pl, '\0');
        if ((hl && read_all(g_in_fd, &htxt[0], hl)) || (pl && read_all(g_in_fd, &payload[0], pl)))
            break;
        std::map<std::string, std::string> h = parse_hdr(htxt);

        if (!strcmp(op, "QUIT")) {
            logf("[worker %d] QUIT，退出", (int)getpid());
            break;
        }
        std::vector<std::pair<std::string, std::string> > rh;
        std::vector<unsigned char> rpl;

        if (!strcmp(op, "STATUS")) {
            rh.push_back(std::make_pair("RUNS", std::to_string(g_runs)));
            rh.push_back(std::make_pair("MODEL", cur_model));
            rh.push_back(std::make_pair("PID", std::to_string((int)getpid())));
            send_rsp(0, rh, rpl);
            continue;
        }
        std::string model = h.count("MODEL") ? h["MODEL"] : "";

        if (model.empty()) {
            rh.push_back(std::make_pair("MSG", "missing MODEL"));
            send_rsp(2, rh, rpl);
            continue;
        }
        if (model != cur_model) {
            eng.reset(new phyAIEngine());
            std::string prefix = g_model_dir + model;
            int r = eng->init_graph(prefix);
            logf("[worker %d] init_graph(%s) -> %d", (int)getpid(), prefix.c_str(), r);
            if (r) {
                eng.reset();
                rh.push_back(std::make_pair("MSG", "init_graph=" + std::to_string(r)));
                send_rsp(10, rh, rpl);
                continue;
            }
            rules = load_rules(model);
            cur_model = model;
        }
        if (!strcmp(op, "LOAD")) {
            rh.push_back(std::make_pair("MSG", "loaded"));
            send_rsp(0, rh, rpl);
            continue;
        }
        if (strcmp(op, "INFER")) {
            rh.push_back(std::make_pair("MSG", std::string("unknown op ") + op));
            send_rsp(2, rh, rpl);
            continue;
        }
        /* 组输入 Mat（引用请求载荷；任意 ndim） */
        std::vector<int> shape;
        if (h.count("SHAPE")) {
            std::string s = h["SHAPE"], cur;
            for (size_t i = 0; i <= s.size(); i++) {
                if (i == s.size() || s[i] == ',') { if (!cur.empty()) { shape.push_back(atoi(cur.c_str())); cur.clear(); } }
                else cur += s[i];
            }
        }
        if (shape.empty() || payload.empty()) {
            rh.push_back(std::make_pair("MSG", "bad SHAPE/payload"));
            send_rsp(2, rh, rpl);
            continue;
        }
        cv::Mat in;
        if (shape.size() == 1) in = cv::Mat(1, &shape[0], CV_32F, (void *)payload.data());
        else in = cv::Mat((int)shape.size(), shape.data(), CV_32F, (void *)payload.data());
        std::vector<cv::Mat> ins{in}, outs;
        int r = eng->execute_graph(ins, outs);
        if (r) {
            logf("[worker %d] execute_graph(%s) -> %d FAIL", (int)getpid(), model.c_str(), r);
            rh.push_back(std::make_pair("MSG", "execute_graph=" + std::to_string(r)));
            send_rsp(11, rh, rpl);
            continue;
        }
        postproc(outs, rules);          /* ★补上厂商运行时漏掉的"设备页→App Mat"那步 */
        g_runs++;
        rh.push_back(std::make_pair("COUNT", std::to_string(outs.size())));
        for (size_t i = 0; i < outs.size(); i++) {
            size_t nb = (size_t)outs[i].total() * outs[i].elemSize();
            rh.push_back(std::make_pair("BYTES" + std::to_string(i), std::to_string(nb)));
            if (outs[i].dims > 0 && outs[i].data) {
                std::string sh; bool ok = true;
                for (int d = 0; d < outs[i].dims; d++) {
                    int v = outs[i].size[d];
                    if (v <= 0) { ok = false; break; }
                    sh += std::to_string(v) + (d + 1 < outs[i].dims ? "," : "");
                }
                if (ok) rh.push_back(std::make_pair("SHAPE" + std::to_string(i), sh));
            }
            if (nb) rpl.insert(rpl.end(), outs[i].data, outs[i].data + nb);
        }
        logf("[worker %d] INFER %s ok: %zu 输出 %zu B", (int)getpid(), model.c_str(), outs.size(), rpl.size());
        if (send_rsp(0, rh, rpl)) break;
    }
    logf("[worker %d] 退出", (int)getpid());
    return 0;
}

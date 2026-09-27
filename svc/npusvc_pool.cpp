// npusvc_pool.cpp — NPU 推理服务 supervisor（进程池版，M1.5）
//
// 为什么用进程池（2026-09-27 实测定案）：
//   厂商库 libnpusession.so 只按 npu_user_rsp.sid 匹配完成响应，而同一进程内不同图的提交 sid
//   恒为 0x10101 ⇒ 第 2 个图的任务永远等不到响应（WaitForCompletion 永久挂死）；
//   实测"切模型析构旧 phyAIEngine"无效 ⇒ 映射活在进程级。
//   ⇒ 隔离边界 = 进程：每个模型一个 npuworker 子进程，supervisor 串行持有唯一 worker。
//
// 角色划分：
//   supervisor（本程序）：只做 socket/排队/优先级/超时/转发，**不碰设备、不加载任何模型**
//   worker（npuworker）：独占 /dev/npu0 + phyAIEngine，跑一个模型（见 npuworker.cpp）
// 协议：对客户端 = NPU1（与单进程版完全一致，客户端零改动）；对 worker = NPU1 帧走管道。
// 关键健壮性：worker 有**响应超时**，超时即击杀并回收 ⇒ "库挂死"变成可观测错误（status 14）+ 下次自动换新进程。
//
// 用法：
//   npusvc_pool [--sock /tmp/npu.sock] [--models /dev/shm/nputest/model/]
//               [--worker ./npuworker] [--timeout-ms 20000] [--worker-timeout-ms 30000]
//               [--queue 64] [--idle-kill-ms 0]
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
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

/* ---------------- 配置 ---------------- */
static std::string g_sock = "/tmp/npu.sock";
static std::string g_model_dir = "";
static std::string g_worker_bin = "./npuworker";
static std::string g_worker_log = "/tmp/npuworker.log";
static size_t      g_max_payload = 64u * 1024 * 1024;
static int         g_default_timeout_ms = 20000;   /* 队列内超时 */
static int         g_worker_timeout_ms = 30000;    /* worker 响应超时（超时即击杀） */
static int         g_queue_cap = 64;
static int         g_idle_kill_ms = 0;             /* >0：空闲这么久就回收 worker，把设备让出来 */

/* ---------------- 状态 ---------------- */
struct Job {
    std::string op;                     /* LOAD | INFER */
    std::string model, dtype;
    std::vector<int> shape;
    std::vector<unsigned char> in;
    int prio = 1;
    int timeout_ms = 0;
    uint64_t enq = 0;      /* ★入队时刻(now_ms)；队列超时据此判断 */
    uint64_t seq = 0;      /* 日志用序号（与 enq 分开，勿混用） */

    int status = -1;
    std::string msg;
    std::vector<std::pair<std::string, std::string> > rh;
    std::vector<unsigned char> payload;

    std::mutex m;
    std::condition_variable cv;
    bool done = false;
};

static std::mutex  g_mtx;                 /* 保护队列/统计 */
static std::condition_variable g_cv_q;
static std::deque<std::shared_ptr<Job> > g_q[3];
static uint64_t    g_seq = 0;
static bool        g_stop = false;

static uint64_t g_n_req = 0, g_n_err = 0, g_n_timeout = 0, g_n_drop = 0;
static uint64_t g_n_switch = 0, g_n_reap = 0, g_n_wto = 0;
static std::map<std::string, uint64_t> g_runs;   /* 每模型成功次数 */

static uint64_t now_ms()
{
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

static uint64_t g_t0 = now_ms();

static void logf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[pool %8llu ms] %s\n", (unsigned long long)(now_ms() - g_t0), buf);
    fflush(stderr);
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
        ssize_t k = ::send(fd, q + off, n - off, MSG_NOSIGNAL);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        off += (size_t)k;
    }
    return 0;
}

static int pipe_all_read(int fd, void *p, size_t n)
{
    char *q = (char *)p; size_t off = 0;
    while (off < n) {
        ssize_t k = ::read(fd, q + off, n - off);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        off += (size_t)k;
    }
    return 0;
}

static int pipe_all_write(int fd, const void *p, size_t n)
{
    const char *q = (const char *)p; size_t off = 0;
    while (off < n) {
        ssize_t k = ::write(fd, q + off, n - off);
        if (k <= 0) { if (k < 0 && errno == EINTR) continue; return -1; }
        off += (size_t)k;
    }
    return 0;
}

/* 带超时的管道写：worker 挂死时管道缓冲会写满 ⇒ 必须能超时退出，
 * 否则 supervisor 自己的工作线程被卡死（整个服务失去响应）。返回 -2 = 超时。 */
static int pipe_write_tmo(int fd, const void *p, size_t n, int tmo_ms)
{
    const char *q = (const char *)p;
    size_t off = 0;
    int waited = 0;
    while (off < n) {
        struct pollfd pf = { fd, POLLOUT, 0 };
        int pr = poll(&pf, 1, 200);
        if (pr < 0) { if (errno == EINTR) continue; return -1; }
        if (pr == 0) {
            waited += 200;
            if (tmo_ms > 0 && waited >= tmo_ms) return -2;
            continue;
        }
        ssize_t k = ::write(fd, q + off, n - off);
        if (k < 0) { if (errno == EINTR) continue; return -1; }
        if (k == 0) return -1;
        off += (size_t)k;
        waited = 0;
    }
    return 0;
}

static int read_line(int fd, std::string &out, size_t max = 1024)
{
    out.clear(); char c;
    for (;;) {
        ssize_t k = ::recv(fd, &c, 1, 0);
        if (k <= 0) return -1;
        if (c == '\n') return 0;
        out += c;
        if (out.size() > max) return -1;
    }
}

static int pipe_read_line(int fd, std::string &out, size_t max = 1024)
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

static std::map<std::string, std::string> parse_hdr(const std::string &s)
{
    std::map<std::string, std::string> m;
    size_t p = 0;
    while (p <= s.size()) {
        size_t e = s.find('\n', p);
        std::string line = s.substr(p, e == std::string::npos ? std::string::npos : e - p);
        size_t eq = line.find('=');
        if (eq != std::string::npos) m[line.substr(0, eq)] = line.substr(eq + 1);
        if (e == std::string::npos) break;
        p = e + 1;
    }
    return m;
}

static void send_resp(int fd, int status, const std::vector<std::pair<std::string, std::string> > &rh,
                      const std::vector<unsigned char> &payload)
{
    std::string h;
    for (size_t i = 0; i < rh.size(); i++) h += rh[i].first + "=" + rh[i].second + "\n";
    char line[128];
    int n = snprintf(line, sizeof(line), "NPU1 %d %zu %zu\n", status, h.size(), payload.size());
    if (write_all(fd, line, n) || (h.size() && write_all(fd, h.data(), h.size())) ||
        (payload.size() && write_all(fd, payload.data(), payload.size())))
        logf("[conn] 写响应失败: %s", strerror(errno));
}

/* ---------------- worker 管理（同一时刻仅一个） ---------------- */
struct Worker {
    pid_t pid = -1;
    int   in_fd = -1;      /* supervisor -> worker */
    int   out_fd = -1;     /* worker -> supervisor */
    std::string model;
    uint64_t last_use = 0;
};

static Worker g_w;
static std::mutex g_w_mtx;   /* 只在工作线程里用，但保留以便将来多 worker */

/* 强制击杀 worker（挂死/超时用）：SIGKILL + 回收 + 清状态 ⇒ 下一个请求会拉起全新进程 */
static void worker_kill_locked(const char *why)
{
    if (g_w.pid <= 0) return;
    g_n_wto++;
    logf("[worker] ★%s ⇒ 击杀 pid=%d（下次自动换新进程）", why, (int)g_w.pid);
    kill(g_w.pid, SIGKILL);
    int st = 0;
    waitpid(g_w.pid, &st, 0);
    if (g_w.in_fd >= 0) close(g_w.in_fd);
    if (g_w.out_fd >= 0) close(g_w.out_fd);
    g_w.pid = -1; g_w.in_fd = -1; g_w.out_fd = -1; g_w.model.clear();
}

static void worker_stop_locked()
{
    if (g_w.pid <= 0) return;
    /* 礼貌退出：QUIT，等 800ms；不退出则 SIGTERM→SIGKILL */
    char q[] = "NPU1 QUIT 0 0\n";
    if (g_w.in_fd >= 0) { pipe_all_write(g_w.in_fd, q, sizeof(q) - 1); ::close(g_w.in_fd); }
    g_w.in_fd = -1;
    if (g_w.out_fd >= 0) { ::close(g_w.out_fd); g_w.out_fd = -1; }
    int st = 0, waited = 0, gone = 0;
    while (waited < 800) {
        pid_t r = waitpid(g_w.pid, &st, WNOHANG);
        if (r == g_w.pid) { gone = 1; break; }
        if (r < 0) { gone = 1; break; }
        usleep(50000); waited += 50;
    }
    if (!gone) {
        kill(g_w.pid, SIGTERM);
        usleep(200000);
        if (waitpid(g_w.pid, &st, WNOHANG) != g_w.pid) {
            kill(g_w.pid, SIGKILL);
            waitpid(g_w.pid, &st, 0);
        }
        logf("[worker] pid=%d 强制回收", (int)g_w.pid);
    }
    logf("[worker] pid=%d 已停（模型=%s）", (int)g_w.pid, g_w.model.c_str());
    g_w.pid = -1;
    g_w.model.clear();
}

static int worker_start_locked(const std::string &model)
{
    int pin[2], pout[2];
    if (pipe2(pin, O_CLOEXEC) || pipe2(pout, O_CLOEXEC)) {
        logf("[worker] pipe2 失败: %s", strerror(errno));
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        logf("[worker] fork 失败: %s", strerror(errno));
        close(pin[0]); close(pin[1]); close(pout[0]); close(pout[1]);
        return -1;
    }
    if (pid == 0) {
        /* 子进程：stdin=pin[0]、stdout=pout[1]，stderr 落到 worker 日志 */
        dup2(pin[0], 0);
        dup2(pout[1], 1);
        int lf = open(g_worker_log.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (lf >= 0) { dup2(lf, 2); if (lf > 2) close(lf); }
        close(pin[0]); close(pin[1]); close(pout[0]); close(pout[1]);
        /* 环境：worker 需要 /usr/local/lib 下的厂商库 */
        setenv("LD_LIBRARY_PATH", "/usr/local/lib", 1);
        const char *argv[8];
        int n = 0;
        argv[n++] = g_worker_bin.c_str();
        argv[n++] = "--models"; argv[n++] = g_model_dir.c_str();
        argv[n++] = "--log";    argv[n++] = g_worker_log.c_str();
        argv[n++] = nullptr;
        execv(argv[0], (char *const *)argv);
        /* execv 失败：兜底走 PATH */
        execvp("npuworker", (char *const *)argv);
        _exit(127);
    }
    close(pin[0]); close(pout[1]);
    g_w.pid = pid;
    g_w.in_fd = pin[1];
    g_w.out_fd = pout[0];
    g_w.model = model;
    g_w.last_use = now_ms();
    g_n_switch++;
    logf("[worker] pid=%d 已起（模型=%s）", (int)pid, model.c_str());
    return 0;
}

static int worker_ensure_locked(const std::string &model)
{
    if (g_w.pid > 0 && g_w.model == model) return 0;
    if (g_w.pid > 0) {
        logf("[worker] 模型切换 %s -> %s，回收旧 worker", g_w.model.c_str(), model.c_str());
        worker_stop_locked();
    }
    return worker_start_locked(model);
}

/* 向 worker 发一帧并读回一帧（带超时；超时=击杀 worker） */
static int worker_call_locked(const Job &j, std::vector<std::pair<std::string, std::string> > &rh,
                              std::vector<unsigned char> &pl, std::string &err)
{
    /* 组请求头 */
    std::string h = "MODEL=" + j.model + "\nDTYPE=" + (j.dtype.empty() ? "f32" : j.dtype) + "\n";
    if (!j.shape.empty()) {
        std::string s;
        for (size_t i = 0; i < j.shape.size(); i++)
            s += std::to_string(j.shape[i]) + (i + 1 < j.shape.size() ? "," : "");
        h += "SHAPE=" + s + "\n";
    }
    char line[128];
    int n = snprintf(line, sizeof(line), "NPU1 %s %zu %zu\n", j.op.c_str(), h.size(), j.in.size());
    int wr = pipe_write_tmo(g_w.in_fd, line, n, g_worker_timeout_ms);
    if (!wr && !h.empty()) wr = pipe_write_tmo(g_w.in_fd, h.data(), h.size(), g_worker_timeout_ms);
    if (!wr && !j.in.empty()) wr = pipe_write_tmo(g_w.in_fd, j.in.data(), j.in.size(), g_worker_timeout_ms);
    if (wr) {
        if (wr == -2) { worker_kill_locked("写请求超时(worker 不消费)"); err = "worker 写超时（已击杀）"; return -2; }
        err = "写请求失败(worker 已死)";
        return -1;
    }
    /* 带超时地读首行 */
    int tmo_used = 0;
    for (;;) {
        struct pollfd p = { g_w.out_fd, POLLIN, 0 };
        int pr = poll(&p, 1, 200);
        if (pr > 0) break;
        if (pr < 0 && errno != EINTR) { err = "poll 失败"; return -1; }
        tmo_used += 200;
        if (g_worker_timeout_ms > 0 && tmo_used >= g_worker_timeout_ms) {
            worker_kill_locked("响应超时(库可能挂死)");
            err = "worker 响应超时（已击杀）";
            return -2;
        }
    }
    std::string first;
    if (pipe_read_line(g_w.out_fd, first)) { err = "读响应首行失败(worker 已死)"; return -1; }
    int st = 0; size_t hl = 0, pln = 0;
    if (sscanf(first.c_str(), "NPU1 %d %zu %zu", &st, &hl, &pln) != 3) { err = "worker 响应格式错"; return -1; }
    if (hl > 8192 || pln > g_max_payload) { err = "worker 响应过大"; return -1; }
    std::string htxt(hl, 0);
    if (hl && read_all(g_w.out_fd, &htxt[0], hl)) { err = "读响应头失败"; return -1; }
    pl.assign(pln, 0);
    if (pln && read_all(g_w.out_fd, pl.data(), pln)) { err = "读响应载荷失败"; return -1; }
    auto hm = parse_hdr(htxt);
    for (auto &kv : hm) rh.push_back(kv);
    g_w.last_use = now_ms();
    if (st != 0) { err = hm.count("MSG") ? hm["MSG"] : ("worker status=" + std::to_string(st)); return st; }
    return 0;
}

/* ---------------- 作业执行（= 转发给 worker，含一次重试） ---------------- */
static void run_job(std::shared_ptr<Job> j)
{
    uint64_t t0 = now_ms();
    if (j->timeout_ms > 0 && t0 - j->enq > (uint64_t)j->timeout_ms) {
        j->status = 4;
        j->msg = "timeout in queue";
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            g_n_timeout++;
        }
        return;
    }
    std::lock_guard<std::mutex> lk(g_w_mtx);
    if (worker_ensure_locked(j->model)) {
        j->status = 13;
        j->msg = "worker 启动失败";
        return;
    }
    std::string err;
    std::vector<std::pair<std::string, std::string> > rh;
    std::vector<unsigned char> pl;
    int r = worker_call_locked(*j, rh, pl, err);
    if (r == -1) {
        /* worker 中途死掉：清状态、重启一次、重试一回合（LOAD/INFER 都安全） */
        logf("[worker] 调用失败(%s) ⇒ 重启并重试一次", err.c_str());
        worker_stop_locked();
        if (!worker_ensure_locked(j->model)) {
            rh.clear(); pl.clear();
            r = worker_call_locked(*j, rh, pl, err);
        }
    }
    if (r != 0) {
        j->status = (r == -2) ? 14 : (r > 0 ? 11 : 12);
        j->msg = err.empty() ? "worker 调用失败" : err;
        logf("[req#%llu] %s %s 失败: status=%d %s", (unsigned long long)j->seq,
             j->op.c_str(), j->model.c_str(), j->status, j->msg.c_str());
        return;
    }
    j->rh = rh;
    j->payload = pl;
    j->status = 0;
    {
        std::lock_guard<std::mutex> lg(g_mtx);
        g_runs[j->model]++;
    }
    logf("[req#%llu] %s %s ok: 载荷 %zu B, 耗时 %llu ms (worker pid=%d)",
         (unsigned long long)j->seq, j->op.c_str(), j->model.c_str(), j->payload.size(),
         (unsigned long long)(now_ms() - t0), (int)g_w.pid);
}

/* ---------------- 工作线程（唯一执行者） ---------------- */
static void worker_loop()
{
    for (;;) {
        std::shared_ptr<Job> j;
        {
            std::unique_lock<std::mutex> lk(g_mtx);
            g_cv_q.wait(lk, [] {
                return g_stop || !g_q[0].empty() || !g_q[1].empty() || !g_q[2].empty();
            });
            for (int p = 0; p < 3; p++)
                if (!g_q[p].empty()) { j = g_q[p].front(); g_q[p].pop_front(); break; }
            if (!j && g_stop) break;
        }
        if (!j) continue;
        run_job(j);
        {
            std::lock_guard<std::mutex> lk(j->m);
            j->done = true;
        }
        j->cv.notify_all();
    }
    std::lock_guard<std::mutex> lk(g_w_mtx);
    worker_stop_locked();
    logf("工作线程退出");
}

/* ---------------- 空闲回收（可选，把设备让给别人） ---------------- */
static void reaper_loop()
{
    if (g_idle_kill_ms <= 0) return;
    for (;;) {
        usleep(500000);
        if (g_stop) return;
        std::lock_guard<std::mutex> lk(g_w_mtx);
        if (g_w.pid > 0 && now_ms() - g_w.last_use > (uint64_t)g_idle_kill_ms) {
            logf("[worker] 空闲 %dms ⇒ 回收（设备让出）", g_idle_kill_ms);
            worker_stop_locked();
            g_n_reap++;
        }
    }
}

/* ---------------- 客户端连接 ---------------- */
static void handle_conn(int fd)
{
    for (;;) {
        std::string first;
        if (read_line(fd, first) < 0) return;
        char magic[16], op[16];
        size_t hl = 0, pl = 0;
        if (sscanf(first.c_str(), "%15s %15s %zu %zu", magic, op, &hl, &pl) != 4 || strcmp(magic, "NPU1")) {
            send_resp(fd, 2, {{"MSG", "bad header"}}, {});
            return;
        }
        if (pl > g_max_payload || hl > 8192) {
            send_resp(fd, 2, {{"MSG", "too large"}}, {});
            return;
        }
        std::string hdr(hl, 0);
        if (hl && read_all(fd, &hdr[0], hl)) return;
        std::vector<unsigned char> payload(pl);
        if (pl && read_all(fd, payload.data(), pl)) return;
        auto hm = parse_hdr(hdr);

        if (!strcmp(op, "STATUS")) {
            std::lock_guard<std::mutex> lk(g_mtx);
            std::vector<std::pair<std::string, std::string> > rh;
            std::string ms;
            for (auto &kv : g_runs) ms += kv.first + ":" + std::to_string(kv.second) + " ";
            rh.push_back({"MODE", "pool"});
            rh.push_back({"MODELS", ms.empty() ? "-" : ms});
            rh.push_back({"WORKER_PID", std::to_string((int)g_w.pid)});
            rh.push_back({"WORKER_MODEL", g_w.model.empty() ? "-" : g_w.model});
            rh.push_back({"Q0", std::to_string(g_q[0].size())});
            rh.push_back({"Q1", std::to_string(g_q[1].size())});
            rh.push_back({"Q2", std::to_string(g_q[2].size())});
            rh.push_back({"REQS", std::to_string(g_n_req)});
            rh.push_back({"ERRS", std::to_string(g_n_err)});
            rh.push_back({"TIMEOUTS", std::to_string(g_n_timeout)});
            rh.push_back({"WORKER_TIMEOUTS", std::to_string(g_n_wto)});
            rh.push_back({"SWITCHES", std::to_string(g_n_switch)});
            rh.push_back({"UPTIME_MS", std::to_string(now_ms() - g_t0)});
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
        if (j->timeout_ms <= 0) j->timeout_ms = g_default_timeout_ms;
        if (j->prio < 0 || j->prio > 2) j->prio = 1;
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
            j->seq = ++g_seq;
            j->enq = now_ms();   /* ★真实入队时刻：队列超时判断必须用时间戳，不能用序号 */
            g_n_req++;
            g_q[j->prio].push_back(j);
        }
        g_cv_q.notify_one();
        {
            std::unique_lock<std::mutex> lk(j->m);
            j->cv.wait(lk, [&] { return j->done; });
        }
        if (j->status != 0) {
            std::lock_guard<std::mutex> lk(g_mtx);
            g_n_err++;
        }
        send_resp(fd, j->status, j->rh, j->payload);
    }
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sock") && i + 1 < argc) g_sock = argv[++i];
        else if (!strcmp(argv[i], "--models") && i + 1 < argc) g_model_dir = argv[++i];
        else if (!strcmp(argv[i], "--worker") && i + 1 < argc) g_worker_bin = argv[++i];
        else if (!strcmp(argv[i], "--worker-log") && i + 1 < argc) g_worker_log = argv[++i];
        else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) g_default_timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--worker-timeout-ms") && i + 1 < argc) g_worker_timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--queue") && i + 1 < argc) g_queue_cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--idle-kill-ms") && i + 1 < argc) g_idle_kill_ms = atoi(argv[++i]);
        else {
            fprintf(stderr, "用法: %s [--sock PATH] [--models DIR] [--worker BIN] [--timeout-ms N]\n"
                            "          [--worker-timeout-ms N] [--queue N] [--idle-kill-ms N]\n", argv[0]);
            return 1;
        }
    }
    if (!g_model_dir.empty() && g_model_dir[g_model_dir.size() - 1] != '/') g_model_dir += "/";
    signal(SIGPIPE, SIG_IGN);
    /* ⚠️ 不要设 SIGCHLD=SIG_IGN：worker 由我们显式 waitpid 回收；
     * 若内核自动收尸，waitpid 会立刻返回 ECHILD ⇒ 我们会误判"worker 已停"，
     * 于是新旧 worker 可能同时存活并争抢设备。 */
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
    ::chmod(g_sock.c_str(), 0666);
    logf("npusvc_pool 启动: sock=%s models=%s worker=%s 队列=%d 队列超时=%dms worker超时=%dms 空闲回收=%dms pid=%d",
         g_sock.c_str(), g_model_dir.c_str(), g_worker_bin.c_str(), g_queue_cap,
         g_default_timeout_ms, g_worker_timeout_ms, g_idle_kill_ms, (int)getpid());
    std::thread w(worker_loop);
    std::thread rp(reaper_loop);

    for (;;) {
        int fd = ::accept(srv, nullptr, nullptr);
        if (fd < 0) {
            if (errno == EINTR) continue;
            logf("accept: %s", strerror(errno));
            break;
        }
        std::thread([fd] { handle_conn(fd); ::close(fd); }).detach();
    }
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_stop = true;
    }
    g_cv_q.notify_all();
    w.join();
    if (rp.joinable()) rp.join();
    logf("npusvc_pool 退出");
    return 0;
}

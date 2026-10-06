import gdb

# 计数：VhaDnnTask 构造次数 / VhaNotifyImp 构造次数 / Signal 次数 / Wait 次数
# 目的：sensevoice（多段）是否为每段新建任务对象，而主线程只在其中一个上等待
SIG_OFF = 0x165b0
WAIT_ADDR = 0x15c58
SIG_SYM = "npu::VhaNotifyImp::Signal()"
CTOR_SYMS = [
    "_ZN3npu10VhaDnnTaskC1EjPNS_12VhaObserverE",
    "_ZN3npu10VhaDnnTaskC2EjPNS_12VhaObserverE",
    "npu::VhaDnnTask::VhaDnnTask(unsigned int, npu::VhaObserver*)",
]
NOTIFY_SYMS = [
    "_ZN3npu12VhaNotifyImpC1Ev",
    "_ZN3npu12VhaNotifyImpC2Ev",
    "npu::VhaNotifyImp::VhaNotifyImp()",
]
CNT = {"task": 0, "notify": 0, "sig": 0, "wait": 0}
ADDRS = {"task": [], "notify": [], "sig": [], "wait": []}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


def mk(key, reg="x0", cap=20):
    class B(gdb.Breakpoint):
        def stop(self):
            CNT[key] += 1
            try:
                v = int(gdb.parse_and_eval("$" + reg)) & 0xffffffffffffffff
                if len(ADDRS[key]) < cap:
                    ADDRS[key].append(v)
            except Exception:
                pass
            return False
    return B


def _bye(ev):
    print("[%.3f] [SUM] task_ctor=%d notify_ctor=%d signal=%d wait=%d"
          % (up(), CNT["task"], CNT["notify"], CNT["sig"], CNT["wait"]))
    for k in ("task", "notify", "sig", "wait"):
        print("[SUM] %s 前几个 this = %s" % (k, [hex(a) for a in ADDRS[k][:8]]))


base = None
try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % SIG_SYM)) - SIG_OFF
    print("[SETUP] base=%#x" % base)
    mk("sig")("*%d" % (base + SIG_OFF))
    mk("wait")("*%d" % (base + WAIT_ADDR - 0x165b0 + SIG_OFF))
except Exception as e:
    print("[SETUP] sig/wait 失败: %s" % e)

for s in CTOR_SYMS:
    try:
        a = int(gdb.parse_and_eval("(void*)'%s'" % s))
        mk("task")("*%d" % a)
        print("[SETUP] task ctor %s @%#x" % (s, a))
        break
    except Exception:
        continue
for s in NOTIFY_SYMS:
    try:
        a = int(gdb.parse_and_eval("(void*)'%s'" % s))
        mk("notify")("*%d" % a)
        print("[SETUP] notify ctor %s @%#x" % (s, a))
        break
    except Exception:
        continue

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] end: %s" % e)

import gdb

# ★决定性探针：SetNotifier 是否被调用、给哪个任务、传的是哪个 notifier
#   SetNotifier  @0x32500   (x0=this task, x1=VhaNotifyImp*)
#   GetNotifier  @0x32580   (x0=this task, 返回值=x0)
SETNOTIFY = 0x32500
GETNOTIFY = 0x32580
CTOR = 0x331a8
WAIT = 0x15c58
SIG = 0x16568
CNT = {"ctor": 0, "set": 0, "get": 0, "wait": 0, "sig": 0}
LOG = {"set": [], "wait": [], "sig": []}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


def mk(key, fn=None):
    class B(gdb.Breakpoint):
        def stop(self):
            CNT[key] += 1
            try:
                if fn:
                    fn()
            except Exception as e:
                print("[%.3f] %s err %s" % (up(), key, e))
            return False
    return B


def log_set():
    t = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
    n = int(gdb.parse_and_eval("$x1")) & 0xffffffffffffffff
    if len(LOG["set"]) < 24:
        LOG["set"].append((t, n))
        print("[%.3f] ★SetNotifier #%d task=%#x notifier=%#x" % (up(), CNT["set"], t, n))


def log_sig():
    t = int(gdb.parse_and_eval("$x19")) & 0xffffffffffffffff
    if len(LOG["sig"]) < 24:
        LOG["sig"].append(t)
        print("[%.3f]   Signal notifier=%#x" % (up(), t))


def log_wait():
    t = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
    if len(LOG["wait"]) < 24:
        LOG["wait"].append(t)
        print("[%.3f]   Wait  notifier=%#x" % (up(), t))


def _bye(ev):
    print("[%.3f] [SUM] ctor=%d SetNotifier=%d GetNotifier=%d Wait=%d Signal=%d"
          % (up(), CNT["ctor"], CNT["set"], CNT["get"], CNT["wait"], CNT["sig"]))
    print("[SUM] SetNotifier pairs: %s" % [(hex(a), hex(b)) for a, b in LOG["set"][:8]])
    print("[SUM] Wait   objects  : %s" % [hex(a) for a in LOG["wait"][:8]])
    print("[SUM] Signal objects  : %s" % [hex(a) for a in LOG["sig"][:8]])


base = None
try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - 0x32430
    print("[SETUP] base=%#x" % base)
    mk("ctor")("*%d" % (base + CTOR))
    mk("set", log_set)("*%d" % (base + SETNOTIFY))
    mk("get")("*%d" % (base + GETNOTIFY))
    mk("wait", log_wait)("*%d" % (base + WAIT))
    mk("sig", log_sig)("*%d" % (base + SIG + 0x48))   # 0x165b0 = Signal 内形成 condvar 处
    print("[SETUP] 5 个断点已挂")
except Exception as e:
    print("[SETUP] FAILED: %s" % e)

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] end: %s" % e)

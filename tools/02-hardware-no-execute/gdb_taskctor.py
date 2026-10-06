import gdb

# 抓 VhaDnnTask 构造：打印 id(w0) 与调用栈（前几次）⇒ 找出"谁在按段新建任务"
CTOR_CANDS = [
    "npu::VhaDnnTask::VhaDnnTask(unsigned int, npu::VhaObserver*)",
    "_ZN3npu10VhaDnnTaskC1EjPNS_12VhaObserverE",
    "_ZN3npu10VhaDnnTaskC2EjPNS_12VhaObserverE",
]
EXEC_OFFS = {}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class CtorBP(gdb.Breakpoint):
    def stop(self):
        CtorBP.n += 1
        if CtorBP.n <= 6:
            try:
                tid = int(gdb.parse_and_eval("$w0")) & 0xffffffff
                ob = int(gdb.parse_and_eval("$x1")) & 0xffffffffffffffff
                print("[%.3f] ★VhaDnnTask ctor #%d  id=%d  observer=%#x"
                      % (up(), CtorBP.n, tid, ob))
                gdb.execute("bt 8")
            except Exception as e:
                print("[%.3f] err %s" % (up(), e))
        return False


CtorBP.n = 0


def _bye(ev):
    print("[%.3f] [SUM] VhaDnnTask 构造总次数=%d" % (up(), CtorBP.n))


ok = False
for s in CTOR_CANDS:
    try:
        a = int(gdb.parse_and_eval("(void*)'%s'" % s))
        CtorBP("*%d" % a)
        print("[SETUP] ctor %s @%#x" % (s, a))
        ok = True
        break
    except Exception:
        continue
if not ok:
    print("[SETUP] ctor 符号未找到")

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] end: %s" % e)

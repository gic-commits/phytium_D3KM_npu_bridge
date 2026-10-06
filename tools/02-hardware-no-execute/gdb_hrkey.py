import gdb

# ★测库为每个等待登记的"期望键"：VhaObserver::HandleResponse(task, slot, cb, flag)
#   记录每次调用的 slot(w1) 与 notifier，看清"5 个任务各等什么键"
HR_OFF = 0x356c0          # VhaObserver::HandleResponse（第八轮实测）
NEXTSEG_OFF = 0x32430
SIG = 0x16568
CNT = {"hr": 0, "wait": 0, "sig": 0}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class HRBP(gdb.Breakpoint):
    def stop(self):
        CNT["hr"] += 1
        try:
            x1 = int(gdb.parse_and_eval("$x1")) & 0xffffffffffffffff
            w2 = int(gdb.parse_and_eval("$w2")) & 0xffffffff
            w3 = int(gdb.parse_and_eval("$w3")) & 0xffffffff
            print("[%.3f] ★HandleResponse #%d  x1(slot/key)=%d (0x%x)  w2=%d w3=%d"
                  % (up(), CNT["hr"], x1, x1, w2, w3))
        except Exception as e:
            print("[%.3f] hr err %s" % (up(), e))
        return False


class WaitBP(gdb.Breakpoint):
    def stop(self):
        CNT["wait"] += 1
        try:
            t = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
            print("[%.3f]   Wait on notifier=%#x" % (up(), t))
        except Exception:
            pass
        return False


class SigBP(gdb.Breakpoint):
    def stop(self):
        CNT["sig"] += 1
        try:
            t = int(gdb.parse_and_eval("$x19")) & 0xffffffffffffffff
            print("[%.3f]   Signal notifier=%#x" % (up(), t))
        except Exception:
            pass
        return False


def _bye(ev):
    print("[%.3f] [SUM] HandleResponse=%d Wait=%d Signal=%d"
          % (up(), CNT["hr"], CNT["wait"], CNT["sig"]))


base = None
try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] base=%#x" % base)
    HRBP("*%d" % (base + HR_OFF))
    WaitBP("*%d" % (base + 0x15c58))
    SigBP("*%d" % (base + SIG + 0x48))
    print("[SETUP] 3 个断点已挂")
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

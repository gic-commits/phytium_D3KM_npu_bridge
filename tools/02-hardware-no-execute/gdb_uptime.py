import gdb
import time

# 用 /proc/uptime 打时间戳 —— 与内核 dmesg 的 [ 9730.615961] 同一时基，可直接对齐
def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


def ts():
    return "%.3f" % up()


CNT = {"slot": 0, "hr": 0, "seg": 0, "wait": 0}


class SlotBP(gdb.Breakpoint):
    def stop(self):
        CNT["slot"] += 1
        try:
            this = int(gdb.parse_and_eval("$x0"))
            val = int(gdb.parse_and_eval("*(unsigned int*)(%d + 4)" % this))
            print("UPTIME %s SLOT#%d task->slot=%d" % (ts(), CNT["slot"], val))
        except Exception as e:
            print("UPTIME %s SLOT err %s" % (ts(), e))
        return False


class HRBP(gdb.Breakpoint):
    def stop(self):
        CNT["hr"] += 1
        try:
            wid = int(gdb.parse_and_eval("$w1")) & 0xffffffff
            print("UPTIME %s ★HR#%d 登记等待 slot=%d" % (ts(), CNT["hr"], wid))
        except Exception:
            print("UPTIME %s ★HR#%d" % (ts(), CNT["hr"]))
        return False


class SegBP(gdb.Breakpoint):
    def stop(self):
        CNT["seg"] += 1
        print("UPTIME %s SEG#%d NextSegment" % (ts(), CNT["seg"]))
        return False


class WFCBP(gdb.Breakpoint):
    def stop(self):
        CNT["wait"] += 1
        print("UPTIME %s WAIT#%d WaitForCompletion" % (ts(), CNT["wait"]))
        return False


def _bye(ev):
    print("UPTIME %s [SUM] Slot=%d HR=%d Seg=%d Wait=%d" %
          (ts(), CNT["slot"], CNT["hr"], CNT["seg"], CNT["wait"]))


for spec, cls in (
    ("npu::VhaDnnTask::GetSlot() const", SlotBP),
    ("npu::VhaObserver::HandleResponse(int, std::function<void (void*)>, int)", HRBP),
    ("npu::VhaDnnTask::NextSegment()", SegBP),
    ("npu::VhaNotifyImp::WaitForCompletion(int)", WFCBP),
):
    try:
        cls(spec)
        print("[SETUP] OK %s" % spec[:50])
    except Exception as e:
        print("[SETUP] FAILED %s -> %s" % (spec[:40], e))

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] continue end: %s" % e)

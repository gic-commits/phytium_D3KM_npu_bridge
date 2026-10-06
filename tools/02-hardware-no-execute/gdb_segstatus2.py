import gdb

# 断在 0x1d414（`ldrh w0,[x0,#2]` 的下一条），此时 $w0 已是段状态值
NEXTSEG_OFF = 0x32430
BP_OFF = 0x1d414

CNT = {"st": 0, "vals": {}}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class SegStatusBP(gdb.Breakpoint):
    def stop(self):
        CNT["st"] += 1
        try:
            v = int(gdb.parse_and_eval("$w0")) & 0xffff
            CNT["vals"][v] = CNT["vals"].get(v, 0) + 1
            if CNT["st"] <= 30:
                print("[%.3f] 段状态#%d = %d %s" %
                      (up(), CNT["st"], v,
                       "★已完成(1/4)" if v in (1, 4) else "未完成"))
        except Exception as e:
            print("[%.3f] err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] 读取次数=%d 取值分布=%s" %
          (up(), CNT["st"], CNT["vals"]))


try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] base=%#x 断点=%#x" % (base, base + BP_OFF))
    SegStatusBP("*%d" % (base + BP_OFF))
    print("[SETUP] 已挂")
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

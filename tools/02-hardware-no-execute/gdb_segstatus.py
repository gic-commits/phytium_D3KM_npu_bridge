import gdb

# 断在库读"段状态字段"的地方，打印它看到的状态值
#   base + 0x1d410:  ldrh w0, [x0, #2]   ← 段状态（1 或 4 = 已完成）
NEXTSEG_OFF = 0x32430
HYBRID_OFF = 0x1d410

CNT = {"st": 0}


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
            # 该指令执行后 w0 才是读到的值；用 si 单步读
            gdb.execute("stepi", to_string=True)
            v = int(gdb.parse_and_eval("$w0")) & 0xffff
            ok = "★已完成(1/4)" if v in (1, 4) else "未完成"
            if CNT["st"] <= 40:
                print("[%.3f] 段状态#%d = %d  %s" % (up(), CNT["st"], v, ok))
        except Exception as e:
            print("[%.3f] seg err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] 段状态读取次数=%d" % (up(), CNT["st"]))


try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] base=%#x  断点=%#x" % (base, base + HYBRID_OFF))
    SegStatusBP("*%d" % (base + HYBRID_OFF))
    print("[SETUP] 断点已挂")
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
    print("[RUN] continue 结束: %s" % e)

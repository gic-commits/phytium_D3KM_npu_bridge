import gdb

# 在 0x1d414 断点：打印对象指针 $x0，并 dump 其周边 u16（找段状态字段落在哪块内存）
NEXTSEG_OFF = 0x32430
BP_OFF = 0x1d414
CNT = {"n": 0}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class B(gdb.Breakpoint):
    def stop(self):
        CNT["n"] += 1
        if CNT["n"] > 12:
            return False
        try:
            st = int(gdb.parse_and_eval("$w0")) & 0xffff
            ptr = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
            # 读该指针处的 8 个 u16
            vals = []
            for i in range(0, 8):
                try:
                    v = int(gdb.parse_and_eval("*(unsigned short*)(%d)" % (ptr + i * 2))) & 0xffff
                    vals.append(v)
                except Exception:
                    vals.append(-1)
            print("[%.3f] #%d 状态=%d  对象指针=%#x  u16[0..7]=%s" %
                  (up(), CNT["n"], st, ptr, vals))
        except Exception as e:
            print("[%.3f] err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] 命中=%d" % (up(), CNT["n"]))


try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] base=%#x 断点=%#x" % (base, base + BP_OFF))
    B("*%d" % (base + BP_OFF))
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

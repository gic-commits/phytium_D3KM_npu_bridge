import gdb

# 决定性验证：把库读到的"段状态=3"直接改成 1（模拟本应发生的写入），看库是否前进
NEXTSEG_OFF = 0x32430
BP_OFF = 0x1d408
CNT = {"n": 0, "fixed": 0}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class SegBP(gdb.Breakpoint):
    def stop(self):
        CNT["n"] += 1
        try:
            x0 = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
            inner = int(gdb.parse_and_eval("*(unsigned long*)%d" % x0)) & 0xffffffffffffffff
            st = int(gdb.parse_and_eval("*(unsigned short*)(%d+2)" % inner)) & 0xffff
            if st not in (1, 4):
                # ★ 强制写成 1（"已完成"）
                gdb.execute("set *(unsigned short*)(%d+2) = 1" % inner, to_string=True)
                after = int(gdb.parse_and_eval("*(unsigned short*)(%d+2)" % inner)) & 0xffff
                CNT["fixed"] += 1
                print("[%.3f] #%d ★把段状态 %d -> %d (inner=%#x)" %
                      (up(), CNT["n"], st, after, inner))
            else:
                print("[%.3f] #%d 段状态=%d（已合规，不动）" % (up(), CNT["n"], st))
        except Exception as e:
            print("[%.3f] err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] 段命中=%d 强制修正=%d" % (up(), CNT["n"], CNT["fixed"]))


try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] 断点=%#x" % (base + BP_OFF))
    SegBP("*%d" % (base + BP_OFF))
    print("[SETUP] 已挂（会自动把非 1/4 的段状态改成 1）")
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

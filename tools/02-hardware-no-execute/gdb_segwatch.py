import gdb

# 两步走：
#  1) 在 0x1d408 处抓段指针，算出 inner 对象
#  2) 对 inner+2（段状态字段）设**写断点** ⇒ 抓到"谁把它写成 3"，并打印调用栈
NEXTSEG_OFF = 0x32430
BP_OFF = 0x1d408
CNT = {"n": 0, "wp": 0}
WP_DONE = {"set": False}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class WatchBP(gdb.Breakpoint):
    """段状态字段的写断点"""
    def stop(self):
        CNT["wp"] += 1
        print("[%.3f] ★★★ 段状态被写入！(第 %d 次)" % (up(), CNT["wp"]))
        try:
            old = int(gdb.parse_and_eval("$old")) if False else -1
        except Exception:
            pass
        try:
            gdb.execute("bt 12")
        except Exception as e:
            print("bt err", e)
        return False


class SegBP(gdb.Breakpoint):
    def stop(self):
        CNT["n"] += 1
        if CNT["n"] > 3 or WP_DONE["set"]:
            return False
        try:
            x0 = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
            inner = int(gdb.parse_and_eval("*(unsigned long*)%d" % x0)) & 0xffffffffffffffff
            st = int(gdb.parse_and_eval("*(unsigned short*)(%d+2)" % inner)) & 0xffff
            print("[%.3f] #%d 段指针=%#x inner=%#x 当前状态=%d" %
                  (up(), CNT["n"], x0, inner, st))
            if CNT["n"] == 2:      # 第 2 个段就是状态=3 的那个
                try:
                    WatchBP("*(unsigned short*)(%d+2)" % inner, gdb.BP_WATCHPOINT)
                    WP_DONE["set"] = True
                    print("[SETUP] ★已在 inner+2 (%#x) 挂写断点" % (inner + 2))
                except Exception as e:
                    print("[SETUP] watch 失败: %s" % e)
        except Exception as e:
            print("[%.3f] err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] 段命中=%d 状态写命中=%d" % (up(), CNT["n"], CNT["wp"]))


try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] 断点=%#x" % (base + BP_OFF))
    SegBP("*%d" % (base + BP_OFF))
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

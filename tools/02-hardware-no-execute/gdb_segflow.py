import gdb

# 段状态机走向探针：4 个关键点计数 + 最后一次命中的调用栈
#   0x1d3f8  段循环入口（NextSegment 调用）
#   0x1d424  段状态 ∈{1,4} 成立（已完成分支）
#   0x1d43c  GetSubmitKey（未完成 ⇒ 去提交）
#   0x1dfb8  段倒计数（b.ne 回循环）
#   0x1dfcc  Done::~Done() ⇒ Signal（收尾，成功唤醒）
#   0x1f394  段取完的出口（cbz x0）
NEXTSEG_OFF = 0x32430
PTS = {
    0x1d3f8: "loop_in",
    0x1d424: "done_branch",
    0x1d43c: "submit_path",
    0x1dfb8: "countdown",
    0x1dfcc: "signal_tail",
    0x1f394: "seg_exhausted",
}
CNT = {v: 0 for v in PTS.values()}
FIRST = {}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


def mk(name):
    class B(gdb.Breakpoint):
        def stop(self):
            CNT[name] += 1
            if CNT[name] == 1:
                FIRST[name] = up()
                print("[%.3f] ★首次命中 %s (#%d)" % (up(), name, CNT[name]))
                if name in ("signal_tail", "seg_exhausted"):
                    try:
                        gdb.execute("bt 6")
                    except Exception:
                        pass
            return False
    return B


def _bye(ev):
    print("[%.3f] [SUM] %s" % (up(), CNT))
    print("[SUM] 首次命中时间 %s" % FIRST)


base = None
try:
    base = int(gdb.parse_and_eval("(void*)'npu::VhaDnnTask::NextSegment()'")) - NEXTSEG_OFF
    print("[SETUP] base=%#x" % base)
    for off, nm in PTS.items():
        mk(nm)("*%d" % (base + off))
    print("[SETUP] 6 个断点已挂")
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

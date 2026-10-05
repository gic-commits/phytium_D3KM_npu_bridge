import gdb

# 用符号名断点（不依赖硬编码偏移），抓库为每个 task 分配的 slot
CNT = {"slot": 0, "hr": 0, "seg": 0, "wfc": 0}


class SlotBP(gdb.Breakpoint):
    """npu::VhaDnnTask::GetSlot() const  -> 返回 task->slot (this+4)"""
    def stop(self):
        CNT["slot"] += 1
        try:
            this = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
            val = gdb.parse_and_eval("*(unsigned int*)(%d + 4)" % this)
            print("[SLOT#%d] task->slot = %d" % (CNT["slot"], int(val)))
        except Exception as e:
            print("[SLOT] err", e)
        return False


class HRBP(gdb.Breakpoint):
    """npu::VhaObserver::HandleResponse(int, std::function<void(void*)>, int)"""
    def stop(self):
        CNT["hr"] += 1
        try:
            wid = int(gdb.parse_and_eval("$w1")) & 0xffffffff
            to = int(gdb.parse_and_eval("$w3")) & 0xffffffff
            print("[HR#%d] 库注册等待 slot/id=%d timeout=%d" % (CNT["hr"], wid, to))
        except Exception:
            pass
        return False


class SegBP(gdb.Breakpoint):
    """npu::VhaDnnTask::NextSegment()"""
    def stop(self):
        CNT["seg"] += 1
        if CNT["seg"] <= 12:
            print("[SEG#%d] NextSegment 被调用" % CNT["seg"])
        return False


def _bye(ev):
    print("[SUM] GetSlot=%d HandleResponse=%d NextSegment=%d" %
          (CNT["slot"], CNT["hr"], CNT["seg"]))


for spec, cls in (("npu::VhaDnnTask::GetSlot() const", SlotBP),
                  ("npu::VhaObserver::HandleResponse(int, std::function<void (void*)>, int)", HRBP),
                  ("npu::VhaDnnTask::NextSegment()", SegBP)):
    try:
        cls(spec)
        print("[SETUP] 断点 OK: %s" % spec[:52])
    except Exception as e:
        print("[SETUP] FAILED %s -> %s" % (spec[:40], e))

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

# ★ 关键：batch 模式必须有 continue，否则脚本跑完 gdb 立刻 detach，断点从未生效
gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] continue 结束:", e)

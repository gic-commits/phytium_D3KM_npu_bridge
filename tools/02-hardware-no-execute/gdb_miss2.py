import gdb

MSYM = "_ZNSt6thread11_State_implINS_8_InvokerISt5tupleIJZN3npu11VhaObserverC4EP3VhaSt8functionIFvNS4_9EventTypeERiEEEUlvE_EEEEE6_M_runEv"
RECV_OFF = 0x36420

MISS_OFF = 0x36700      # bl ReleaseVhaResponse —— 只有未命中才走到
KEY_OFF = 0x364d4
HRCALL_OFF = 0x1e074
GETSLOT_OFF = 0x32300

CNT = {"miss": 0, "key": 0, "hr": 0, "slot": 0}

class MissBP(gdb.Breakpoint):
    def stop(self):
        CNT["miss"] += 1
        try:
            print("[MISS#%d] ★ 响应被丢弃（map 里没有该 slot 条目）" % CNT["miss"])
        except Exception:
            pass
        return False

class KeyBP(gdb.Breakpoint):
    def stop(self):
        CNT["key"] += 1
        try:
            v = int(gdb.parse_and_eval("$w0")) & 0xffffffff
            print("[KEY#%d]=%d" % (CNT["key"], v))
        except Exception:
            pass
        return False

class HRBP(gdb.Breakpoint):
    def stop(self):
        CNT["hr"] += 1
        try:
            print("[HR#%d] 等 slot=%d" % (CNT["hr"], int(gdb.parse_and_eval("$w1")) & 0xffffffff))
        except Exception:
            pass
        return False

class SlotBP(gdb.Breakpoint):
    def stop(self):
        CNT["slot"] += 1
        try:
            v = int(gdb.parse_and_eval("*(unsigned int*)($x0+4)"))
            print("[GetSlot#%d]=%d" % (CNT["slot"], v))
        except Exception:
            pass
        return False

def _bye(ev):
    print("[SUM] 丢弃=%d 解出key=%d HR=%d GetSlot=%d" % (CNT["miss"], CNT["key"], CNT["hr"], CNT["slot"]))

try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % MSYM)) - RECV_OFF
    print("[SETUP] base=%#x" % base)
    MissBP("*%d" % (base + MISS_OFF))
    KeyBP("*%d" % (base + KEY_OFF))
    HRBP("*%d" % (base + HRCALL_OFF))
    SlotBP("*%d" % (base + GETSLOT_OFF))
    print("[SETUP] 断点已挂")
except Exception as e:
    print("[SETUP] FAILED:", e)

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

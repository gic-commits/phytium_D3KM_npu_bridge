import gdb

MSYM = "_ZNSt6thread11_State_implINS_8_InvokerISt5tupleIJZN3npu11VhaObserverC4EP3VhaSt8functionIFvNS4_9EventTypeERiEEEUlvE_EEEEE6_M_runEv"
RECV_OFF = 0x36420
W20_OFF = 0x1d3f0      # str w20, [sp, #144]  —— 段数（库期待的完成次数）
UPD_OFF = 0x1dfc0      # Update(this, 1) —— 完成置位

CNT = {"w": 0, "u": 0}

class W20BP(gdb.Breakpoint):
    def stop(self):
        CNT["w"] += 1
        try:
            v = int(gdb.parse_and_eval("$w20")) & 0xffffffff
            print("[W20] 段数/期待完成次数 = %d  (第 %d 次)" % (v, CNT["w"]))
        except Exception as e:
            print("[W20] err", e)
        return False

class UpdBP(gdb.Breakpoint):
    def stop(self):
        CNT["u"] += 1
        try:
            w1 = int(gdb.parse_and_eval("$w1")) & 0xffffffff
            print("[UPD] Update(status=%d) 第 %d 次" % (w1, CNT["u"]))
        except Exception as e:
            print("[UPD] err", e)
        return False

def _bye(ev):
    print("[SUM] W20=%d  Update=%d" % (CNT["w"], CNT["u"]))

try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % MSYM)) - RECV_OFF
    print("[SETUP] base=%#x  W20=%#x  UPD=%#x" % (base, base + W20_OFF, base + UPD_OFF))
    W20BP("*%d" % (base + W20_OFF))
    UpdBP("*%d" % (base + UPD_OFF))
    print("[SETUP] 断点已挂")
except Exception as e:
    print("[SETUP] FAILED:", e)

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

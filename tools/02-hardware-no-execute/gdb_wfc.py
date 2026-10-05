import gdb

MSYM = "_ZNSt6thread11_State_implINS_8_InvokerISt5tupleIJZN3npu11VhaObserverC4EP3VhaSt8functionIFvNS4_9EventTypeERiEEEUlvE_EEEEE6_M_runEv"
RECV_OFF = 0x36420

WFC_OFF = 0x15c58          # WaitForCompletion 入口
WFC_RET_OFF = 0x15d4c      # 主返回路径：mov w0, w19
UPD1_OFF = 0x1dfc0         # Update(status=1)
UPD4_OFF = 0x1ed64         # Update(status=4)
UPD_FN_OFF = 0x16310       # Update 函数入口

CNT = {"wfc": 0, "ret": 0, "u1": 0, "u4": 0}

class WFCBP(gdb.Breakpoint):
    def stop(self):
        CNT["wfc"] += 1
        try:
            t = int(gdb.parse_and_eval("$w1")) & 0xffffffff
            if CNT["wfc"] <= 12:
                print("[WFC] 进入 WaitForCompletion(timeout=%d) 第 %d 次" % (t, CNT["wfc"]))
        except Exception as e:
            print("[WFC] err", e)
        return False

class RetBP(gdb.Breakpoint):
    def stop(self):
        CNT["ret"] += 1
        try:
            v = int(gdb.parse_and_eval("$w19")) & 0xffffffff
            print("[WFC-RET] 返回 status=%d  (第 %d 次)" % (v, CNT["ret"]))
        except Exception as e:
            print("[WFC-RET] err", e)
        return False

class Upd1BP(gdb.Breakpoint):
    def stop(self):
        CNT["u1"] += 1
        return False

class Upd4BP(gdb.Breakpoint):
    def stop(self):
        CNT["u4"] += 1
        print("[UPD4] ★ Update(status=4) 命中 第 %d 次" % CNT["u4"])
        return False

def _bye(ev):
    print("[SUM] WaitForCompletion=%d 返回=%d  Update(1)=%d  Update(4)=%d"
          % (CNT["wfc"], CNT["ret"], CNT["u1"], CNT["u4"]))

try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % MSYM)) - RECV_OFF
    print("[SETUP] base=%#x" % base)
    WFCBP("*%d" % (base + WFC_OFF))
    RetBP("*%d" % (base + WFC_RET_OFF))
    Upd1BP("*%d" % (base + UPD1_OFF))
    Upd4BP("*%d" % (base + UPD4_OFF))
    print("[SETUP] 断点已挂")
except Exception as e:
    print("[SETUP] FAILED:", e)

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

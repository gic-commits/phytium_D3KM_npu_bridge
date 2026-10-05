import gdb

MSYM = "_ZNSt6thread11_State_implINS_8_InvokerISt5tupleIJZN3npu11VhaObserverC4EP3VhaSt8functionIFvNS4_9EventTypeERiEEEUlvE_EEEEE6_M_runEv"
RECV_OFF = 0x36420

GETSLOT_OFF = 0x32300     # VhaDnnTask::GetSlot(): ldr w0,[x0,#4]; ret
HRCALL_OFF = 0x1e074      # bl HandleResponse 前：w1 = 期待的 id
NEXTSEG_OFF = 0x32430
UPD1_OFF = 0x1dfc0
UPD4_OFF = 0x1ed64
KEYRCV_OFF = 0x364d4

CNT = {"slot": 0, "hr": 0, "seg": 0, "u1": 0, "u4": 0, "key": 0}
SLOTS = []
HRS = []

class GetSlotBP(gdb.Breakpoint):
    def stop(self):
        CNT["slot"] += 1
        try:
            # 函数体是 ldr w0,[x0,#4]; ret ⇒ 直接读 this->slot
            v = int(gdb.parse_and_eval("*(unsigned int*)($x0+4)"))
            if len(SLOTS) < 60:
                SLOTS.append(v)
                if CNT["slot"] <= 3 or v != SLOTS[-2] if len(SLOTS) > 1 else True:
                    print("[GetSlot#%d] slot=%d" % (CNT["slot"], v))
        except Exception as e:
            print("[GetSlot] err", e)
        return False

class HRBP(gdb.Breakpoint):
    def stop(self):
        CNT["hr"] += 1
        try:
            wid = int(gdb.parse_and_eval("$w1")) & 0xffffffff
            if len(HRS) < 40:
                HRS.append(wid)
            print("[HR-CALL#%d] ★ 等 slot=%d" % (CNT["hr"], wid))
        except Exception:
            pass
        return False

class KeyBP(gdb.Breakpoint):
    def stop(self):
        CNT["key"] += 1
        try:
            v = int(gdb.parse_and_eval("$w0")) & 0xffffffff
            print("[KEY#%d] 解出 key=%d" % (CNT["key"], v))
        except Exception:
            pass
        return False

class SegBP(gdb.Breakpoint):
    def stop(self):
        CNT["seg"] += 1
        return False

class U1BP(gdb.Breakpoint):
    def stop(self):
        CNT["u1"] += 1
        return False

class U4BP(gdb.Breakpoint):
    def stop(self):
        CNT["u4"] += 1
        return False

def _bye(ev):
    print("[SUM] GetSlot=%d HR=%d NextSeg=%d U1=%d U4=%d KEY=%d"
          % (CNT["slot"], CNT["hr"], CNT["seg"], CNT["u1"], CNT["u4"], CNT["key"]))
    print("[SUM-SLOTS] %s" % " ".join(str(x) for x in SLOTS))
    print("[SUM-HRS] %s" % " ".join(str(x) for x in HRS))

try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % MSYM)) - RECV_OFF
    print("[SETUP] base=%#x" % base)
    GetSlotBP("*%d" % (base + GETSLOT_OFF))
    HRBP("*%d" % (base + HRCALL_OFF))
    KeyBP("*%d" % (base + KEYRCV_OFF))
    SegBP("*%d" % (base + NEXTSEG_OFF))
    U1BP("*%d" % (base + UPD1_OFF))
    U4BP("*%d" % (base + UPD4_OFF))
    print("[SETUP] 断点已挂")
except Exception as e:
    print("[SETUP] FAILED:", e)

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

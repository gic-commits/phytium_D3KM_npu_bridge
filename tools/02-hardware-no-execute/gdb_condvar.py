import gdb

# 决定性比对：Signal() 通知的 condvar 对象  vs  主线程 WaitForCompletion 等待的对象
#   Signal:            0x165b0: add x0, x19, #0x98   ; x19 = this
#   WaitForCompletion: 取 this（x0），比较是否同一对象
SIGNAL_OFF = 0x165b0
SIG_SYM = "npu::VhaNotifyImp::Signal()"
WAIT_SYMS = [
    "_ZN3npu12VhaNotifyImp17WaitForCompletionEi",
    "npu::VhaNotifyImp::WaitForCompletion(int)",
    "npu::VhaNotifyImp::WaitForCompletion(unsigned int, unsigned int)",
    "npu::VhaNotifyImp::WaitForCompletion(unsigned int)",
    "npu::VhaNotifyImp::WaitForCompletion(unsigned int, unsigned long)",
]
CNT = {"sig": 0, "wait": 0}


def up():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return -1.0


class SigBP(gdb.Breakpoint):
    def stop(self):
        CNT["sig"] += 1
        if CNT["sig"] <= 8:
            try:
                x19 = int(gdb.parse_and_eval("$x19")) & 0xffffffffffffffff
                print("[%.3f] [SIGNAL] #%d this(x19)=%#x  condvar(+0x98)=%#x"
                      % (up(), CNT["sig"], x19, x19 + 0x98))
            except Exception as e:
                print("[%.3f] sig err %s" % (up(), e))
        return False


class WaitBP(gdb.Breakpoint):
    def stop(self):
        CNT["wait"] += 1
        if CNT["wait"] <= 8:
            try:
                x0 = int(gdb.parse_and_eval("$x0")) & 0xffffffffffffffff
                print("[%.3f] [WAIT  ] #%d this(x0)=%#x  condvar(+0x98)=%#x"
                      % (up(), CNT["wait"], x0, x0 + 0x98))
            except Exception as e:
                print("[%.3f] wait err %s" % (up(), e))
        return False


def _bye(ev):
    print("[%.3f] [SUM] SIGNAL=%d WAIT=%d" % (up(), CNT["sig"], CNT["wait"]))


base = None
try:
    base = int(gdb.parse_and_eval("(void*)'%s'" % SIG_SYM)) - SIGNAL_OFF
    print("[SETUP] base=%#x  Signal 断点=%#x" % (base, base + SIGNAL_OFF))
    SigBP("*%d" % (base + SIGNAL_OFF))
except Exception as e:
    print("[SETUP] Signal 断点失败: %s" % e)

for s in WAIT_SYMS:
    try:
        a = int(gdb.parse_and_eval("(void*)'%s'" % s))
        WaitBP("*%d" % a)
        print("[SETUP] Wait 断点 %s @%#x" % (s, a))
        break
    except Exception:
        continue

try:
    gdb.events.exited.connect(_bye)
except Exception:
    pass

gdb.execute("set confirm off")
try:
    gdb.execute("continue")
except Exception as e:
    print("[RUN] end: %s" % e)

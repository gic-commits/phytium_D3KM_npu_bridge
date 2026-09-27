#!/usr/bin/env python3
# regsnap.py — 加速器关键寄存器「一次性快照」（只读 /dev/mem，单进程、每寄存器独立 mmap 一页，安全）
#
# 为什么要它：**事后读寄存器会骗人** —— 跑完再读可能整块全 0（电源态/超时清理后的读数），
# 连常量寄存器都为 0 就说明"这次读数无效"。正确判据来自**运行中轮询**（见 SKILL.md §四）。
# 用法：
#   sudo python3 regsnap.py "标签"            # 快照一次
#   ( ./harness model/x img 640 640 & ); sleep 0.8; sudo python3 regsnap.py "运行中"   # 运行中快照
#
# 本表按飞腾 leopard 偏移表（include/phytium_npu_leopard_reg.h）整理，基址 0x26d00000
# （用 `sudo dmesg | grep registers` 复核基址）。换芯片时整表替换即可。
import mmap, os, struct, sys

BASE = 0x26d00000
OFFS = [
    ("SYS_MMU_STATUS",        0x0A08), ("MDBG_S1",           0x0A10), ("MDBG_S2",          0x0A18),
    ("MDBG_IDLE",             0x0A20), ("MDBG_STATUS3",      0x0A28), ("MDBG_FAULT_STOP",  0x0A30),
    ("MDBG_STATUS_DEBUG",     0x0A38), ("CACHE_CMDREQ_RD",   0x0A60), ("CACHE_CMDBCK_WR",  0x0A68),
    ("CACHE_CMDCRC_WR",       0x0A70), ("CACHE_CMDDBG_WR",   0x0A78), ("CACHE_CMDREQ_FENCE", 0x0B80),
    ("CMDREQ_RD_WORD",        0x0BC0), ("CMDBCK_WR_WORD",    0x0BC8), ("CMDCRC_WR_WORD",   0x0BD0),
    ("CMDDBG_WR_WORD",        0x0BD8), ("SYS_CMDMH_CONTROL", 0x2898), ("SYS_MM_MH_CONTROL", 0x28C8),
    ("SYS_MEM_CTRL",          0xEA80), ("SYS_MEM_FAULT_STOP",0xEAC8), ("SYS_MMU_PSIZE_RONE",0xEBD0),
    ("CH0_WRITEBACK_CONTROL", 0x10800),("VHA_EVENT_ENABLE",  0x10808),("VHA_EVENT_STATUS",  0x10810),
    ("VHA_EVENT_CLEAR",       0x10818),("CH0_CONTROL",       0x10880),("CH0_STATUS",        0x10888),
    ("CH0_CMD_BASE",          0x108A0),("CH0_ADDR_USED",     0x108B8),
    ("ADDR0", 0x108C0), ("ADDR1", 0x108C8), ("ADDR2", 0x108D0), ("ADDR3", 0x108D8),
    ("ADDR4", 0x108E0), ("ADDR5", 0x108E8), ("ADDR6", 0x108F0), ("ADDR7", 0x108F8),
    ("CRC_CONTROL", 0x10980), ("CRC_ADDRESS", 0x10988),
    ("ADDR8",  0x109C0), ("ADDR9",  0x109C8), ("ADDR10", 0x109D0), ("ADDR11", 0x109D8),
    ("ADDR12", 0x109E0), ("ADDR13", 0x109E8), ("ADDR14", 0x109F0), ("ADDR15", 0x109F8),
]

label = sys.argv[1] if len(sys.argv) > 1 else "snap"
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
rows = []
for name, off in OFFS:
    try:
        m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=(BASE + off) & ~0xfff)
        v = struct.unpack_from('<I', m, off & 0xfff)[0]
        m.close()
        rows.append((name, off, v))
    except Exception:
        rows.append((name, off, None))
os.close(fd)

print(f"### {label}")
for name, off, v in rows:
    print(f"{name:22} 0x{off:08x} = " + ("BUS-ERR" if v is None else f"0x{v:08x}"))

# 读法速查（本案例的判据）：
#   CMDREQ_RD_WORD == 命令流总字数   ⇒ 取指通路把整条流走完（≠"引擎没动"）
#   MDBG_IDLE  == 空闲值(0xffff)     ⇒ 引擎已回到 idle
#   MDBG_FAULT_STOP == 0             ⇒ 无 fault-stop
#   上面三条 + 无完成事件            ⇒ 定名"流取完、无 fault、不发完成事件"（战场在事件/同步握手）
#   ⚠️ MDBG_STATUS3 是**活值**（相邻采样会变），别拿它某一位当 sticky error。
#   ⚠️ 若"连常量寄存器都为 0" ⇒ 这次快照无效（电源态/清理后），改用运行中轮询。

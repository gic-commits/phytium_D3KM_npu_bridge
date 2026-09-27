#!/usr/bin/env python3
# regsnap.py — 一次性快照 NPU 关键寄存器（单进程、每寄存器独立 mmap 一页，安全只读）
# 用法: sudo python3 regsnap.py [标签]
import mmap, os, struct, sys
BASE = 0x26d00000
OFFS = [
    ("SYS_MMU_STATUS",        0x0A08), ("MDBG_S1",          0x0A10), ("MDBG_S2",        0x0A18),
    ("MDBG_IDLE",             0x0A20), ("MDBG_STATUS3",     0x0A28), ("MDBG_FAULT_STOP",0x0A30),
    ("MDBG_STATUS_DEBUG",     0x0A38), ("CACHE_CMDREQ_RD",  0x0A60), ("CACHE_CMDBCK_WR",0x0A68),
    ("CACHE_CMDCRC_WR",       0x0A70), ("CACHE_CMDDBG_WR",  0x0A78), ("CACHE_CMDREQ_FENCE",0x0B80),
    ("CMDREQ_RD_WORD",        0x0BC0), ("CMDBCK_WR_WORD",   0x0BC8), ("CMDCRC_WR_WORD", 0x0BD0),
    ("CMDDBG_WR_WORD",        0x0BD8), ("SYS_CMDMH_CONTROL",0x2898), ("SYS_MM_MH_CONTROL",0x28C8),
    ("SYS_MEM_CTRL",          0xEA80), ("SYS_MEM_FAULT_STOP",0xEAC8),("SYS_MMU_PSIZE_RONE",0xEBD0),
    ("CH0_WRITEBACK_CONTROL", 0x10800),("VHA_EVENT_ENABLE", 0x10808),("VHA_EVENT_STATUS",0x10810),
    ("VHA_EVENT_CLEAR",       0x10818),("CH0_CONTROL",      0x10880),("CH0_STATUS",      0x10888),
    ("CH0_CMD_BASE",          0x108A0),("CH0_ADDR_USED",    0x108B8),
    ("ADDR0", 0x108C0), ("ADDR1", 0x108C8), ("ADDR2", 0x108D0), ("ADDR3", 0x108D8),
    ("ADDR4", 0x108E0), ("ADDR5", 0x108E8), ("ADDR6", 0x108F0), ("ADDR7", 0x108F8),
    ("CRC_CONTROL", 0x10980), ("CRC_ADDRESS", 0x10988),
    ("ADDR8", 0x109C0), ("ADDR9", 0x109C8), ("ADDR10", 0x109D0), ("ADDR11", 0x109D8),
    ("ADDR12", 0x109E0), ("ADDR13", 0x109E8), ("ADDR14", 0x109F0), ("ADDR15", 0x109F8),
]
label = sys.argv[1] if len(sys.argv) > 1 else "snap"
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
out = []
for name, off in OFFS:
    try:
        m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=(BASE + off) & ~0xfff)
        v = struct.unpack_from('<I', m, off & 0xfff)[0]
        m.close()
        out.append((name, off, v))
    except Exception as e:
        out.append((name, off, None))
os.close(fd)
print(f"### {label}")
for name, off, v in out:
    print(f"{name:22} 0x{off:08x} = " + ("BUS-ERR" if v is None else f"0x{v:08x}"))

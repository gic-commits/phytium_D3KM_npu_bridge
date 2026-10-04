#!/bin/bash
O=/home/greatwall/step53.txt
{
echo "=== 试不同 VHA_VADDR 组合 ==="
test_env() {
  local desc="$1"; shift
  echo "  --- $desc ---"
  export VHA_VADDR_BASE=$1
  export VHA_VADDR_SIZE=$2
  export VHA_VADDR_OFFS=$3
  export VHA_VADDR_PAGESIZE=$4
  sudo systemctl restart npusvc; sleep 6
  sudo dmesg -C
  cd /opt/npu/python
  NPU_SOCK=/run/npu/npu.sock timeout 300 python3 -c "
import sys; sys.path.insert(0,'/opt/npu/python')
import npu_client as npu
c = npu.connect()
try: print('    load ->', c.load('sensevoice'))
except Exception as e: print('    load 异常:', str(e)[:50])
" 2>&1 | tail -1
  echo "    报错: $(sudo grep -a 'No heap capable\|failed to allocate' /var/log/npuworker.log 2>/dev/null | tail -1 | sed 's/^ *//')"
  echo "    ALLOC: $(sudo dmesg | grep -ac 'alloc size=')"
}

test_env "base=0x48200000 size=0x40000000 offs=0x1000" 0x48200000 0x40000000 0x1000 4096
test_env "base=0x0 size=0x40000000 offs=0" 0x0 0x40000000 0 4096
test_env "base=0x48200000 size=0x10000000 offs=0" 0x48200000 0x10000000 0 4096
test_env "base=0x48200000 size=0x40000000 offs=0" 0x48200000 0x40000000 0 4096
} > $O 2>&1
cat $O

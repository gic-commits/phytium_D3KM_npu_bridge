#!/bin/bash
O=/home/greatwall/step20.txt
{
T=/home/greatwall/npudrv/tree/drivers/staging/phytium-npu
echo "=== 1. struct vha_mem_alloc 的定义 ==="
grep -n -A20 "struct vha_mem_alloc {" $T/include/phytium_npu_uapi.h | head -25 | sed 's/^/  /'
echo
echo "=== 2. 关键：结构体大小 vs ioctl 声明的 size ==="
cat > /tmp/sz.c <<'EOF'
#include <stdio.h>
#include <stdint.h>
struct vha_mem_alloc {
    uint64_t size;
    uint32_t field8;
    uint32_t flags;
    char name[8];
    uint64_t addr;
    uint32_t page_idx;
    uint32_t pad;
};
int main(void){ printf("  sizeof = %zu\n", sizeof(struct vha_mem_alloc)); return 0; }
EOF
gcc -o /tmp/sz /tmp/sz.c 2>/dev/null && /tmp/sz
echo
echo "=== 3. ioctl 实际声明的 size ==="
python3 -c "
print('  VHA_ALLOC_MEM: _IOC(_IOC_READ|_IOC_WRITE, 0x71, 0x2, 0x20)')
print('  => size 字段 = 0x20 = 32 字节')
print()
print('  VHA_MAP_BUF:   _IOC(_IOC_WRITE, 0x71, 0x7, 0x10)')
print('  => size 字段 = 0x10 = 16 字节')
"
echo
echo "=== 4. 关键：驱动里 copy_from_user 用的 sizeof ==="
grep -n "copy_from_user(&req, (void __user \*)arg, sizeof(req))" $T/phytium_npu_uapi.c | head -8 | sed 's/^/  /'
echo
echo "=== 5. 头文件里 struct 的实际定义（完整） ==="
awk '/struct vha_mem_alloc \{/,/^\};/' $T/include/phytium_npu_uapi.h | sed 's/^/  /'
echo
echo "=== 6. 头文件里 struct vha_map_buf ==="
awk '/struct vha_map_buf \{/,/^\};/' $T/include/phytium_npu_uapi.h | sed 's/^/  /'
echo
echo "=== 7. 关键：驱动侧是否有 ioctl 大小校验 ==="
grep -n "_IOC_SIZE\|cmd_size\|WARN.*size" $T/phytium_npu_uapi.c | head -10 | sed 's/^/  /'
} > $O 2>&1
cat $O

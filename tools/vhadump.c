// vhadump.c — 直接从 /dev/npu0 mmap 指定页并 dump（与库取 host 指针同一路径）
// 用法: vhadump <page_no> <bytes> <out.bin>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
    if (argc < 4) { printf("用法: %s <page号> <字节数> <out.bin>\n", argv[0]); return 1; }
    unsigned long page = strtoul(argv[1], NULL, 0);
    size_t bytes = (size_t)strtoul(argv[2], NULL, 0);
    long PS = sysconf(_SC_PAGESIZE);
    size_t maplen = ((bytes + PS - 1) / PS) * PS;

    int fd = open("/dev/npu0", O_RDWR);
    if (fd < 0) { perror("open /dev/npu0"); return 2; }
    void *p = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)page * PS);
    if (p == MAP_FAILED) { perror("mmap"); close(fd); return 3; }

    FILE *f = fopen(argv[3], "wb");
    if (!f) { perror("fopen"); return 4; }
    fwrite(p, 1, bytes, f);
    fclose(f);
    printf("page=%lu bytes=%zu -> %s (前16B: ", page, bytes, argv[3]);
    for (size_t i = 0; i < 16 && i < bytes; i++) printf("%02x ", ((unsigned char *)p)[i]);
    printf(")\n");
    munmap(p, maplen); close(fd);
    return 0;
}

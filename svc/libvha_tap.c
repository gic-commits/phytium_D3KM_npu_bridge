// libvha_tap.c — 用户态 VHA ioctl/read 探针（LD_PRELOAD，零内核风险）
// 用途：抓库 <-> /dev/npu0 的 cmd payload 与响应字节，定位"响应投递错位"
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <stdlib.h>

static int (*real_ioctl)(int, unsigned long, ...);
static ssize_t (*real_read)(int, void *, size_t);
static ssize_t (*real_write)(int, const void *, size_t);
static FILE *lf;
static int inited;

static void ini(void)
{
    const char *p;
    if (inited) return;
    inited = 1;
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_read  = dlsym(RTLD_NEXT, "read");
    real_write = dlsym(RTLD_NEXT, "write");
    p = getenv("VHA_TAP_LOG");
    lf = fopen(p ? p : "/tmp/vha_tap.log", "a");
}

static double ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void dump(const char *tag, int fd, const void *buf, size_t n, long ret)
{
    unsigned char *b = (unsigned char *)buf;
    size_t i, lim = n > 288 ? 288 : n;
    if (!lf) return;
    fprintf(lf, "[%.3f] t=%ld %s fd=%d ret=%ld n=%zu | ", ms(),
            syscall(SYS_gettid), tag, fd, ret, n);
    for (i = 0; i < lim; i++) fprintf(lf, "%02x", b[i]);
    fprintf(lf, "\n");
    fflush(lf);
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap; void *arg; long ret;
    unsigned nr = req & 0xff, sz = (req >> 16) & 0x3fff, type = (req >> 8) & 0xff;
    ini();
    va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);
    ret = real_ioctl(fd, req, arg);
    if (lf && fd >= 3) {
        fprintf(lf, "[%.3f] t=%ld IOCTL fd=%d type=0x%x nr=%u sz=%u ret=%ld | ",
                ms(), syscall(SYS_gettid), fd, type, nr, sz, ret);
        if (arg && sz) {
            unsigned long *w = (unsigned long *)arg;
            unsigned k, n = sz / 8 > 12 ? 12 : sz / 8;
            for (k = 0; k < n; k++) fprintf(lf, "%016lx ", w[k]);
        }
        fprintf(lf, "\n"); fflush(lf);
    }
    return (int)ret;
}

ssize_t read(int fd, void *buf, size_t n)
{
    ssize_t r;
    ini();
    r = real_read(fd, buf, n);
    if (lf && fd >= 3 && n <= 64 && r > 0) dump("READ", fd, buf, (size_t)r, r);
    return r;
}

ssize_t write(int fd, const void *buf, size_t n)
{
    ssize_t r;
    ini();
    if (lf && fd >= 3 && n <= 512) dump("WRITE", fd, buf, n, 0);
    r = real_write(fd, buf, n);
    return r;
}

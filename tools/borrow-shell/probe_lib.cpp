// 最小可行性探针：确认 libnpucompiler.so 可加载、关键符号可解析
// 不追求跑通编译，只回答"能不能用 C++ 链接它"
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <string>

int main() {
    const char *L = "/usr/local/lib/libnpucompiler.so";
    void *h = dlopen(L, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("dlopen 失败: %s\n", dlerror());
        return 1;
    }
    printf("dlopen OK: %p\n", h);

    // 关键符号（mangled 名，从 nm 抄来）
    const char *syms[] = {
        "_ZNK8CnnModel9read_jsonEPKcb",                 // CnnModel::read_json(char const*, bool) const
        "_ZNK8CnnModel10build_jsonEPKcbbb9CnnGEType",   // CnnModel::build_json(...)
        "_ZN17CnnModelHwAdapter11GenerateMBSERK16CnnAllocatorBaseRSobbb", // 近似
        "_ZN22CnnInterleavingOptions5applyEP8CnnModel", // CnnInterleavingOptions::apply(CnnModel*)
        nullptr
    };
    for (int i = 0; syms[i]; i++) {
        void *p = dlsym(h, syms[i]);
        printf("  %-60s -> %s\n", syms[i], p ? "FOUND" : "not found");
    }

    // 用 nm 输出核对真实签名
    printf("\n提示：上面 not found 的是我猜的 mangled 名，需用 nm 的真实签名。\n");
    dlclose(h);
    return 0;
}

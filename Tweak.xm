#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <dlfcn.h>
#import <stdint.h>

// Stheno.dylib 拖拽越界修复 (arm64e 运行时补丁)
//
// 根因：Stheno.dylib 内部函数 0x9ca84 在写回拖拽百分比时，
//       只夹下界 0.3 (fmaxnm)，漏了上界 0.7 (fminnm)，
//       导致百分比可无限累加 >1.0，卡片被拖出屏幕。
//
// 补丁：把 0x9cacc..0x9cad8 这 4 条指令原位替换为：
//       ldr d1, 0xb4800   (0.3)
//       ldr d2, 0xb4810   (0.7)
//       fmaxnm d0, d0, d1
//       fminnm d0, d0, d2
// 即把结果夹到 [0.3, 0.7]，指令条数不变，不破坏代码签名/PAC。
//
// 注意：0x9ca84 / 0xb4800 / 0xb4810 均为 __TEXT 段内的 VM 地址，
//       __TEXT vmaddr = 0，故运行时地址 = mach_header + vmaddr。

// 函数 0x9ca84 内被替换的第一条指令 (mov x8,#0x3f... 载入 0.3 的前半)
static const uint64_t kPatchVmAddr = 0x9cacc;
static const uint32_t kPatchInsns[4] = {
    0x5c0be9a1,  // ldr d1, 0xb4800  (0.3)
    0x5c0bea02,  // ldr d2, 0xb4810  (0.7)
    0x1e616800,  // fmaxnm d0, d0, d1
    0x1e627800,  // fminnm d0, d0, d2
};

static bool sPatched = false;

static void TryPatchStheno(void) {
    if (sPatched) return;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;

        // 只在 Stheno.dylib 上打补丁
        size_t len = strlen(name);
        if (len < 12) continue;
        if (strcmp(name + len - 12, "Stheno.dylib") != 0) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh == NULL) continue;

        uintptr_t base = (uintptr_t)mh;
        uintptr_t target = base + kPatchVmAddr;
        uintptr_t page = target & ~(uintptr_t)0x3fffULL;

        // 让该页可写
        if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
            continue;
        }

        volatile uint32_t *p = (volatile uint32_t *)target;
        for (int j = 0; j < 4; j++) {
            p[j] = kPatchInsns[j];
        }

        // 刷新指令缓存
        sys_icache_invalidate((void *)target, 16);

        // 恢复只读+执行
        mprotect((void *)page, 0x4000, PROT_READ | PROT_EXEC);

        sPatched = true;
        break;
    }
}

static void ImageAddedCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh;
    (void)vmaddr_slide;
    TryPatchStheno();
}

__attribute__((constructor)) static void SthenoBoundsInit(void) {
    // 先试一次（可能已加载）
    TryPatchStheno();
    // 注册回调，Stheno.dylib 晚于本 tweak 加载时也能命中
    _dyld_register_func_for_add_image(ImageAddedCallback);
}

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <dlfcn.h>
#import <stdint.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdio.h>

static void Log(const char *f, ...) {
    int d = open("/var/mobile/Documents/SthenoBounds.trace", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (d < 0) return;
    char b[512]; va_list a; va_start(a, f);
    int n = vsnprintf(b, sizeof(b), f, a); va_end(a);
    if (n > 0) write(d, b, (size_t)(n < 511 ? n : 511));
    close(d);
}

// 期望在 0x9cacc 处看到的原始指令（用于校验目标正确性）
static const uint32_t kExpectedOrig[4] = {
    0xd2c33348,  // mov x8, #0x3333333333333333  (0.3 的低 16 位)
    0xf2dfd3c8,  // movk x8, #0x3fd3, lsl #48
    0x9e670101,  // fmov d1, x8
    0x1e616800,  // fmaxnm d0, d0, d1
};

static const uint32_t kPatchInsns[4] = {
    0x5c0be9a1,  // ldr d1, 0xb4800  (0.3)
    0x5c0bea02,  // ldr d2, 0xb4810  (0.7)
    0x1e616800,  // fmaxnm d0, d0, d1
    0x1e627800,  // fminnm d0, d0, d2
};

static const uint64_t kPatchVmAddr = 0x9cacc;

static bool sPatched = false;

static void TryPatchStheno(void) {
    if (sPatched) return;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        size_t len = strlen(name);
        if (len < 12) continue;
        if (strcmp(name + len - 12, "Stheno.dylib") != 0) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh == NULL) continue;

        uintptr_t base = (uintptr_t)mh;
        uintptr_t target = base + kPatchVmAddr;
        uintptr_t page = target & ~(uintptr_t)0x3fffULL;

        uint32_t orig[4];
        memcpy(orig, (const void *)target, 16);
        Log("FOUND Stheno.dylib base=%p target=%p page=%p\n", (void *)base, (void *)target, (void *)page);
        Log("  orig words: %08x %08x %08x %08x\n", orig[0], orig[1], orig[2], orig[3]);
        Log("  expect orig: %08x %08x %08x %08x\n", kExpectedOrig[0], kExpectedOrig[1], kExpectedOrig[2], kExpectedOrig[3]);

        int m1 = mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC);
        Log("  mprotect(RWX)=%d\n", m1);

        volatile uint32_t *p = (volatile uint32_t *)target;
        for (int j = 0; j < 4; j++) p[j] = kPatchInsns[j];

        sys_icache_invalidate((void *)target, 16);

        uint32_t after[4];
        memcpy(after, (const void *)target, 16);
        Log("  after  words: %08x %08x %08x %08x\n", after[0], after[1], after[2], after[3]);

        int m2 = mprotect((void *)page, 0x4000, PROT_READ | PROT_EXEC);
        Log("  mprotect(RX)=%d\n", m2);

        sPatched = true;
        break;
    }
    if (!sPatched) {
        Log("Stheno.dylib NOT FOUND in images (count=%u)\n", count);
    }
}

static void ImageAddedCallback(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    TryPatchStheno();
}

__attribute__((constructor)) static void SthenoBoundsInit(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Log("000SthenoBounds loaded\n");
    TryPatchStheno();
    _dyld_register_func_for_add_image(ImageAddedCallback);
}

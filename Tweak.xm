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
#import <string.h>

static void Log(const char *f, ...) {
    int d = open("/var/mobile/Documents/SthenoBounds.trace", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (d < 0) return;
    char b[512]; va_list a; va_start(a, f);
    int n = vsnprintf(b, sizeof(b), f, a); va_end(a);
    if (n > 0) write(d, b, (size_t)(n < 511 ? n : 511));
    close(d);
}

// 两处拖拽百分比写回点的原位替换：把只夹下界 0.3 改成夹 [0.3, 0.7]
// Site A @ 0x9c084 (横向 rightPecent/leftPecent)
// Site B @ 0x9cacc (纵向 rightHeightPecent/leftHeightPecent)
static const struct {
    uint64_t vmaddr;
    uint32_t insn[4];
} kPatches[] = {
    { 0x9c084, { 0x5c0c3be1, 0x5c0c3c42, 0x1e616800, 0x1e627800 } },
    { 0x9cacc, { 0x5c0be9a1, 0x5c0bea02, 0x1e616800, 0x1e627800 } },
};

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
        Log("FOUND Stheno.dylib base=%p\n", (void *)base);

        for (size_t k = 0; k < sizeof(kPatches)/sizeof(kPatches[0]); k++) {
            uintptr_t target = base + kPatches[k].vmaddr;
            uintptr_t page = target & ~(uintptr_t)0x3fffULL;

            uint32_t orig[4];
            memcpy(orig, (const void *)target, 16);
            Log("  site @ +%llx orig: %08x %08x %08x %08x\n",
                (unsigned long long)kPatches[k].vmaddr,
                orig[0], orig[1], orig[2], orig[3]);

            int m1 = mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC);
            volatile uint32_t *p = (volatile uint32_t *)target;
            for (int j = 0; j < 4; j++) p[j] = kPatches[k].insn[j];
            sys_icache_invalidate((void *)target, 16);

            uint32_t after[4];
            memcpy(after, (const void *)target, 16);
            Log("  site @ +%llx after: %08x %08x %08x %08x (mprotect=%d)\n",
                (unsigned long long)kPatches[k].vmaddr,
                after[0], after[1], after[2], after[3], m1);

            mprotect((void *)page, 0x4000, PROT_READ | PROT_EXEC);
        }

        sPatched = true;
        break;
    }
    if (!sPatched) Log("Stheno.dylib NOT FOUND (images=%u)\n", count);
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

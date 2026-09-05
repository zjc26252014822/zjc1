#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <substrate.h>
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

static uintptr_t gBase = 0;

// 4 个调用 DragGesture.Value.translation 的函数入口
typedef void (*DragFn)(void *, void *);
static DragFn orig2f894, orig4a780, orig610e0, orig7fd88;

static void logEnter(const char *tag, void *a0, void *a1) {
    Log("ENTER %s a0=%p a1=%p\n", tag, a0, a1);
}

static void h2f894(void *a0, void *a1) { logEnter("2f894", a0, a1); orig2f894(a0, a1); }
static void h4a780(void *a0, void *a1) { logEnter("4a780", a0, a1); orig4a780(a0, a1); }
static void h610e0(void *a0, void *a1) { logEnter("610e0", a0, a1); orig610e0(a0, a1); }
static void h7fd88(void *a0, void *a1) { logEnter("7fd88", a0, a1); orig7fd88(a0, a1); }

static bool sHooked = false;

static void TryHook(void) {
    if (sHooked) return;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len < 12) continue;
        if (strcmp(name + len - 12, "Stheno.dylib") != 0) continue;
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh) continue;
        gBase = (uintptr_t)mh;
        Log("BASE=%p\n", (void *)gBase);
        MSHookFunction((void *)(gBase + 0x2f894), (void *)h2f894, (void **)&orig2f894);
        MSHookFunction((void *)(gBase + 0x4a780), (void *)h4a780, (void **)&orig4a780);
        MSHookFunction((void *)(gBase + 0x610e0), (void *)h610e0, (void **)&orig610e0);
        MSHookFunction((void *)(gBase + 0x7fd88), (void *)h7fd88, (void **)&orig7fd88);
        Log("all 4 hooks installed\n");
        sHooked = true;
        break;
    }
    if (!sHooked) Log("not yet images=%u\n", count);
}

static void ImgCB(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    TryHook();
}

__attribute__((constructor)) static void Init(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Log("diag4 loaded\n");
    TryHook();
    _dyld_register_func_for_add_image(ImgCB);
}

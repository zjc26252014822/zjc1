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

// 0x4a780 = DragGesture.onChanged 处理函数 (Swift, x0=obj, x1=value)
// 从 x19(=x1) 的字段读 gestureState 字节，字段偏移存在 __DATA 全局 [0xf7000+0x8e0]
static void (*origDrag)(void *, void *);

static uint32_t ReadStateOffset(void) {
    if (!gBase) return 0;
    // 0xf7000 落在 __DATA 段；全局存的是字段偏移量（运行时由 Swift 填好）
    uintptr_t slot = gBase + 0xf7000 + 0x8e0;
    return *(uint32_t *)(slot);
}

static void hookDrag(void *obj, void *val) {
    uint32_t off = ReadStateOffset();
    uint8_t state = 0;
    if (off) state = *(uint8_t *)((uintptr_t)val + off);
    // 顺便读一下首帧 translation 存的位置 [val+0x60]/[val+0x68]
    double tx = 0, ty = 0;
    if (val) { tx = *(double *)((uintptr_t)val + 0x60); ty = *(double *)((uintptr_t)val + 0x68); }
    Log("DRAG state=%u firstTrans=(%.1f,%.1f) off=%u\n", state, tx, ty, off);
    origDrag(obj, val);
}

static bool sHooked = false;

static void TryHookStheno(void) {
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
        Log("HOOK base=%p stateSlot=%p stateOff=%u\n", (void *)gBase, (void *)(gBase + 0xf7000 + 0x8e0), ReadStateOffset());
        MSHookFunction((void *)(gBase + 0x4a780), (void *)hookDrag, (void **)&origDrag);
        sHooked = true;
        break;
    }
    if (!sHooked) Log("not yet: images=%u\n", count);
}

static void ImgCB(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    TryHookStheno();
}

__attribute__((constructor)) static void Init(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Log("diagnostic loaded\n");
    TryHookStheno();
    _dyld_register_func_for_add_image(ImgCB);
}

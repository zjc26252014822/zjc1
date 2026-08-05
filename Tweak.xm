#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
extern void MSHookFunction(void *, void *, void **);
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

typedef void *(*InitFn)(void *, void *);
static InitFn OrigReflectInit;
static __unsafe_unretained id managers[16];
static NSUInteger managerCount;
static uintptr_t finalFrameOffset, finalOffsetOffset;
static BOOL offsetsReady;
static IMP OrigPanSetState;
static const CGFloat Edge = 12.0, Top = 59.0, Bottom = 34.0;

static void *HookReflectInit(void *a, void *b) {
    void *object = OrigReflectInit(a, b);
    if (object && managerCount < 16) managers[managerCount++] = (__bridge id)object;
    return object;
}
static BOOL Good(uintptr_t x) { return x >= 16 && x <= 0x1000 && !(x & 7); }
static void Prepare(id object) {
    if (offsetsReady || !object) return;
    const uintptr_t *fields = (const uintptr_t *)((uintptr_t)[object class] + 10 * sizeof(uintptr_t));
    if (!Good(fields[16]) || !Good(fields[18])) return;
    finalFrameOffset = fields[16]; finalOffsetOffset = fields[18]; offsetsReady = YES;
}
static void ClampFinishedOffsets(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    for (NSUInteger i=0; i<managerCount; i++) {
        id object = managers[i]; if (!object) continue;
        Prepare(object); if (!offsetsReady) continue;
        uint8_t *base = (uint8_t *)(__bridge void *)object;
        double *frame = (double *)(base + finalFrameOffset);
        double *offset = (double *)(base + finalOffsetOffset);
        // Device trace proves: frame[0,1] = scaled card size;
        // offset[0,1] = drag displacement from the centered card position.
        double width=frame[0], height=frame[1];
        if (!isfinite(width) || !isfinite(height) || width < 80 || height < 80) continue;
        double centeredX=(screen.size.width-width)*.5;
        double centeredY=(screen.size.height-height)*.5;
        double minX=Edge-centeredX, maxX=screen.size.width-Edge-width-centeredX;
        double minY=Top+Edge-centeredY, maxY=screen.size.height-Bottom-Edge-height-centeredY;
        if (minX <= maxX && isfinite(offset[0])) offset[0] = MIN(MAX(offset[0], minX), maxX);
        if (minY <= maxY && isfinite(offset[1])) offset[1] = MIN(MAX(offset[1], minY), maxY);
    }
}
static void HookPanSetState(UIPanGestureRecognizer *self, SEL cmd, UIGestureRecognizerState state) {
    ((void(*)(id,SEL,UIGestureRecognizerState))OrigPanSetState)(self,cmd,state);
    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        // Let Stheno consume its final drag value first; then only correct final state.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ClampFinishedOffsets(); });
    }
}
static void InstallStheno(const struct mach_header *header, intptr_t slide) {
    static BOOL hooked; if (hooked) return;
    Dl_info info={0}; if (!dladdr(header,&info) || !info.dli_fname || !strstr(info.dli_fname,"Stheno.dylib")) return;
    MSHookFunction((void *)((uintptr_t)header+0x4da60), (void *)HookReflectInit, (void **)&OrigReflectInit);
    hooked=YES;
}
static void InstallPanHook(void) {
    static BOOL hooked; if (hooked) return;
    Class cls=UIPanGestureRecognizer.class;
    MSHookMessageEx(cls,@selector(setState:),(IMP)HookPanSetState,&OrigPanSetState);
    hooked=YES;
}
__attribute__((constructor)) static void Start(void) {
    _dyld_register_func_for_add_image(InstallStheno);
    InstallPanHook();
}

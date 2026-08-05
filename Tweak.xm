#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <string.h>
extern void MSHookFunction(void *symbol, void *replace, void **result);

// arm64e static analysis of the supplied Stheno.dylib:
// 0x4da60 is ReflectManager's allocating initializer. It calls its metadata
// accessor (0x43100), swift_allocObject, then returns the initialized object.
typedef void *(*ReflectInitFn)(void *, void *);
static ReflectInitFn OrigReflectInit = NULL;
static __unsafe_unretained id ReflectInstance = nil;
static BOOL offsetsReady = NO;
static uintptr_t finalFrameOffset = 0, finalOffsetOffset = 0, finalCardFrameOffset = 0;
static CADisplayLink *stateGuard = nil;
static const CGFloat Edge = 12.0;

static void *HookReflectInit(void *arg0, void *arg1) {
    void *object = OrigReflectInit(arg0, arg1);
    if (object) ReflectInstance = (__bridge id)object;
    return object;
}
static BOOL GoodOffset(uintptr_t x) { return x >= 16 && x <= 0x1000 && !(x & 7); }
static void ReadOffsets(id object) {
    if (offsetsReady || !object) return;
    // Swift ABI: ReflectManager ClassDescriptor fieldOffsetVectorOffset = 10
    // words; ClassMetadata::getFieldOffsets uses pointer-sized entries.
    uintptr_t metadata = (uintptr_t)[object class];
    const uintptr_t *fields = (const uintptr_t *)(metadata + 10 * sizeof(uintptr_t));
    uintptr_t frame = fields[16], offset = fields[18], card = fields[19];
    if (!GoodOffset(frame) || !GoodOffset(offset) || !GoodOffset(card)) return;
    finalFrameOffset = frame; finalOffsetOffset = offset; finalCardFrameOffset = card;
    offsetsReady = YES;
}
static CGRect Clamp(CGRect f) {
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat minX=Edge, minY=59.0+Edge;
    CGFloat maxX=b.size.width-Edge-f.size.width, maxY=b.size.height-34.0-Edge-f.size.height;
    if (f.size.width>80 && f.size.width<b.size.width*1.5 && maxX>=minX) f.origin.x=MIN(MAX(f.origin.x,minX),maxX);
    if (f.size.height>80 && f.size.height<b.size.height*1.5 && maxY>=minY) f.origin.y=MIN(MAX(f.origin.y,minY),maxY);
    return f;
}
@interface ReflectStateGuard:NSObject @end
@implementation ReflectStateGuard
- (void)tick:(CADisplayLink *)unused {
    id object=ReflectInstance; if (!object) return; ReadOffsets(object); if (!offsetsReady) return;
    uint8_t *base=(uint8_t *)(__bridge void *)object;
    // finalFrame and finalCardFrame are CGRect state. finalOffset is left
    // untouched because it is a SwiftUI drag vector, not necessarily CGRect.
    CGRect *frame=(CGRect *)(base+finalFrameOffset), *card=(CGRect *)(base+finalCardFrameOffset);
    CGRect a=*frame,b=*card;
    if (isfinite(a.origin.x)&&isfinite(a.origin.y)) *frame=Clamp(a);
    if (isfinite(b.origin.x)&&isfinite(b.origin.y)) *card=Clamp(b);
}
@end
static void Install(void) {
    static BOOL done=NO; if(done) return;
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if (!name || !strstr(name,"Stheno.dylib")) continue;
        const struct mach_header *header=_dyld_get_image_header(i);
        if (!header) return;
        void *target=(void *)((uintptr_t)header+0x4da60);
        MSHookFunction(target,(void *)HookReflectInit,(void **)&OrigReflectInit);
        ReflectStateGuard *guard=[ReflectStateGuard new];
        stateGuard=[CADisplayLink displayLinkWithTarget:guard selector:@selector(tick:)];
        objc_setAssociatedObject(stateGuard,@selector(tick:),guard,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stateGuard addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        done=YES; return;
    }
}
__attribute__((constructor)) static void Start(void) {
    // 000SthenoBounds is injected before Stheno; retry until dyld lists it.
    dispatch_async(dispatch_get_main_queue(),^{for(NSUInteger i=1;i<=80;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/4),dispatch_get_main_queue(),^{Install();});});
}

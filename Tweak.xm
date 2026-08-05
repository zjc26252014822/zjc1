#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Stheno uses a Swift-only ReflectManager. Its arm64e field metadata shows:
// field 16 = finalFrame, 18 = finalOffset, 19 = finalCardFrame.
// Swift creates it with swift_allocObject, not Objective-C +alloc.
typedef void *(*SwiftAllocFn)(void *metadata, size_t size, size_t alignmentMask);
static SwiftAllocFn OrigSwiftAlloc = NULL;
static void *ReflectMetadata = NULL;
static __unsafe_unretained id ReflectInstance = nil;
static BOOL offsetsReady = NO;
static uint32_t finalFrameOffset = 0, finalCardFrameOffset = 0;
static CADisplayLink *stateGuardLink = nil;
static const CGFloat Edge = 12.0;

static void *HookSwiftAlloc(void *metadata, size_t size, size_t alignmentMask) {
    void *object = OrigSwiftAlloc(metadata, size, alignmentMask);
    if (object && metadata == ReflectMetadata) ReflectInstance = (__bridge id)object;
    return object;
}
static CGRect ClampRect(CGRect f) {
    CGRect screen = UIScreen.mainScreen.bounds;
    const CGFloat top = 59.0 + Edge, bottom = 34.0 + Edge;
    CGFloat maxX = screen.size.width - Edge - f.size.width;
    CGFloat maxY = screen.size.height - bottom - f.size.height;
    if (f.size.width > 80 && f.size.width < screen.size.width * 1.5 && maxX >= Edge)
        f.origin.x = MIN(MAX(f.origin.x, Edge), maxX);
    if (f.size.height > 80 && f.size.height < screen.size.height * 1.5 && maxY >= top)
        f.origin.y = MIN(MAX(f.origin.y, top), maxY);
    return f;
}
static BOOL ValidOffset(uint32_t x) { return x >= 16 && x <= 0x1000 && !(x & 7); }
static void Prepare(id object) {
    if (offsetsReady || !object) return;
    // Swift class descriptor proved by analysis: field-offset vector word is #10.
    uintptr_t metadata = (uintptr_t)object_getClass(object);
    uint32_t vectorWord = *(uint32_t *)(metadata + 10 * sizeof(uintptr_t));
    if (vectorWord < 4 || vectorWord > 128) return;
    uint32_t *offsets = (uint32_t *)(metadata + (uintptr_t)vectorWord * sizeof(uintptr_t));
    uint32_t a = offsets[16], b = offsets[19];
    if (!ValidOffset(a) || !ValidOffset(b)) return;
    finalFrameOffset = a; finalCardFrameOffset = b; offsetsReady = YES;
}
@interface SthenoSwiftStateGuard : NSObject @end
@implementation SthenoSwiftStateGuard
- (void)tick:(CADisplayLink *)unused {
    id object = ReflectInstance; if (!object) return;
    Prepare(object); if (!offsetsReady) return;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    // Clamp both stored CGRects; Stheno chooses between them during Medusa motion.
    CGRect *finalFrame = (CGRect *)(base + finalFrameOffset);
    CGRect *cardFrame = (CGRect *)(base + finalCardFrameOffset);
    CGRect a = *finalFrame, b = *cardFrame;
    if (isfinite(a.origin.x) && isfinite(a.origin.y)) *finalFrame = ClampRect(a);
    if (isfinite(b.origin.x) && isfinite(b.origin.y)) *cardFrame = ClampRect(b);
}
@end
static void Install(void) {
    static BOOL installed = NO; if (installed) return;
    Class c = NSClassFromString(@"Stheno.ReflectManager"); if (!c) return;
    ReflectMetadata = (__bridge void *)c;
    void *swiftAlloc = dlsym(RTLD_DEFAULT, "swift_allocObject");
    if (!swiftAlloc) return;
    MSHookFunction(swiftAlloc, (void *)HookSwiftAlloc, (void **)&OrigSwiftAlloc);
    SthenoSwiftStateGuard *guard = [SthenoSwiftStateGuard new];
    stateGuardLink = [CADisplayLink displayLinkWithTarget:guard selector:@selector(tick:)];
    objc_setAssociatedObject(stateGuardLink, @selector(tick:), guard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [stateGuardLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    installed = YES;
}
%ctor { dispatch_async(dispatch_get_main_queue(), ^{ for (NSUInteger i=1;i<=40;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(), ^{ Install(); }); }); }

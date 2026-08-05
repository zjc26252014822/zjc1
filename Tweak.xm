#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

// Direct Swift-state guard. Stheno.ReflectManager's arm64e metadata exposes
// 42 stored fields. finalCardFrame is field 19, finalOffset is field 18.
static __weak id manager = nil;
static CADisplayLink *guardDisplayLink = nil;
static IMP origAlloc = NULL;
static BOOL initialized = NO;
static NSUInteger cardFrameOffset = 0;
static const CGFloat margin = 12.0;

typedef id (*AllocFn)(id,SEL);
static id HookAlloc(id self, SEL cmd) {
    id object = ((AllocFn)origAlloc)(self,cmd);
    if (object) manager = object;
    return object;
}

static CGRect Clamp(CGRect f) {
    CGRect b = UIScreen.mainScreen.bounds;
    UIEdgeInsets inset = UIEdgeInsetsMake(59, 0, 34, 0);
    CGFloat minX = inset.left + margin, minY = inset.top + margin;
    CGFloat maxX = b.size.width - inset.right - margin - f.size.width;
    CGFloat maxY = b.size.height - inset.bottom - margin - f.size.height;
    if (maxX >= minX) f.origin.x = MIN(MAX(f.origin.x,minX),maxX);
    if (maxY >= minY) f.origin.y = MIN(MAX(f.origin.y,minY),maxY);
    return f;
}

static BOOL PrepareOffsets(id object) {
    if (initialized) return cardFrameOffset != 0;
    initialized = YES;
    // Swift ClassDescriptor: fieldOffsetVectorOffset is word #10; metadata
    // contains UInt32 stored-property offsets beginning at that word offset.
    uintptr_t metadata = (uintptr_t)object_getClass(object);
    uint32_t vectorWord = *(uint32_t *)(metadata + 10 * sizeof(uintptr_t));
    if (vectorWord < 4 || vectorWord > 128) return NO;
    uint32_t *offsets = (uint32_t *)(metadata + (uintptr_t)vectorWord * sizeof(uintptr_t));
    uint32_t candidate = offsets[19]; // finalCardFrame
    // Validate the candidate is a plausible aligned object field location.
    if (candidate < 16 || candidate > 0x1000 || (candidate & 7)) return NO;
    cardFrameOffset = candidate;
    return YES;
}

@interface SthenoReflectGuard : NSObject @end
@implementation SthenoReflectGuard
- (void)tick:(CADisplayLink *)unused {
    id object = manager;
    if (!object || !PrepareOffsets(object)) return;
    CGRect *frame = (CGRect *)((uint8_t *)(__bridge void *)object + cardFrameOffset);
    CGRect before = *frame, limited = Clamp(before);
    if (!CGRectEqualToRect(before, limited)) *frame = limited;
}
@end

static void Install(void) {
    static Class cls = Nil;
    if (cls) return;
    cls = NSClassFromString(@"Stheno.ReflectManager");
    if (!cls) return;
    MSHookMessageEx(object_getClass(cls), @selector(alloc), (IMP)HookAlloc, &origAlloc);
    SthenoReflectGuard *guard = [SthenoReflectGuard new];
    guardDisplayLink = [CADisplayLink displayLinkWithTarget:guard selector:@selector(tick:)];
    objc_setAssociatedObject(guardDisplayLink, @selector(tick:), guard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [guardDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
%ctor { dispatch_async(dispatch_get_main_queue(), ^{ for (NSUInteger i=1;i<=40;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(), ^{ Install(); }); }); }

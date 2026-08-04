#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static IMP origSetFrame = NULL;
static __thread BOOL adjusting = NO;
static const CGFloat kEdgeMargin = 12.0;
static Class SthenoWindowClass = Nil;

static CGRect ClampFrame(UIWindow *window, CGRect frame) {
    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    CGRect bounds = screen.bounds;
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat minX = CGRectGetMinX(bounds) + safe.left + kEdgeMargin;
    CGFloat minY = CGRectGetMinY(bounds) + safe.top + kEdgeMargin;
    CGFloat maxX = CGRectGetMaxX(bounds) - safe.right - kEdgeMargin - CGRectGetWidth(frame);
    CGFloat maxY = CGRectGetMaxY(bounds) - safe.bottom - kEdgeMargin - CGRectGetHeight(frame);
    frame.origin.x = (maxX < minX) ? (minX + maxX) * .5 : MIN(MAX(frame.origin.x, minX), maxX);
    frame.origin.y = (maxY < minY) ? (minY + maxY) * .5 : MIN(MAX(frame.origin.y, minY), maxY);
    return frame;
}

static void ApplyBoundary(UIWindow *window) {
    if (!window || adjusting || window.hidden) return;
    CGRect old = window.frame, limited = ClampFrame(window, old);
    if (!CGRectEqualToRect(old, limited)) {
        adjusting = YES;
        window.frame = limited;
        adjusting = NO;
        NSLog(@"[SthenoBounds] corrected %@", window);
    }
}

static void HookedSetFrame(UIWindow *self, SEL cmd, CGRect frame) {
    if (adjusting || !origSetFrame) { ((void(*)(id,SEL,CGRect))origSetFrame)(self,cmd,frame); return; }
    ((void(*)(id,SEL,CGRect))origSetFrame)(self,cmd,ClampFrame(self, frame));
}

@interface SthenoBoundaryGuard : NSObject @end
@implementation SthenoBoundaryGuard
- (void)tick:(CADisplayLink *)link {
    if (!SthenoWindowClass) SthenoWindowClass = NSClassFromString(@"Stheno.SthenoWindow");
    if (!SthenoWindowClass) return;
    // This independent display-link guard catches frame updates that bypass setFrame:.
    for (UIWindow *window in UIApplication.sharedApplication.windows)
        if ([window isKindOfClass:SthenoWindowClass]) ApplyBoundary(window);
}
@end

static void Install(void) {
    SthenoWindowClass = NSClassFromString(@"Stheno.SthenoWindow");
    if (!SthenoWindowClass) return;
    if (!origSetFrame) MSHookMessageEx(SthenoWindowClass, @selector(setFrame:), (IMP)HookedSetFrame, &origSetFrame);
    static SthenoBoundaryGuard *guard;
    static CADisplayLink *displayLink;
    if (!guard) {
        guard = [SthenoBoundaryGuard new];
        displayLink = [CADisplayLink displayLinkWithTarget:guard selector:@selector(tick:)];
        [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    NSLog(@"[SthenoBounds] frame hook and display guard active");
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSUInteger n=1; n<=40; n++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n*.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
    });
}

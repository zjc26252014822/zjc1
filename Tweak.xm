#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static IMP origSetFrame = NULL;
static __thread BOOL adjusting = NO;
static const CGFloat kEdgeMargin = 12.0;

static CGRect boundedFrame(UIWindow *window, CGRect frame) {
    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    CGRect bounds = screen.bounds;
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat minX = CGRectGetMinX(bounds) + safe.left + kEdgeMargin;
    CGFloat minY = CGRectGetMinY(bounds) + safe.top + kEdgeMargin;
    CGFloat maxX = CGRectGetMaxX(bounds) - safe.right - kEdgeMargin - CGRectGetWidth(frame);
    CGFloat maxY = CGRectGetMaxY(bounds) - safe.bottom - kEdgeMargin - CGRectGetHeight(frame);
    frame.origin.x = maxX < minX ? (minX + maxX) / 2.0 : MIN(MAX(frame.origin.x, minX), maxX);
    frame.origin.y = maxY < minY ? (minY + maxY) / 2.0 : MIN(MAX(frame.origin.y, minY), maxY);
    return frame;
}

static void hookedSetFrame(UIWindow *self, SEL _cmd, CGRect frame) {
    if (adjusting) { ((void(*)(id,SEL,CGRect))origSetFrame)(self, _cmd, frame); return; }
    CGRect limited = boundedFrame(self, frame);
    BOOL exceeded = !CGRectEqualToRect(frame, limited);
    adjusting = YES;
    ((void(*)(id,SEL,CGRect))origSetFrame)(self, _cmd, limited);
    adjusting = NO;
    if (exceeded) NSLog(@"[SthenoBounds] clamped Stheno floating window");
}

static void installHook(void) {
    Class cls = objc_getClass("Stheno.SthenoWindow");
    if (!cls) { NSLog(@"[SthenoBounds] SthenoWindow unavailable; retrying"); return; }
    SEL selector = @selector(setFrame:);
    MSHookMessageEx(cls, selector, (IMP)hookedSetFrame, &origSetFrame);
    NSLog(@"[SthenoBounds] hook installed on %@", NSStringFromClass(cls));
}

%ctor {
    NSLog(@"[SthenoBounds] injected into SpringBoard");
    // Stheno's Swift class is registered after dylib load; retry during launch.
    for (NSUInteger n = 1; n <= 20; n++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!origSetFrame) installHook();
        });
    }
}

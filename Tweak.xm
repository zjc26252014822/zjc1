#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>

// Stheno's actual floating app card is managed by SpringBoard's
// BNContentViewController (not SthenoWindow). Keep only that card in bounds.
static __weak UIView *cardView = nil;
static __weak UIViewController *cardController = nil;
static IMP origViewDidAppear = NULL;
static IMP origViewDidLayoutSubviews = NULL;
static CADisplayLink *guardLink = nil;
static __thread BOOL correcting = NO;
static const CGFloat edgeMargin = 12.0;

static void ClampCard(void) {
    UIView *card = cardView;
    if (!card || correcting || card.hidden || !card.superview) return;
    UIView *host = card.superview;
    CGRect hostBounds = host.bounds;
    UIEdgeInsets safe = host.safeAreaInsets;
    // card.frame includes any transform, therefore correcting center preserves
    // Stheno's scale/rotation while keeping the rendered card on-screen.
    CGRect rendered = card.frame;
    CGFloat minX = CGRectGetMinX(hostBounds) + safe.left + edgeMargin;
    CGFloat minY = CGRectGetMinY(hostBounds) + safe.top + edgeMargin;
    CGFloat maxX = CGRectGetMaxX(hostBounds) - safe.right - edgeMargin;
    CGFloat maxY = CGRectGetMaxY(hostBounds) - safe.bottom - edgeMargin;
    CGFloat dx = 0, dy = 0;
    if (CGRectGetWidth(rendered) <= maxX-minX) {
        if (CGRectGetMinX(rendered) < minX) dx = minX-CGRectGetMinX(rendered);
        else if (CGRectGetMaxX(rendered) > maxX) dx = maxX-CGRectGetMaxX(rendered);
    }
    if (CGRectGetHeight(rendered) <= maxY-minY) {
        if (CGRectGetMinY(rendered) < minY) dy = minY-CGRectGetMinY(rendered);
        else if (CGRectGetMaxY(rendered) > maxY) dy = maxY-CGRectGetMaxY(rendered);
    }
    if (dx == 0 && dy == 0) return;
    correcting = YES;
    CGPoint c = card.center; c.x += dx; c.y += dy;
    card.center = c;
    correcting = NO;
}

@interface SthenoBNGuard : NSObject @end
@implementation SthenoBNGuard
- (void)tick:(CADisplayLink *)link { ClampCard(); }
@end

static void StartGuard(UIViewController *controller) {
    if (!controller.view || !controller.view.superview) return;
    cardController = controller;
    cardView = controller.view;
    if (!guardLink) {
        SthenoBNGuard *target = [SthenoBNGuard new];
        guardLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
        // CADisplayLink does not retain target; associate it with link.
        objc_setAssociatedObject(guardLink, @selector(tick:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [guardLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    ClampCard();
}

static void HookViewDidAppear(UIViewController *self, SEL cmd, BOOL animated) {
    ((void(*)(id,SEL,BOOL))origViewDidAppear)(self,cmd,animated);
    StartGuard(self);
}
static void HookViewDidLayoutSubviews(UIViewController *self, SEL cmd) {
    ((void(*)(id,SEL))origViewDidLayoutSubviews)(self,cmd);
    StartGuard(self);
}
static void Install(void) {
    static Class cls = Nil;
    if (cls) return;
    cls = NSClassFromString(@"BNContentViewController");
    if (!cls) return;
    MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)HookViewDidAppear, &origViewDidAppear);
    MSHookMessageEx(cls, @selector(viewDidLayoutSubviews), (IMP)HookViewDidLayoutSubviews, &origViewDidLayoutSubviews);
}
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSUInteger i=1; i<=40; i++)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i*.25*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
    });
}

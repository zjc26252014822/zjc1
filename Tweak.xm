#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static IMP OrigBNView;
static __weak UIView *bnRoot;
static __thread BOOL correcting = NO;
static const CGFloat M = 12.0;

static BOOL ClampOne(UIView *v, UIView *host) {
    if (!v || v.hidden || v.alpha < .01 || v == host || correcting) return NO;
    CGRect b=host.bounds, f=v.frame; UIEdgeInsets s=host.safeAreaInsets;
    CGFloat lx=CGRectGetMinX(b)+s.left+M, ly=CGRectGetMinY(b)+s.top+M;
    CGFloat rx=CGRectGetMaxX(b)-s.right-M, by=CGRectGetMaxY(b)-s.bottom-M;
    // Only a card-sized view that is actually outside its host is eligible.
    if (CGRectGetWidth(f)<120 || CGRectGetHeight(f)<120 || CGRectGetWidth(f)>CGRectGetWidth(b)*1.25 || CGRectGetHeight(f)>CGRectGetHeight(b)*1.25) return NO;
    CGFloat dx=0,dy=0;
    if (CGRectGetMinX(f)<lx) dx=lx-CGRectGetMinX(f); else if(CGRectGetMaxX(f)>rx) dx=rx-CGRectGetMaxX(f);
    if (CGRectGetMinY(f)<ly) dy=ly-CGRectGetMinY(f); else if(CGRectGetMaxY(f)>by) dy=by-CGRectGetMaxY(f);
    if (!dx&&!dy) return NO;
    correcting=YES; CGPoint c=v.center; c.x+=dx;c.y+=dy;v.center=c;correcting=NO; return YES;
}
static BOOL FindAndClamp(UIView *v, UIView *host, NSUInteger depth) {
    if (depth>12) return NO;
    // Prefer the deepest overflowing card so a full-screen container is untouched.
    for (UIView *child in [v.subviews reverseObjectEnumerator]) if (FindAndClamp(child,host,depth+1)) return YES;
    return ClampOne(v,host);
}
@interface BNFrameGuard:NSObject @end
@implementation BNFrameGuard
- (void)tick:(CADisplayLink *)link { UIView *root=bnRoot; if(root&&root.superview) FindAndClamp(root,root.superview,0); }
@end
static void Begin(UIView *view) {
    if (!view) return; bnRoot=view;
    static CADisplayLink *link; if(link) return;
    BNFrameGuard *g=[BNFrameGuard new]; link=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];
    objc_setAssociatedObject(link,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
static id HookBNView(id self, SEL cmd) { id view=((id(*)(id,SEL))OrigBNView)(self,cmd); Begin(view); return view; }
static void Install(void) { static Class c; if(c)return; c=NSClassFromString(@"BNContentViewController"); if(!c)return; MSHookMessageEx(c,@selector(view),(IMP)HookBNView,&OrigBNView); }
%ctor { dispatch_async(dispatch_get_main_queue(),^{for(NSUInteger i=1;i<=40;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(),^{Install();});}); }

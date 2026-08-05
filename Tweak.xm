#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>

// Directly clamp Stheno's own state model. Reverse-engineering the arm64e
// slice shows ReflectManager owns finalCardFrame / finalFrame / finalOffset.
static IMP origFinalCardFrame = NULL;
static IMP origFinalFrame = NULL;
static const CGFloat margin = 12.0;

static CGRect Clamp(CGRect f) {
    CGRect b = UIScreen.mainScreen.bounds;
    // Window safe-area cannot be used here because this is Stheno model state;
    // use conservative iPhone 16.4 status/home reserved zones.
    CGFloat left=margin, right=margin, top=59.0+margin, bottom=34.0+margin;
    CGFloat minX=CGRectGetMinX(b)+left, minY=CGRectGetMinY(b)+top;
    CGFloat maxX=CGRectGetMaxX(b)-right-CGRectGetWidth(f);
    CGFloat maxY=CGRectGetMaxY(b)-bottom-CGRectGetHeight(f);
    f.origin.x = maxX < minX ? (minX+maxX)*.5 : MIN(MAX(f.origin.x,minX),maxX);
    f.origin.y = maxY < minY ? (minY+maxY)*.5 : MIN(MAX(f.origin.y,minY),maxY);
    return f;
}
static void SetFinalCardFrame(id self, SEL cmd, CGRect frame) {
    ((void(*)(id,SEL,CGRect))origFinalCardFrame)(self,cmd,Clamp(frame));
}
static void SetFinalFrame(id self, SEL cmd, CGRect frame) {
    ((void(*)(id,SEL,CGRect))origFinalFrame)(self,cmd,Clamp(frame));
}
static void Install(void) {
    static Class cls; if(cls) return;
    cls=NSClassFromString(@"Stheno.ReflectManager"); if(!cls) return;
    SEL card=NSSelectorFromString(@"setFinalCardFrame:");
    SEL frame=NSSelectorFromString(@"setFinalFrame:");
    // Only hook selectors which Stheno actually exposes at runtime.
    if([cls instancesRespondToSelector:card]) MSHookMessageEx(cls,card,(IMP)SetFinalCardFrame,&origFinalCardFrame);
    if([cls instancesRespondToSelector:frame]) MSHookMessageEx(cls,frame,(IMP)SetFinalFrame,&origFinalFrame);
}
%ctor { dispatch_async(dispatch_get_main_queue(),^{ for(NSUInteger i=1;i<=40;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(),^{Install();}); }); }

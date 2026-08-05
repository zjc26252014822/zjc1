#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>

static BOOL reported = NO;
static IMP OrigInitFrame, OrigInitScene;

static UIViewController *Top(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
static void Report(UIWindow *window) {
    if (reported || !window) return;
    reported = YES;
    NSMutableString *text = [NSMutableString string];
    CGRect f = window.frame; CGAffineTransform t = window.transform;
    [text appendFormat:@"Window\nf=(%.0f,%.0f %.0fx%.0f)\nt=(%.2f %.2f %.2f %.2f %.1f %.1f)\n\nDirect subviews (%lu):\n",f.origin.x,f.origin.y,f.size.width,f.size.height,t.a,t.b,t.c,t.d,t.tx,t.ty,(unsigned long)window.subviews.count];
    NSUInteger limit = MIN(window.subviews.count, (NSUInteger)8);
    for (NSUInteger i=0; i<limit; i++) {
        UIView *v = window.subviews[i]; CGRect x=v.frame; CGAffineTransform a=v.transform;
        [text appendFormat:@"%lu %@\nf=(%.0f,%.0f %.0fx%.0f)\nt=(%.2f %.2f %.2f %.2f %.1f %.1f)\n",(unsigned long)i,NSStringFromClass(v.class),x.origin.x,x.origin.y,x.size.width,x.size.height,a.a,a.b,a.c,a.d,a.tx,a.ty];
    }
    UIViewController *root = window.rootViewController; if (!root) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Stheno target only" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [Top(root) presentViewController:alert animated:YES completion:nil];
}
static id InitFrame(UIWindow *self, SEL cmd, CGRect frame) {
    self=((id(*)(id,SEL,CGRect))OrigInitFrame)(self,cmd,frame);
    if (self) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{ Report(self); });
    return self;
}
static id InitScene(UIWindow *self, SEL cmd, id scene) {
    self=((id(*)(id,SEL,id))OrigInitScene)(self,cmd,scene);
    if (self) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{ Report(self); });
    return self;
}
static void Install(void) {
    static Class c; if (c) return;
    c=NSClassFromString(@"Stheno.SthenoWindow"); if (!c) return;
    MSHookMessageEx(c,@selector(initWithFrame:),(IMP)InitFrame,&OrigInitFrame);
    SEL s=NSSelectorFromString(@"initWithWindowScene:");
    if ([c instancesRespondToSelector:s]) MSHookMessageEx(c,s,(IMP)InitScene,&OrigInitScene);
}
%ctor { dispatch_async(dispatch_get_main_queue(),^{ for(NSUInteger i=1;i<=30;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(),^{Install();}); }); }

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static UIViewController *Top(UIViewController *vc) { while (vc.presentedViewController) vc=vc.presentedViewController; return vc; }
static NSString *Inspect(void) {
    NSMutableString *r=[NSMutableString string];
    Class direct=NSClassFromString(@"Stheno.SthenoWindow");
    [r appendFormat:@"Stheno.SthenoWindow: %@\n\n", direct?@"FOUND":@"NOT FOUND"];
    int n=objc_getClassList(NULL,0); Class *cs=calloc(n,sizeof(Class)); n=objc_getClassList(cs,n);
    [r appendString:@"Classes containing Stheno:\n"];
    for(int i=0;i<n;i++){ NSString *name=NSStringFromClass(cs[i]); if([name rangeOfString:@"Stheno" options:NSCaseInsensitiveSearch].location!=NSNotFound) [r appendFormat:@"%@\n",name]; }
    free(cs); [r appendString:@"\nWindows:\n"];
    for(UIScene *s in UIApplication.sharedApplication.connectedScenes) if([s isKindOfClass:UIWindowScene.class]) for(UIWindow *w in ((UIWindowScene*)s).windows) [r appendFormat:@"%@ hidden=%d frame=(%.0f,%.0f %.0fx%.0f)\n",NSStringFromClass(w.class),w.hidden,w.frame.origin.x,w.frame.origin.y,w.frame.size.width,w.frame.size.height];
    return r;
}
%ctor { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_main_queue(),^{
    UIWindow *w=nil; for(UIScene *s in UIApplication.sharedApplication.connectedScenes) if([s isKindOfClass:UIWindowScene.class]) for(UIWindow *x in ((UIWindowScene*)s).windows) if(!x.hidden&&x.rootViewController){w=x;break;} if(w)break;
    if(!w)return; UIAlertController *a=[UIAlertController alertControllerWithTitle:@"SthenoBounds diagnostics" message:Inspect() preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:0 handler:nil]]; [Top(w.rootViewController) presentViewController:a animated:YES completion:nil];
}); }

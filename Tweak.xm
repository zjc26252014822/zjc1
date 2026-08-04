#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UIViewController *TopController(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
static void AddTree(NSMutableString *out, UIView *view, NSInteger depth) {
    if (depth > 8 || out.length > 11500) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    CGRect f = view.frame; CGAffineTransform t = view.transform;
    [out appendFormat:@"%@%@ f=(%.0f,%.0f %.0fx%.0f) t=(%.2f %.2f %.2f %.2f %.1f %.1f)\n", pad, NSStringFromClass(view.class), f.origin.x, f.origin.y, f.size.width, f.size.height, t.a,t.b,t.c,t.d,t.tx,t.ty];
    for (UIView *child in view.subviews) AddTree(out, child, depth + 1);
}
static NSString *Report(void) {
    NSMutableString *out = [NSMutableString string];
    Class target = NSClassFromString(@"Stheno.SthenoWindow");
    [out appendFormat:@"Target: %@\n\n", target ? @"FOUND" : @"NOT FOUND"];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden) continue;
            [out appendFormat:@"WINDOW %@ Stheno=%d\n", NSStringFromClass(window.class), target ? [window isKindOfClass:target] : 0];
            AddTree(out, window, 1); [out appendString:@"\n"];
        }
    }
    return out;
}
static UIWindow *FindWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (!window.hidden && window.rootViewController) return window;
    }
    return nil;
}
static void ShowReport(void) {
    UIWindow *window = FindWindow(); if (!window) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stheno geometry" message:Report() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [TopController(window.rootViewController) presentViewController:alert animated:YES completion:nil];
}
%ctor {
    // Gives time to unlock, enter SpringBoard and open a Stheno window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ ShowReport(); });
}

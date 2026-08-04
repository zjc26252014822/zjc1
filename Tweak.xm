#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

static UIViewController *Top(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSString *Inspect(void) {
    NSMutableString *r = [NSMutableString string];
    Class direct = NSClassFromString(@"Stheno.SthenoWindow");
    [r appendFormat:@"Stheno.SthenoWindow: %@\n\n", direct ? @"FOUND" : @"NOT FOUND"];
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    [r appendString:@"Classes containing Stheno:\n"];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name rangeOfString:@"Stheno" options:NSCaseInsensitiveSearch].location != NSNotFound)
            [r appendFormat:@"%@\n", name];
    }
    free(classes);
    [r appendString:@"\nWindows:\n"];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            CGRect f = window.frame;
            [r appendFormat:@"%@ hidden=%d (%.0f,%.0f %.0fx%.0f)\n", NSStringFromClass(window.class), window.hidden, f.origin.x, f.origin.y, f.size.width, f.size.height];
        }
    }
    return r;
}

static UIWindow *FindWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (!window.hidden && window.rootViewController) return window;
    }
    return nil;
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *window = FindWindow();
        if (!window) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SthenoBounds diagnostics" message:Inspect() preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [Top(window.rootViewController) presentViewController:alert animated:YES completion:nil];
    });
}

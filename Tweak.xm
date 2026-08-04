#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static UIViewController *TopController(UIViewController *controller) {
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static void ShowLoadConfirmation(void) {
    UIWindow *target = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.rootViewController) { target = window; break; }
        }
        if (target) break;
    }
    if (!target) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SthenoBounds"
        message:@"Loaded into SpringBoard successfully."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [TopController(target.rootViewController) presentViewController:alert animated:YES completion:nil];
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ShowLoadConfirmation();
    });
}

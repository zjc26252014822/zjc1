#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdio.h>

static void Log(const char *f, ...) {
    int d = open("/var/mobile/Documents/SthenoBounds.trace", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (d < 0) return;
    char b[512]; va_list a; va_start(a, f);
    int n = vsnprintf(b, sizeof(b), f, a); va_end(a);
    if (n > 0) write(d, b, (size_t)(n < 511 ? n : 511));
    close(d);
}

%hook UIPanGestureRecognizer
- (CGPoint)translationInView:(UIView *)view {
    CGPoint p = %orig;
    NSString *sc = NSStringFromClass([self class]);
    UIView *gv = [self view];
    NSString *vc = gv ? NSStringFromClass([gv class]) : @"nil";
    Log("PAN cls=%@ view=%@ pt=(%.1f,%.1f) win=%@\n", sc, vc, p.x, p.y,
        [gv window] ? NSStringFromClass([[gv window] class]) : @"nil");
    return p;
}
%end

%hook UIView
- (void)setCenter:(CGPoint)center {
    %orig;
}
%end

__attribute__((constructor)) static void Init(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Log("uikit diag loaded\n");
}

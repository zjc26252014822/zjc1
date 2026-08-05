#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

// Stheno 边界观测版 v3.4.3-diag - 纯观测不干预
// 目标: 找出小窗本体 (类名 + 移动机制: frame/center/transform)
// 1. 每 2 秒 dump 所有 window 的类名/frame + 递归所有**非全屏** subview 类名/frame
// 2. hook setFrame:/setCenter:/setTransform: 记录 Stheno 相关 view 的变化
// 3. 只观测不改任何东西, 绝不崩溃

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

static IMP OrigSetFrame, OrigSetCenter, OrigSetTransform;
static NSUInteger obsCount;

static BOOL IsSthenoRelated(UIView *v) {
    Class c = object_getClass(v);
    if (!c) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    return strstr(n, "Stheno") || strstr(n, "Reflect");
}

static void DumpView(UIView *v, int depth) {
    if (!v || depth > 4) return;
    Class c = object_getClass(v);
    if (!c) return;
    const char *n = class_getName(c);
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect f = v.frame;
    // 记录: 所有 Stheno 相关 view + 所有非全屏 view
    BOOL stheno = strstr(n, "Stheno") || strstr(n, "Reflect");
    BOOL small = f.size.width > 20 && f.size.width < screen.size.width * 0.8 &&
                 f.size.height > 20 && f.size.height < screen.size.height * 0.8;
    if (stheno || small) {
        CGAffineTransform t = v.transform;
        obsCount++;
        Log("view[%lu] d%d %s frame=(%.0f,%.0f %.0fx%.0f) center=(%.0f,%.0f) tx=%.0f ty=%.0f hidden=%d alpha=%.1f%s\n",
            (unsigned long)obsCount, depth, n,
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            v.center.x, v.center.y, t.tx, t.ty,
            v.hidden ? 1 : 0, v.alpha,
            stheno ? " [STHENO]" : "");
    }
    for (UIView *sub in v.subviews) DumpView(sub, depth + 1);
}

static void DumpAll(void) {
    @try {
        NSMutableArray *allWindows = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [allWindows addObjectsFromArray:[(UIWindowScene *)scene windows]];
            }
        }
        Log("--- dump pass (windows=%lu) ---\n", (unsigned long)allWindows.count);
        for (UIWindow *w in allWindows) {
            Class c = object_getClass(w);
            const char *n = c ? class_getName(c) : "?";
            Log("window: %s frame=(%.0f,%.0f %.0fx%.0f) hidden=%d key=%d\n",
                n, w.frame.origin.x, w.frame.origin.y,
                w.frame.size.width, w.frame.size.height,
                w.hidden ? 1 : 0, w.isKeyWindow ? 1 : 0);
            DumpView(w, 0);
        }
    } @catch (NSException *e) {
        Log("dump exception: %@", e.name);
    }
}

@interface DumpTimer : NSObject @end
@implementation DumpTimer
- (void)fire:(NSTimer *)t { DumpAll(); }
@end

static void HookSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (IsSthenoRelated(self)) {
        Log("setFrame: %s (%.0f,%.0f %.0fx%.0f) -> (%.0f,%.0f %.0fx%.0f)\n",
            class_getName(object_getClass(self)),
            self.frame.origin.x, self.frame.origin.y, self.frame.size.width, self.frame.size.height,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    ((void(*)(id,SEL,CGRect))OrigSetFrame)(self, _cmd, frame);
}
static void HookSetCenter(UIView *self, SEL _cmd, CGPoint center) {
    if (IsSthenoRelated(self)) {
        Log("setCenter: %s (%.0f,%.0f) -> (%.0f,%.0f)\n",
            class_getName(object_getClass(self)),
            self.center.x, self.center.y, center.x, center.y);
    }
    ((void(*)(id,SEL,CGPoint))OrigSetCenter)(self, _cmd, center);
}
static void HookSetTransform(UIView *self, SEL _cmd, CGAffineTransform t) {
    if (IsSthenoRelated(self)) {
        Log("setTransform: %s tx=%.0f ty=%.0f\n",
            class_getName(object_getClass(self)), t.tx, t.ty);
    }
    ((void(*)(id,SEL,CGAffineTransform))OrigSetTransform)(self, _cmd, t);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class viewCls = UIView.class;
        MSHookMessageEx(viewCls, @selector(setFrame:), (IMP)HookSetFrame, &OrigSetFrame);
        MSHookMessageEx(viewCls, @selector(setCenter:), (IMP)HookSetCenter, &OrigSetCenter);
        MSHookMessageEx(viewCls, @selector(setTransform:), (IMP)HookSetTransform, &OrigSetTransform);
    });
    DumpTimer *dt = [DumpTimer new];
    NSTimer *t = [NSTimer timerWithTimeInterval:2.0 target:dt selector:@selector(fire:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    Log("SthenoBounds v3.4.3-diag loaded (observe only, no modification)\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DumpAll(); });
}

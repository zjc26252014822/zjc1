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

// 边界修复 v3.4.2 - 松手回弹方案
// 背景: v3.4.1 的 setFrame: hook 只夹到全屏宿主 (PlatformViewHost 430x932),
//       真正的小窗是 SwiftUI 内部 offset/transform 控制, 不走 setFrame:.
// 新策略:
//   1. hook UIPanGestureRecognizer -setState:, 手势 Ended 时延迟 0.15s 回弹
//   2. 遍历所有 UIWindow 的 view 树, 找类名含 SthenoWindow/Reflect 的**非全屏** view
//   3. 把它的 frame 拉回屏幕内贴边 (origin.x = 0 或 screen.width-width, y 避开状态栏)
//   4. 拖拽过程中完全不干预, 手感自由; 松手后自动回弹
//   5. 保留 setFrame: hook 做实时兜底 (全屏宿主放行)

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[512]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 511 ? n : 511));
    close(fd);
}

static IMP OrigSetFrame;
static IMP OrigPanSetState;
static NSUInteger snapCount;

static BOOL IsSthenoView(UIView *v) {
    Class c = object_getClass(v);
    if (!c) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    return strstr(n, "SthenoWindow") || strstr(n, "ReflectView") ||
           strstr(n, "ReflectStack") || strstr(n, "ReflectKeyboard");
}
// 接近全屏的 view (宿主容器) 跳过, 只处理真正的小窗
static BOOL IsFullscreenHost(UIView *v) {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect f = v.frame;
    if (v.superview) f = [v.superview convertRect:v.frame toView:nil];
    return f.size.width >= screen.size.width * 0.85 &&
           f.size.height >= screen.size.height * 0.85;
}

// 递归遍历 view 树, 把小窗 frame 拉回屏幕内贴边
static void SnapIn(UIView *v, int depth) {
    if (!v || depth > 8) return;
    if (IsSthenoView(v) && !IsFullscreenHost(v)) {
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect sf = v.superview ? [v.superview convertRect:v.frame toView:nil] : v.frame;
        if (isfinite(sf.origin.x) && isfinite(sf.origin.y) &&
            sf.size.width > 1 && sf.size.height > 1) {
            CGRect fixed = sf;
            // X: 贴边回弹 (完全回到屏幕内)
            if (fixed.origin.x < 0) fixed.origin.x = 0;
            if (fixed.origin.x + fixed.size.width > screen.size.width)
                fixed.origin.x = screen.size.width - fixed.size.width;
            // Y: 顶部避开状态栏(47), 底部贴屏幕下沿
            if (fixed.origin.y < 47) fixed.origin.y = 47;
            if (fixed.origin.y + fixed.size.height > screen.size.height)
                fixed.origin.y = screen.size.height - fixed.size.height;
            if (fixed.origin.y < 47) fixed.origin.y = 47;
            if (fixed.origin.x != sf.origin.x || fixed.origin.y != sf.origin.y) {
                CGRect newF = v.superview ? [v.superview convertRect:fixed fromView:nil] : fixed;
                snapCount++;
                Log("snap[%lu]: %s (%.0f,%.0f %.0fx%.0f) -> (%.0f,%.0f)\n",
                    (unsigned long)snapCount, class_getName(object_getClass(v)),
                    sf.origin.x, sf.origin.y, sf.size.width, sf.size.height,
                    fixed.origin.x, fixed.origin.y);
                v.frame = newF;
            }
        }
    }
    for (UIView *sub in v.subviews) SnapIn(sub, depth + 1);
}
static void SnapBackAll(void) {
    @try {
        // iOS 15+: UIApplication.windows deprecated, 用 UIWindowScene.windows
        NSMutableArray *allWindows = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [allWindows addObjectsFromArray:[(UIWindowScene *)scene windows]];
            }
        }
        for (UIWindow *w in allWindows) {
            SnapIn(w, 0);
        }
        Log("snap pass done (total=%lu)\n", (unsigned long)snapCount);
    } @catch (NSException *e) {
        Log("snap exception: %@", e.name);
    }
}
static void HookPanSetState(UIPanGestureRecognizer *self, SEL cmd, UIGestureRecognizerState state) {
    ((void(*)(id,SEL,UIGestureRecognizerState))OrigPanSetState)(self,cmd,state);
    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        // 等 Stheno 处理完手势的最终位置再回弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SnapBackAll(); });
    }
}
// 实时兜底: setFrame: 夹紧 (仅非全屏小窗), 保留
static void HookSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (IsSthenoView(self) && !IsFullscreenHost(self)) {
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect sf = self.superview ? [self.superview convertRect:frame toView:nil] : frame;
        if (isfinite(sf.origin.x) && isfinite(sf.origin.y)) {
            CGRect fixed = sf;
            if (fixed.origin.x < 0) fixed.origin.x = 0;
            if (fixed.origin.x + fixed.size.width > screen.size.width)
                fixed.origin.x = screen.size.width - fixed.size.width;
            if (fixed.origin.y < 47) fixed.origin.y = 47;
            if (fixed.origin.y + fixed.size.height > screen.size.height)
                fixed.origin.y = screen.size.height - fixed.size.height;
            if (fixed.origin.x != sf.origin.x || fixed.origin.y != sf.origin.y) {
                frame = self.superview ? [self.superview convertRect:fixed fromView:nil] : fixed;
            }
        }
    }
    ((void(*)(id,SEL,CGRect))OrigSetFrame)(self, _cmd, frame);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class panCls = UIPanGestureRecognizer.class;
        MSHookMessageEx(panCls, @selector(setState:), (IMP)HookPanSetState, &OrigPanSetState);
        Class viewCls = UIView.class;
        MSHookMessageEx(viewCls, @selector(setFrame:), (IMP)HookSetFrame, &OrigSetFrame);
    });
    Log("SthenoBounds v3.4.2 loaded (pan-end snap-back + setFrame fallback)\n");
}

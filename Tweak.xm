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

// 边界修复 v3.4.0 - 纯系统层方案 (不再碰 Stheno.dylib 代码)
// 背景: v3.2.0/v3.3.x hook Stheno.dylib 内部函数 (arm64e + Swift) 必崩。
//       崩溃 culprit 均为 000SthenoBounds.dylib, PC/LR 恒定 -> 同一处崩。
// 新策略:
//   1. hook 系统 UIView -setFrame: (UIKit 系统方法, MSHookMessageEx 安全)
//   2. 只对类名含 SthenoWindow/ReflectView/ReflectStackView/ReflectKeyboard 的 view 处理
//   3. 把将要设置的 frame 换算到屏幕坐标, 夹紧到屏幕内(至少 40pt 可见), 再转回
//   4. view 由 UIKit 持有必然存活, 无 UAF, 无 PAC 问题
//   5. 全路径日志 /var/mobile/Documents/SthenoBounds.log

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
static const CGFloat MinVisible = 40.0;   // 小窗至少保留 40pt 在屏幕内
static NSUInteger hookCalls, clampedCount, lastLogCount;

static BOOL IsSthenoView(UIView *v) {
    Class c = object_getClass(v);
    if (!c) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    return strstr(n, "SthenoWindow") || strstr(n, "ReflectView") ||
           strstr(n, "ReflectStack") || strstr(n, "ReflectKeyboard");
}

// 把 frame 换算到屏幕坐标并夹紧, 返回修正后的 superview 坐标 frame
static CGRect ClampedFrame(UIView *self, CGRect frame) {
    UIView *superview = self.superview;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect sf;  // 屏幕坐标 frame

    if (superview) {
        sf = [superview convertRect:frame toView:nil];
    } else {
        sf = frame;  // 顶层 window, frame 即屏幕坐标
    }
    // 防 NaN
    if (!isfinite(sf.origin.x) || !isfinite(sf.origin.y) ||
        !isfinite(sf.size.width) || !isfinite(sf.size.height)) return frame;
    if (sf.size.width < 1 || sf.size.height < 1) return frame;

    CGRect fixed = sf;
    // X: 保证至少 MinVisible 在屏幕内
    if (fixed.origin.x > screen.size.width - MinVisible)
        fixed.origin.x = screen.size.width - MinVisible;
    if (fixed.origin.x + fixed.size.width < MinVisible)
        fixed.origin.x = MinVisible - fixed.size.width;
    // Y: 顶部留状态栏空间, 底部留 home indicator
    if (fixed.origin.y < 47)
        fixed.origin.y = 47;
    if (fixed.origin.y > screen.size.height - 47 - MinVisible)
        fixed.origin.y = screen.size.height - 47 - MinVisible;
    if (fixed.origin.y + fixed.size.height < 47 + MinVisible)
        fixed.origin.y = 47 + MinVisible - fixed.size.height;
    // 屏幕坐标下界也夹一下 (避免拖到 -x)
    if (fixed.origin.x < -fixed.size.width + MinVisible)
        fixed.origin.x = -fixed.size.width + MinVisible;

    if (fixed.origin.x == sf.origin.x && fixed.origin.y == sf.origin.y)
        return frame;  // 无需修正

    // 转回 superview 坐标
    if (superview) {
        return [superview convertRect:fixed fromView:nil];
    }
    return fixed;
}

static void HookSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    hookCalls++;
    if (IsSthenoView(self)) {
        CGRect clamped = ClampedFrame(self, frame);
        if (!CGRectEqualToRect(clamped, frame)) {
            clampedCount++;
            if (clampedCount - lastLogCount >= 20 || clampedCount < 5) {
                lastLogCount = clampedCount;
                Log("clamp[%lu]: %s frame(%.0f,%.0f %.0fx%.0f) -> (%.0f,%.0f %.0fx%.0f)\n",
                    (unsigned long)clampedCount, class_getName(object_getClass(self)),
                    frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                    clamped.origin.x, clamped.origin.y, clamped.size.width, clamped.size.height);
            }
            frame = clamped;
        }
    }
    ((void(*)(id,SEL,CGRect))OrigSetFrame)(self, _cmd, frame);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UIView.class;
        MSHookMessageEx(cls, @selector(setFrame:), (IMP)HookSetFrame, &OrigSetFrame);
    });
    Log("SthenoBounds v3.4.0 loaded (UIView setFrame: hook, no Stheno code touched)\n");
}

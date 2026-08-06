#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

// Stheno v3.4.16 - 修复"全宽层被误杀"
// v3.4.15 证据: 用户拖的是全宽层 (430x114 / 430x74 / 430x932 宿主)
//   seen[40]: 430x74 sp=(252,939) 出屏但没被 SNAP -> 被"w>=90%屏"排除误杀!
//   seen[9]: 430x932 sp=(215,-466) 宿主被拖出屏 -> 也没处理
// 修复: 1) 排除条件改为 宽>=90% 且 高>=90% (全宽横条不再误杀)
//       2) 全屏宿主出屏时恢复到屏幕中心 (215,466)
//       3) 非全屏层 clamp 到屏幕边界贴边
// 关键: sp 用 convertPoint 到 root (v3.4.15 验证有效)

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

static const CGFloat TopInset = 47.0, BottomInset = 34.0;
static NSUInteger snapCount, passCount;

static BOOL HasSthenoAncestor(CALayer *layer, int depth) {
    if (!layer || depth > 12) return NO;
    id d = layer.delegate;
    if (d) {
        const char *n = class_getName(object_getClass(d));
        if (n && (strstr(n, "Stheno") || strstr(n, "Reflect"))) return YES;
    }
    const char *ln = class_getName(object_getClass(layer));
    if (ln && (strstr(ln, "PlatformViewHost") || strstr(ln, "UIHostingView") ||
               strstr(ln, "Stheno") || strstr(ln, "Reflect") || strstr(ln, "Material")))
        return YES;
    return HasSthenoAncestor(layer.superlayer, depth + 1);
}

static void ScanLayerTree(CALayer *layer, int depth, CGRect screen) {
    if (!layer || depth > 40) return;
    @try {
        if (HasSthenoAncestor(layer, 0)) {
            CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
            if (w < 20 || h < 20) { /* 极小层跳过 */ }
            else {
                CALayer *root = layer;
                while (root.superlayer) root = root.superlayer;
                CGPoint sp = layer.position;
                if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
                BOOL isFullscreen = (w >= screen.size.width * 0.9 && h >= screen.size.height * 0.9);
                BOOL changed = NO;
                CGPoint fixed = sp;
                if (isFullscreen) {
                    // 全屏宿主: 只有明显出屏才恢复到屏幕中心
                    CGFloat cx = screen.size.width / 2.0, cy = screen.size.height / 2.0;
                    if (fabs(sp.x - cx) > 20 || fabs(sp.y - cy) > 20) {
                        fixed = CGPointMake(cx, cy);
                        changed = YES;
                    }
                } else {
                    // 非全屏层: clamp 到屏幕内贴边
                    CGFloat hw = w / 2.0, hh = h / 2.0;
                    CGFloat minX = hw, maxX = screen.size.width - hw;
                    CGFloat minY = TopInset + hh, maxY = screen.size.height - BottomInset - hh;
                    if (minX > maxX) { minX = maxX = screen.size.width / 2.0; }
                    if (minY > maxY) { minY = maxY = screen.size.height / 2.0; }
                    CGFloat nx = MIN(MAX(sp.x, minX), maxX);
                    CGFloat ny = MIN(MAX(sp.y, minY), maxY);
                    if (nx != sp.x || ny != sp.y) {
                        fixed = CGPointMake(nx, ny);
                        changed = YES;
                    }
                }
                if (changed) {
                    CGPoint parentFixed = fixed;
                    if (layer.superlayer) parentFixed = [layer.superlayer convertPoint:fixed fromLayer:root];
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    layer.position = parentFixed;
                    [CATransaction commit];
                    snapCount++;
                    if (snapCount <= 40 || snapCount % 10 == 0) {
                        Log("SNAP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f) cls=%s%s\n",
                            (unsigned long)snapCount, w, h, sp.x, sp.y, fixed.x, fixed.y,
                            class_getName(object_getClass(layer)),
                            isFullscreen ? " [FULLSCREEN]" : "");
                    }
                }
            }
        }
        for (CALayer *sub in layer.sublayers) {
            ScanLayerTree(sub, depth + 1, screen);
        }
    } @catch (NSException *e) {
        Log("scan exception: %@\n", e.name);
    }
}

static void DoSnapBack(void) {
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        NSMutableArray *allWindows = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [allWindows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        for (UIWindow *w in allWindows) {
            ScanLayerTree(w.layer, 0, screen);
        }
        passCount++;
        Log("snap pass #%lu done (snap=%lu)\n", (unsigned long)passCount, (unsigned long)snapCount);
    } @catch (NSException *e) {
        Log("snap pass exception: %@\n", e.name);
    }
}

static IMP OrigSetState;
static BOOL pending;
static void HookSetState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    ((void(*)(id,SEL,NSInteger))OrigSetState)(self, _cmd, state);
    @try {
        if (state == UIGestureRecognizerStateEnded && !pending) {
            pending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ pending = NO; DoSnapBack(); });
        }
    } @catch (NSException *e) {}
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class gr = UIGestureRecognizer.class;
        MSHookMessageEx(gr, @selector(setState:), (IMP)HookSetState, &OrigSetState);
    });
    Log("SthenoBounds v3.4.16 loaded (fix full-width layers + fullscreen restore)\n");
}

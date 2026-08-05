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

// Stheno v3.4.15 诊断版 - 为什么扫描找不到 303x303 小窗层?
// v3.4.14: snap pass 上百次, 只有 61x30 小层被 SNAP, 303x303 从未被拉
// 调查: 1) 深度限制 12 -> 40  2) 记录扫描到的所有 Stheno 层(前60)  3) 记录 window 列表
//       4) 顺带 hook setPosition 记录拖动时 303x303 的移动 (前30) 对照

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
static NSUInteger snapCount, seenCount, winCount;
static BOOL winListLogged;

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

// 记录扫描到的每个 Stheno 层 (前 60 条), 并拉回出屏的
static void ScanLayerTree(CALayer *layer, int depth, CGRect screen) {
    if (!layer || depth > 40) return;
    @try {
        if (HasSthenoAncestor(layer, 0)) {
            CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
            seenCount++;
            if (seenCount <= 60) {
                CALayer *root = layer;
                while (root.superlayer) root = root.superlayer;
                CGPoint sp = layer.position;
                if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
                Log("seen[%lu]: d%d %.0fx%.0f sp=(%.0f,%.0f) pos=(%.0f,%.0f) cls=%s\n",
                    (unsigned long)seenCount, depth, w, h,
                    sp.x, sp.y,
                    layer.position.x, layer.position.y,
                    class_getName(object_getClass(layer)));
            }
            // 拉回: 中型层出屏才动
            if (w >= 30 && h >= 30 && w < screen.size.width * 0.9 && h < screen.size.height * 0.9) {
                CALayer *root = layer;
                while (root.superlayer) root = root.superlayer;
                CGPoint sp = layer.position;
                if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
                CGFloat hw = w / 2.0, hh = h / 2.0;
                CGFloat nx = MIN(MAX(sp.x, hw), screen.size.width - hw);
                CGFloat ny = MIN(MAX(sp.y, TopInset + hh), screen.size.height - BottomInset - hh);
                if (nx != sp.x || ny != sp.y) {
                    CGPoint fixed = sp;
                    if (layer.superlayer) fixed = [layer.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
                    else fixed = CGPointMake(nx, ny);
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    layer.position = fixed;
                    [CATransaction commit];
                    snapCount++;
                    if (snapCount <= 40 || snapCount % 10 == 0) {
                        Log("SNAP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f) cls=%s\n",
                            (unsigned long)snapCount, w, h, sp.x, sp.y, nx, ny,
                            class_getName(object_getClass(layer)));
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
        // 记录 window 列表 (只一次)
        if (!winListLogged) {
            for (UIWindow *w in allWindows) {
                winCount++;
                if (winCount <= 15) {
                    Log("win[%lu]: %s frame=(%.0f,%.0f %.0fx%.0f)\n",
                        (unsigned long)winCount,
                        class_getName(object_getClass(w)),
                        w.frame.origin.x, w.frame.origin.y,
                        w.frame.size.width, w.frame.size.height);
                }
            }
            winListLogged = YES;
        }
        for (UIWindow *w in allWindows) {
            ScanLayerTree(w.layer, 0, screen);
        }
        Log("snap pass done (seen=%lu snap=%lu)\n", (unsigned long)seenCount, (unsigned long)snapCount);
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

// 观测拖动时的 setPosition (前 30 条)
static IMP OrigSetPosition;
static NSUInteger obsCount;
static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    @try {
        if (HasSthenoAncestor(self, 0)) {
            CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
            if (w >= 100 && h >= 100 && w < 450 && h < 800 && obsCount < 30) {
                obsCount++;
                Log("drag[%lu]: %.0fx%.0f pos=(%.0f,%.0f) cls=%s\n",
                    (unsigned long)obsCount, w, h, pos.x, pos.y,
                    class_getName(object_getClass(self)));
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class gr = UIGestureRecognizer.class;
        MSHookMessageEx(gr, @selector(setState:), (IMP)HookSetState, &OrigSetState);
        Class lc = CALayer.class;
        MSHookMessageEx(lc, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
    });
    Log("SthenoBounds v3.4.15 loaded (diagnose: why scan misses 303x303)\n");
}

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

// Stheno v3.4.18 - 处理 transform 平移 (关键)
// 铁证: v3.4.15 seen[9] 430x932 sp=(215,-466) pos=(215,466)
//       position 没变但屏幕坐标变了 -> 移动靠 transform 平移, 不是 setPosition!
// v3.4.17 失败原因: 拉回 position 但 transform 平移还在 -> 视觉不动
// 方案: 1) 同时 hook setPosition 和 setTransform 收集移动层
//       2) SNAP 时: 清掉 transform 平移(m41/m42) + clamp position
//       3) 尺寸过滤放宽 60~900 (覆盖调整大小后的窗口)

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
static NSUInteger snapCount, movedSeen, tfSeen;
static NSHashTable *movedSet;
static BOOL dragging;

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

static BOOL IsWindowSize(CALayer *layer, CGRect screen) {
    CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
    if (w < 60 || h < 60) return NO;
    if (w >= screen.size.width * 0.9 && h >= screen.size.height * 0.9) return NO; // 全屏宿主
    return YES;
}

static void TrackLayer(CALayer *layer, const char *why) {
    if (!dragging) return;
    @try {
        if (!HasSthenoAncestor(layer, 0)) return;
        CGRect screen = UIScreen.mainScreen.bounds;
        if (!IsWindowSize(layer, screen)) return;
        if (![movedSet containsObject:layer]) {
            [movedSet addObject:layer];
            movedSeen++;
            if (movedSeen <= 25) {
                Log("tracked[%lu]: %.0fx%.0f cls=%s via %s\n",
                    (unsigned long)movedSeen,
                    layer.bounds.size.width, layer.bounds.size.height,
                    class_getName(object_getClass(layer)), why);
            }
        }
    } @catch (NSException *e) {}
}

static IMP OrigSetPosition;
static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    TrackLayer(self, "setPos");
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

static IMP OrigSetTransform;
static void HookSetTransform(CALayer *self, SEL _cmd, CATransform3D t) {
    @try {
        if (dragging && (t.m41 != 0 || t.m42 != 0) && HasSthenoAncestor(self, 0)) {
            CGRect screen = UIScreen.mainScreen.bounds;
            if (IsWindowSize(self, screen)) {
                if (![movedSet containsObject:self]) {
                    [movedSet addObject:self];
                    movedSeen++;
                    if (movedSeen <= 25) {
                        Log("tracked[%lu]: %.0fx%.0f cls=%s via setTransform tx=%.0f ty=%.0f\n",
                            (unsigned long)movedSeen,
                            self.bounds.size.width, self.bounds.size.height,
                            class_getName(object_getClass(self)), t.m41, t.m42);
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,CATransform3D))OrigSetTransform)(self, _cmd, t);
}

static void DoSnapBack(void) {
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        NSUInteger fixed = 0;
        for (CALayer *layer in movedSet) {
            if (!layer) continue;
            CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
            if (w < 20 || h < 20) continue;
            CALayer *root = layer;
            while (root.superlayer) root = root.superlayer;
            // 屏幕坐标 (convertPoint 已包含 transform)
            CGPoint sp = layer.position;
            if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
            // 加上 transform 平移 (convertPoint 可能不含 m41/m42 到 root 的完整链, 手动加)
            CATransform3D tf = layer.transform;
            CGFloat tx = tf.m41, ty = tf.m42;
            CGFloat hw = w / 2.0, hh = h / 2.0;
            CGFloat minX = hw, maxX = screen.size.width - hw;
            CGFloat minY = TopInset + hh, maxY = screen.size.height - BottomInset - hh;
            if (minX > maxX) { minX = maxX = screen.size.width / 2.0; }
            if (minY > maxY) { minY = maxY = screen.size.height / 2.0; }
            CGFloat nx = MIN(MAX(sp.x + tx, minX), maxX);
            CGFloat ny = MIN(MAX(sp.y + ty, minY), maxY);
            BOOL changed = (fabs((sp.x + tx) - nx) > 1.0 || fabs((sp.y + ty) - ny) > 1.0);
            if (changed) {
                // 目标: 屏幕坐标 (nx, ny). 清 transform 平移, 把位移折入 position
                CGPoint parentFixed = CGPointMake(sp.x, sp.y);
                if (layer.superlayer) {
                    parentFixed = [layer.superlayer convertPoint:CGPointMake(nx - tx, ny - ty) fromLayer:root];
                } else {
                    parentFixed = CGPointMake(nx - tx, ny - ty);
                }
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                layer.position = parentFixed;
                if (tf.m41 != 0 || tf.m42 != 0) {
                    CATransform3D clean = tf;
                    clean.m41 = 0; clean.m42 = 0;
                    layer.transform = clean;
                }
                [CATransaction commit];
                fixed++;
                snapCount++;
                if (snapCount <= 40 || snapCount % 10 == 0) {
                    Log("SNAP[%lu]: %.0fx%.0f screen=(%.0f,%.0f) -> (%.0f,%.0f) tx=%.0f ty=%.0f cls=%s\n",
                        (unsigned long)snapCount, w, h,
                        sp.x + tx, sp.y + ty, nx, ny, tx, ty,
                        class_getName(object_getClass(layer)));
                }
            }
        }
        [movedSet removeAllObjects];
        Log("snap done: fixed=%lu tracked_total=%lu\n", (unsigned long)fixed, (unsigned long)movedSeen);
    } @catch (NSException *e) {
        Log("snap exception: %@\n", e.name);
    }
}

static IMP OrigSetState;
static BOOL pending;
static void HookSetState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    @try {
        if (state == UIGestureRecognizerStateBegan) {
            dragging = YES;
        } else if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled) {
            dragging = NO;
            if (!pending) {
                pending = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ pending = NO; DoSnapBack(); });
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,NSInteger))OrigSetState)(self, _cmd, state);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        movedSet = [NSHashTable weakObjectsHashTable];
        Class gr = UIGestureRecognizer.class;
        MSHookMessageEx(gr, @selector(setState:), (IMP)HookSetState, &OrigSetState);
        Class lc = CALayer.class;
        MSHookMessageEx(lc, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
        MSHookMessageEx(lc, @selector(setTransform:), (IMP)HookSetTransform, &OrigSetTransform);
    });
    Log("SthenoBounds v3.4.18 loaded (transform-aware snap)\n");
}

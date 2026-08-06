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

// Stheno v3.4.17 - 只夹"被拖动过"的层 (精准方案)
// v3.4.16 问题: 误伤正常 UI (401x80 工具栏在边缘被反复拉) + 拉的层不是用户拖的小窗
// 方案: 1) setPosition hook 记录"最近移动过"的 Stheno 层 (NSHashTable weak)
//       2) 手势 Changed 期间持续收集
//       3) Ended 后 0.4s 只扫描 movedSet, 出屏的拉回屏幕内
//       4) 静止层(工具栏/宿主)从不入 set, 不被误伤
// 边界: 小窗尺寸 100~500 宽 100~900 高; 排除全屏层

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
static NSUInteger snapCount, movedSeen;
static NSHashTable *movedSet;   // weak 引用被拖过的层
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

// setPosition hook: 拖动期间收集移动的 Stheno 层
static IMP OrigSetPosition;
static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    @try {
        if (dragging && HasSthenoAncestor(self, 0)) {
            CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
            // 小窗尺寸范围, 排除全屏层和极小层
            if (w >= 60 && w <= 520 && h >= 60 && h <= 900) {
                if (![movedSet containsObject:self]) {
                    [movedSet addObject:self];
                    movedSeen++;
                    if (movedSeen <= 20) {
                        Log("tracked[%lu]: %.0fx%.0f cls=%s\n",
                            (unsigned long)movedSeen, w, h,
                            class_getName(object_getClass(self)));
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
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
            CGPoint sp = layer.position;
            if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
            CGFloat hw = w / 2.0, hh = h / 2.0;
            CGFloat minX = hw, maxX = screen.size.width - hw;
            CGFloat minY = TopInset + hh, maxY = screen.size.height - BottomInset - hh;
            if (minX > maxX) { minX = maxX = screen.size.width / 2.0; }
            if (minY > maxY) { minY = maxY = screen.size.height / 2.0; }
            CGFloat nx = MIN(MAX(sp.x, minX), maxX);
            CGFloat ny = MIN(MAX(sp.y, minY), maxY);
            if (fabs(nx - sp.x) > 1.0 || fabs(ny - sp.y) > 1.0) {
                CGPoint parentFixed = sp;
                if (layer.superlayer) parentFixed = [layer.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                layer.position = parentFixed;
                [CATransaction commit];
                fixed++;
                snapCount++;
                if (snapCount <= 40 || snapCount % 10 == 0) {
                    Log("SNAP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f) cls=%s\n",
                        (unsigned long)snapCount, w, h, sp.x, sp.y, nx, ny,
                        class_getName(object_getClass(layer)));
                }
            }
        }
        // 清空集合, 等待下次拖动
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
    });
    Log("SthenoBounds v3.4.17 loaded (track moved layers only)\n");
}

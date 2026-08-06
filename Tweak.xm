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

// Stheno v3.4.19 - 持续夹 2 秒对抗 SwiftUI 写回
// v3.4.18 证据: tx=0 ty=0 (无 transform), SNAP 拉回后 SwiftUI 又写回 -> fixed=0
// 真相: SwiftUI 数据驱动渲染, layer position 是渲染结果, 拉一次会被下一帧覆盖
// 方案: 松手后 2 秒内每 0.15s 强制夹一次 (对抗每帧写回), 且拉回时检查祖先链
//       (视觉主体可能是父层, 不只 303x303 子层)

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
static NSUInteger snapCount;
static NSHashTable *movedSet;
static BOOL dragging;
static int clampRounds;      // 已执行的夹紧轮次
static const int MaxRounds = 14;   // 2.1s / 0.15s
static BOOL snapActive;

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
    if (w >= screen.size.width * 0.9 && h >= screen.size.height * 0.9) return NO;
    return YES;
}

static IMP OrigSetPosition;
static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    @try {
        if (dragging && HasSthenoAncestor(self, 0)) {
            CGRect screen = UIScreen.mainScreen.bounds;
            if (IsWindowSize(self, screen)) {
                [movedSet addObject:self];
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

// 检查并拉回一个层 (返回是否修正)
static BOOL FixLayer(CALayer *layer, CGRect screen, NSUInteger *outCount) {
    if (!layer) return NO;
    CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
    if (w < 20 || h < 20) return NO;
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
        (*outCount)++;
        snapCount++;
        if (snapCount <= 40 || snapCount % 10 == 0) {
            Log("SNAP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f) cls=%s\n",
                (unsigned long)snapCount, w, h, sp.x, sp.y, nx, ny,
                class_getName(object_getClass(layer)));
        }
        return YES;
    }
    return NO;
}

static void ClampRound(void) {
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        NSUInteger fixed = 0;
        // 复制集合快照 (避免遍历中修改)
        NSArray *snapshot = [movedSet allObjects];
        for (CALayer *layer in snapshot) {
            if (!layer) continue;
            // 拉回层本身
            FixLayer(layer, screen, &fixed);
            // 同时检查祖先链 (视觉主体可能是父层)
            CALayer *anc = layer.superlayer;
            int depth = 0;
            while (anc && depth < 6) {
                if (HasSthenoAncestor(anc, 0)) {
                    if (FixLayer(anc, screen, &fixed)) break;
                }
                anc = anc.superlayer;
                depth++;
            }
        }
        clampRounds++;
        Log("clamp round %d/%d done (fixed=%lu)\n", clampRounds, MaxRounds, (unsigned long)fixed);
        if (clampRounds >= MaxRounds) {
            snapActive = NO;
            [movedSet removeAllObjects];
            Log("clamp finished, set cleared\n");
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ClampRound(); });
        }
    } @catch (NSException *e) {
        Log("clamp exception: %@\n", e.name);
        snapActive = NO;
    }
}

static IMP OrigSetState;
static void HookSetState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    @try {
        if (state == UIGestureRecognizerStateBegan) {
            dragging = YES;
        } else if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled) {
            dragging = NO;
            if (!snapActive) {
                snapActive = YES;
                clampRounds = 0;
                // 先等 0.3s (等 SwiftUI 惯性/动画初步稳定), 再开始持续夹
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (snapActive) ClampRound();
                });
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
    Log("SthenoBounds v3.4.19 loaded (persistent clamp 2s)\n");
}

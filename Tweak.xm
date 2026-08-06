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

// Stheno v3.4.20 - CADisplayLink 常驻每帧夹
// 铁证: v3.4.19 持续夹 2 秒期间每轮都拉回(fixed>0), 停手后 SwiftUI 又写回
// 真相: Stheno offset 状态就是出屏的, layer 只是渲染结果
// 方案: CADisplayLink 常驻每帧检查, 只要出屏就拉回, 永不超时
//       拖动中暂停夹, 松手恢复夹 -> 拖动自由, 松手即钉住

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
static CADisplayLink *dlLink;
static id linkTarget;

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
        if (HasSthenoAncestor(self, 0)) {
            CGRect screen = UIScreen.mainScreen.bounds;
            if (IsWindowSize(self, screen)) {
                [movedSet addObject:self];
            }
        }
    } @catch (NSException *e) {}
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

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
        if (snapCount <= 30 || snapCount % 20 == 0) {
            Log("SNAP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f) cls=%s\n",
                (unsigned long)snapCount, w, h, sp.x, sp.y, nx, ny,
                class_getName(object_getClass(layer)));
        }
        return YES;
    }
    return NO;
}

static void TickFunc(void) {
    if (dragging) return;
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        NSUInteger fixed = 0;
        NSArray *snapshot = [movedSet allObjects];
        for (CALayer *layer in snapshot) {
            if (!layer) continue;
            FixLayer(layer, screen, &fixed);
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
    } @catch (NSException *e) {
        Log("tick exception: %@\n", e.name);
    }
}

// CADisplayLink target
@interface SBLinkTarget : NSObject @end
@implementation SBLinkTarget
- (void)tick { TickFunc(); }
@end

static IMP OrigSetState;
static void HookSetState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    @try {
        if (state == UIGestureRecognizerStateBegan) {
            dragging = YES;
        } else if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled) {
            dragging = NO;
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
        linkTarget = [[SBLinkTarget alloc] init];
        dlLink = [CADisplayLink displayLinkWithTarget:linkTarget selector:@selector(tick)];
        [dlLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    Log("SthenoBounds v3.4.20 loaded (CADisplayLink persistent clamp)\n");
}

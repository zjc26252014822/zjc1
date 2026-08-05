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

// Stheno v3.4.14 - 松手回弹方案 (关键转折)
// 证据: v3.4.13 实时夹 position 无效 - SwiftUI 每帧重写 position (CLAMP 反复出现同值 sp=455)
//       = 数据驱动渲染覆盖我们的修改
// 方案: 放弃实时夹, 改为 UIPanGestureRecognizer 手势结束(Ended)后延迟 0.25s,
//       扫描所有 Stheno 层, 把出屏的小窗 (MTMaterialLayer 303x303 / 内容层) 拉回屏幕内贴边
//       手势结束后 SwiftUI 不再写入 -> 一次生效不可覆盖
// 小窗本体: MTMaterialLayer (303x303 毛玻璃) + CALayer (303x303 bounds, transform 内容层)

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
static BOOL snapPending;

static BOOL HasSthenoAncestor(CALayer *layer, int depth) {
    if (!layer || depth > 10) return NO;
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

// 把一个层的屏幕位置拉回屏幕内 (贴边)
static void SnapLayerIn(CALayer *layer, CGRect screen) {
    @try {
        CGFloat w = layer.bounds.size.width, h = layer.bounds.size.height;
        // 只处理中型层 (小窗 30~420), 排除全屏层和小图标
        if (w < 30 || h < 30) return;
        if (w >= screen.size.width * 0.9 || h >= screen.size.height * 0.9) return;
        CALayer *root = layer;
        while (root.superlayer) root = root.superlayer;
        CGPoint sp = layer.position;
        if (layer.superlayer) sp = [layer.superlayer convertPoint:layer.position toLayer:root];
        CGFloat hw = w / 2.0, hh = h / 2.0;
        CGFloat minX = hw, maxX = screen.size.width - hw;
        CGFloat minY = TopInset + hh, maxY = screen.size.height - BottomInset - hh;
        CGFloat nx = MIN(MAX(sp.x, minX), maxX);
        CGFloat ny = MIN(MAX(sp.y, minY), maxY);
        if (nx != sp.x || ny != sp.y) {
            CGPoint fixed = sp;
            if (layer.superlayer) fixed = [layer.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
            else fixed = CGPointMake(nx, ny);
            // 禁动画直接设置, 防止被隐式动画干扰
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
    } @catch (NSException *e) {
        Log("snap exception: %@\n", e.name);
    }
}

static void ScanLayerTree(CALayer *layer, int depth, CGRect screen) {
    if (!layer || depth > 12) return;
    SnapLayerIn(layer, screen);
    for (CALayer *sub in layer.sublayers) {
        ScanLayerTree(sub, depth + 1, screen);
    }
}

static void DoSnapBack(void) {
    snapPending = NO;
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        // iOS 15+: UIWindowScene.windows
        NSMutableArray *allWindows = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [allWindows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        for (UIWindow *w in allWindows) {
            ScanLayerTree(w.layer, 0, screen);
        }
        Log("snap pass done\n");
    } @catch (NSException *e) {
        Log("snap pass exception: %@\n", e.name);
    }
}

static IMP OrigSetState;
static void HookSetState(UIGestureRecognizer *self, SEL _cmd, UIGestureRecognizerState state) {
    ((void(*)(id,SEL,NSInteger))OrigSetState)(self, _cmd, state);
    @try {
        if (state == UIGestureRecognizerStateEnded && !snapPending) {
            snapPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ DoSnapBack(); });
        }
    } @catch (NSException *e) {}
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class gr = UIGestureRecognizer.class;
        MSHookMessageEx(gr, @selector(setState:), (IMP)HookSetState, &OrigSetState);
    });
    Log("SthenoBounds v3.4.14 loaded (snap-back on gesture end)\n");
}

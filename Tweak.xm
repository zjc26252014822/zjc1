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

// Stheno v3.4.13 - 位置出屏才夹 + 完整观测
// 问题: v3.4.12 夹 303x303 但小窗照样拖出 -> 303x303 不是视觉主体
//       v3.4.8 观测到 344x746 被拖出屏, 但 v3.4.10-12 没夹到它
//       (setPosition 时 bounds 可能为 0, 尺寸判断失效)
// 方案: 1) 不依赖尺寸判断, 用"位置出屏"判断 (屏幕坐标超出边界即夹)
//       2) 排除全屏层(>=90%屏) 和 极小层(<30)
//       3) 记录所有 Stheno 祖先层 setPosition (前100条), 确认谁是视觉主体

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

static IMP OrigSetPosition;
static NSUInteger clampCount, obsCount;
static const CGFloat TopInset = 47.0, BottomInset = 34.0;

static BOOL HasSthenoAncestor(CALayer *layer, int depth) {
    if (!layer || depth > 10) return NO;
    id d = layer.delegate;
    if (d) {
        const char *n = class_getName(object_getClass(d));
        if (n && (strstr(n, "Stheno") || strstr(n, "Reflect"))) return YES;
    }
    const char *ln = class_getName(object_getClass(layer));
    if (ln && (strstr(ln, "PlatformViewHost") || strstr(ln, "UIHostingView") ||
               strstr(ln, "Stheno") || strstr(ln, "Reflect")))
        return YES;
    return HasSthenoAncestor(layer.superlayer, depth + 1);
}

static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    CGPoint newPos = pos;
    @try {
        if (!HasSthenoAncestor(self, 0)) {
            ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
            return;
        }
        CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
        CGRect screen = UIScreen.mainScreen.bounds;
        // 排除全屏层 (>=90% 屏) 和极小层 (<30)
        if (w >= screen.size.width * 0.9 || h >= screen.size.height * 0.9 || w < 30 || h < 30) {
            ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
            return;
        }
        // 观测: 记录前 100 条 (含尺寸/位置/是否出屏)
        obsCount++;
        if (obsCount <= 100) {
            Log("obs[%lu]: %.0fx%.0f pos=(%.0f,%.0f) frame=(%.0f,%.0f %.0fx%.0f) cls=%s\n",
                (unsigned long)obsCount, w, h,
                pos.x, pos.y,
                self.frame.origin.x, self.frame.origin.y,
                self.frame.size.width, self.frame.size.height,
                class_getName(object_getClass(self)));
        }
        // 屏幕坐标 (转 root; 失败则用 pos)
        CALayer *root = self;
        while (root.superlayer) root = root.superlayer;
        CGPoint sp = pos;
        if (self.superlayer) sp = [self.superlayer convertPoint:pos toLayer:root];
        // 位置出屏才夹: 中心点超出 [half, screen-half] 范围
        CGFloat hw = w / 2.0, hh = h / 2.0;
        CGFloat minX = hw, maxX = screen.size.width - hw;
        CGFloat minY = TopInset + hh, maxY = screen.size.height - BottomInset - hh;
        CGFloat nx = MIN(MAX(sp.x, minX), maxX);
        CGFloat ny = MIN(MAX(sp.y, minY), maxY);
        if (nx != sp.x || ny != sp.y) {
            CGPoint fixed = sp;
            if (self.superlayer) fixed = [self.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
            else fixed = CGPointMake(nx, ny);
            clampCount++;
            if (clampCount <= 60 || clampCount % 10 == 0) {
                Log("CLAMP[%lu]: %.0fx%.0f sp=(%.0f,%.0f) -> (%.0f,%.0f)\n",
                    (unsigned long)clampCount, w, h, sp.x, sp.y, nx, ny);
            }
            newPos = fixed;
        }
    } @catch (NSException *e) {
        Log("clamp exception: %@\n", e.name);
    }
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, newPos);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class layerCls = CALayer.class;
        MSHookMessageEx(layerCls, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
    });
    Log("SthenoBounds v3.4.13 loaded (position-out-of-screen clamp + full observe)\n");
}

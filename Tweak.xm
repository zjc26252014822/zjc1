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

// Stheno 边界修复 v3.4.11 - 屏幕坐标 clamp
// v3.4.10 失败: 只夹到 303x303 装饰层; 用户拖的 344x746 内容层没被夹
// 关键修正: 1) position 转屏幕坐标再 clamp (父层可能有偏移/transform, 直接夹 pos 基准错)
//           2) 任何尺寸的 Stheno 层都处理 (> 30pt, 过滤小图标), 不卡 150-420
//           3) 顺带观测: 记录所有 Stheno 层 setPosition (前60条), 确认到底谁在动

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
static NSUInteger clampCount, observeCount;
static const CGFloat TopInset = 47.0, BottomInset = 34.0, SideInset = 0.0;

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
        CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
        if (HasSthenoAncestor(self, 0) && w >= 30 && h >= 30) {
            // 观测: 前 60 条记录谁在动
            observeCount++;
            if (observeCount <= 60) {
                Log("obs[%lu]: %.0fx%.0f pos=(%.0f,%.0f) frame=(%.0f,%.0f)\n",
                    (unsigned long)observeCount, w, h,
                    pos.x, pos.y,
                    self.frame.origin.x, self.frame.origin.y);
            }
            // 转屏幕坐标: pos 是父坐标系, 向上转换到 root layer
            CALayer *root = self;
            while (root.superlayer) root = root.superlayer;
            CGPoint screenPos = pos;
            if (self.superlayer) {
                screenPos = [self.superlayer convertPoint:pos toLayer:root];
            }
            CGRect screen = UIScreen.mainScreen.bounds;
            CGFloat halfW = w / 2.0, halfH = h / 2.0;
            CGFloat minX = SideInset + halfW;
            CGFloat maxX = screen.size.width - SideInset - halfW;
            CGFloat minY = TopInset + halfH;
            CGFloat maxY = screen.size.height - BottomInset - halfH;
            CGFloat nx = MIN(MAX(screenPos.x, minX), maxX);
            CGFloat ny = MIN(MAX(screenPos.y, minY), maxY);
            if (nx != screenPos.x || ny != screenPos.y) {
                // 转回父坐标系
                CGPoint fixedParent = screenPos;
                if (self.superlayer) {
                    fixedParent = [self.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
                } else {
                    fixedParent = CGPointMake(nx, ny);
                }
                clampCount++;
                if (clampCount <= 60 || clampCount % 10 == 0) {
                    Log("CLAMP[%lu]: %.0fx%.0f screenPos=(%.0f,%.0f) -> (%.0f,%.0f) [screen %.0fx%.0f]\n",
                        (unsigned long)clampCount, w, h,
                        screenPos.x, screenPos.y, nx, ny,
                        screen.size.width, screen.size.height);
                }
                newPos = fixedParent;
            }
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
    Log("SthenoBounds v3.4.11 loaded (screen-coord clamp, all sizes)\n");
}

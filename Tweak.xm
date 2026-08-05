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

// Stheno v3.4.12 - 修复黑框 + offsetFilter 观测
// 1) 修复 v3.4.11: 全屏宿主(430x932)被误夹 -> 硬性排除 >=90% 屏幕的层
// 2) 观测 ReflectManager -offsetFilter (挂起模式的边界入口, v3.4.5/6 没测到因为当时没挂起)
// 3) 只夹中型层 (100~420) 的小窗内容层

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
static NSUInteger clampCount;

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
        CGRect screen = UIScreen.mainScreen.bounds;
        // 硬性排除全屏宿主: >=90% 屏幕尺寸绝对不碰 (修复 v3.4.11 黑框)
        if (w >= screen.size.width * 0.9 || h >= screen.size.height * 0.9) {
            ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
            return;
        }
        // 只夹中型层 (小窗内容层 100~420)
        if (HasSthenoAncestor(self, 0) && w >= 100 && w <= 420 && h >= 100 && h <= 420) {
            CALayer *root = self;
            while (root.superlayer) root = root.superlayer;
            CGPoint screenPos = pos;
            if (self.superlayer) screenPos = [self.superlayer convertPoint:pos toLayer:root];
            CGFloat halfW = w / 2.0, halfH = h / 2.0;
            CGFloat minX = halfW, maxX = screen.size.width - halfW;
            CGFloat minY = 47.0 + halfH, maxY = screen.size.height - 34.0 - halfH;
            CGFloat nx = MIN(MAX(screenPos.x, minX), maxX);
            CGFloat ny = MIN(MAX(screenPos.y, minY), maxY);
            if (nx != screenPos.x || ny != screenPos.y) {
                CGPoint fixedParent = screenPos;
                if (self.superlayer) fixedParent = [self.superlayer convertPoint:CGPointMake(nx, ny) fromLayer:root];
                else fixedParent = CGPointMake(nx, ny);
                clampCount++;
                if (clampCount <= 40 || clampCount % 10 == 0) {
                    Log("CLAMP[%lu]: %.0fx%.0f screenPos=(%.0f,%.0f) -> (%.0f,%.0f)\n",
                        (unsigned long)clampCount, w, h,
                        screenPos.x, screenPos.y, nx, ny);
                }
                newPos = fixedParent;
            }
        }
    } @catch (NSException *e) {
        Log("clamp exception: %@\n", e.name);
    }
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, newPos);
}

// ---- offsetFilter 观测 (挂起模式边界入口) ----
typedef struct { double a, b; } Ret16;
static Ret16 (*OrigOffsetFilter)(id, SEL);
static NSUInteger offsetCalls;
static BOOL typeLogged;

static Ret16 HookOffsetFilter(id self, SEL _cmd) {
    if (!typeLogged) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        if (m) {
            char *t = method_copyReturnType(m);
            Log("offsetFilter return type encoding: %s\n", t ? t : "?");
            if (t) free(t);
        }
        typeLogged = YES;
    }
    Ret16 r = OrigOffsetFilter(self, _cmd);
    offsetCalls++;
    if (offsetCalls <= 50 || offsetCalls % 20 == 0) {
        Log("offsetFilter[%lu]: x=%.1f y=%.1f\n", (unsigned long)offsetCalls, r.a, r.b);
    }
    return r;
}

static void TryHookOffsetFilter(void) {
    static int attempt = 0;
    const char *names[] = {"_TtC6Stheno14ReflectManager", "Stheno.ReflectManager", NULL};
    for (int i = 0; names[i]; i++) {
        Class cls = NSClassFromString([NSString stringWithUTF8String:names[i]]);
        if (!cls) continue;
        SEL sel = NSSelectorFromString(@"offsetFilter");
        if (sel && [cls instancesRespondToSelector:sel]) {
            if (OrigOffsetFilter == NULL) {
                MSHookMessageEx(cls, sel, (IMP)HookOffsetFilter, (IMP *)&OrigOffsetFilter);
                Log("HOOKED offsetFilter (attempt %d)\n", attempt);
            }
            return;
        }
    }
    attempt++;
    if (attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ TryHookOffsetFilter(); });
    }
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class layerCls = CALayer.class;
        MSHookMessageEx(layerCls, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
    });
    Log("SthenoBounds v3.4.12 loaded (fix black frame + offsetFilter observe)\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TryHookOffsetFilter(); });
}

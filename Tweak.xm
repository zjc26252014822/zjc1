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

// Stheno 观测版 v3.4.7 - hook CALayer 层 (SwiftUI offset 最终落地为 layer position/transform)
// 发现: ReflectView/MaterialView 303x303 = 小窗本体, 但 UIView setFrame/setBounds 抓不到移动
//       (SwiftUI 渲染在 CALayer 层). 这是所有渲染必经之路.

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

static IMP OrigSetPosition, OrigSetTransform, OrigSetBounds;
static NSUInteger posCalls, tfCalls, bndCalls;
static NSUInteger sthenoPosCalls;

// layer 的 delegate 是否为 Stheno/Reflect 相关 view
static BOOL IsSthenoLayer(CALayer *layer) {
    id d = layer.delegate;
    if (!d) return NO;
    const char *n = class_getName(object_getClass(d));
    if (!n) return NO;
    return strstr(n, "Stheno") || strstr(n, "Reflect") || strstr(n, "Material") ||
           strstr(n, "PlatformViewHost") || strstr(n, "Container");
}

static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    BOOL stheno = IsSthenoLayer(self);
    if (stheno) {
        sthenoPosCalls++;
        if (sthenoPosCalls <= 40 || sthenoPosCalls % 20 == 0) {
            Log("layerPos[%lu]: %s pos=(%.0f,%.0f) frame=(%.0f,%.0f %.0fx%.0f)\n",
                (unsigned long)sthenoPosCalls,
                class_getName(object_getClass(self.delegate)),
                pos.x, pos.y,
                self.frame.origin.x, self.frame.origin.y,
                self.frame.size.width, self.frame.size.height);
        }
    } else {
        posCalls++;
        if (posCalls <= 5) {
            Log("layerPos[%lu]: generic %s pos=(%.0f,%.0f)\n",
                (unsigned long)posCalls,
                self.delegate ? class_getName(object_getClass(self.delegate)) : "no-delegate",
                pos.x, pos.y);
        }
    }
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

static void HookSetTransform(CALayer *self, SEL _cmd, CATransform3D t) {
    BOOL stheno = IsSthenoLayer(self);
    BOOL nonIdentity = !CATransform3DIsIdentity(t);
    if (stheno && nonIdentity) {
        tfCalls++;
        if (tfCalls <= 40) {
            Log("layerTf[%lu]: %s tx=%.1f ty=%.1f\n",
                (unsigned long)tfCalls,
                class_getName(object_getClass(self.delegate)),
                t.m41, t.m42);
        }
    } else if (stheno) {
        tfCalls++;
        if (tfCalls <= 10) {
            Log("layerTf[%lu]: %s identity\n",
                (unsigned long)tfCalls,
                class_getName(object_getClass(self.delegate)));
        }
    }
    ((void(*)(id,SEL,CATransform3D))OrigSetTransform)(self, _cmd, t);
}

static void HookSetBounds(CALayer *self, SEL _cmd, CGRect bounds) {
    BOOL stheno = IsSthenoLayer(self);
    if (stheno) {
        bndCalls++;
        if (bndCalls <= 30 || bndCalls % 20 == 0) {
            Log("layerBnd[%lu]: %s origin=(%.0f,%.0f) size=(%.0fx%.0f)\n",
                (unsigned long)bndCalls,
                class_getName(object_getClass(self.delegate)),
                bounds.origin.x, bounds.origin.y,
                bounds.size.width, bounds.size.height);
        }
    }
    ((void(*)(id,SEL,CGRect))OrigSetBounds)(self, _cmd, bounds);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class layerCls = CALayer.class;
        MSHookMessageEx(layerCls, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
        MSHookMessageEx(layerCls, @selector(setTransform:), (IMP)HookSetTransform, &OrigSetTransform);
        MSHookMessageEx(layerCls, @selector(setBounds:), (IMP)HookSetBounds, &OrigSetBounds);
    });
    Log("SthenoBounds v3.4.7 loaded (CALayer observe)\n");
}

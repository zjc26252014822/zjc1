#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

// Stheno 观测版 v3.4.4 - 枚举 ReflectManager 方法 + hook setBounds:
// 发现: 小窗是 SwiftUI 渲染, 不走 UIView frame/center/transform
// 新观测: 1) setBounds: (SwiftUI offset 可能改 bounds.origin)
//         2) 枚举 Stheno/Reflect 类的全部 ObjC 方法名 (找出位置相关 selector)

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

static IMP OrigSetBounds, OrigSetFrame, OrigSetCenter, OrigSetTransform;

static BOOL IsSthenoRelated(UIView *v) {
    Class c = object_getClass(v);
    if (!c) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    return strstr(n, "Stheno") || strstr(n, "Reflect") || strstr(n, "PlatformViewHost");
}

static void HookSetBounds(UIView *self, SEL _cmd, CGRect bounds) {
    if (IsSthenoRelated(self)) {
        Log("setBounds: %s origin=(%.0f,%.0f) size=(%.0fx%.0f) frame=(%.0f,%.0f)\n",
            class_getName(object_getClass(self)),
            bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
            self.frame.origin.x, self.frame.origin.y);
    }
    ((void(*)(id,SEL,CGRect))OrigSetBounds)(self, _cmd, bounds);
}
static void HookSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (IsSthenoRelated(self)) {
        Log("setFrame: %s (%.0f,%.0f %.0fx%.0f)\n",
            class_getName(object_getClass(self)),
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    ((void(*)(id,SEL,CGRect))OrigSetFrame)(self, _cmd, frame);
}
static void HookSetCenter(UIView *self, SEL _cmd, CGPoint center) {
    if (IsSthenoRelated(self)) {
        Log("setCenter: %s (%.0f,%.0f)\n",
            class_getName(object_getClass(self)), center.x, center.y);
    }
    ((void(*)(id,SEL,CGPoint))OrigSetCenter)(self, _cmd, center);
}
static void HookSetTransform(UIView *self, SEL _cmd, CGAffineTransform t) {
    if (IsSthenoRelated(self)) {
        Log("setTransform: %s tx=%.0f ty=%.0f\n",
            class_getName(object_getClass(self)), t.tx, t.ty);
    }
    ((void(*)(id,SEL,CGAffineTransform))OrigSetTransform)(self, _cmd, t);
}

// 枚举一个类的全部方法 (含父类), 打印 selector
static void DumpMethods(const char *label, Class cls) {
    if (!cls) { Log("class %s: NOT FOUND\n", label); return; }
    Log("class %s: %s found, methods:\n", label, class_getName(cls));
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count && i < 200; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (name) Log("  -%s\n", name);
    }
    if (methods) free(methods);
    // 类方法
    unsigned int ccount = 0;
    Method *cms = class_copyMethodList(object_getClass(cls), &ccount);
    for (unsigned int i = 0; i < ccount && i < 100; i++) {
        SEL sel = method_getName(cms[i]);
        const char *name = sel_getName(sel);
        if (name) Log("  +%s\n", name);
    }
    if (cms) free(cms);
}

static void FindAllSthenoClasses(void) {
    Log("--- enumerate known Stheno classes ---\n");
    // 尝试各种可能的类名 (Swift 类名带模块前缀或混淆)
    const char *names[] = {
        "_TtC6Stheno14ReflectManager",
        "Stheno.ReflectManager",
        "ReflectManager",
        "_TtC6Stheno12SthenoWindow",
        "Stheno.SthenoWindow",
        "SthenoWindow",
        "_TtC6Stheno11ReflectView",
        "Stheno.ReflectView",
        "ReflectView",
        "ReflectStackView",
        "Stheno.ReflectStackView",
        "ReflectKeyboardView",
        "Stheno.ReflectKeyboardView",
        "SthenoController",
        "Stheno.SthenoController",
        NULL
    };
    for (int i = 0; names[i]; i++) {
        Class c = NSClassFromString([NSString stringWithUTF8String:names[i]]);
        if (c) DumpMethods(names[i], c);
    }
    // 全量扫描所有已注册类, 找类名含 Stheno/Reflect 的
    Log("--- full class scan (Stheno/Reflect) ---\n");
    int total = objc_getClassList(NULL, 0);
    Class *all = (Class *)malloc(sizeof(Class) * total);
    total = objc_getClassList(all, total);
    for (int i = 0; i < total; i++) {
        const char *n = class_getName(all[i]);
        if (n && (strstr(n, "Stheno") || strstr(n, "Reflect"))) {
            DumpMethods(n, all[i]);
        }
    }
    free(all);
    Log("--- class scan done ---\n");
}

@interface DumpTimer : NSObject @end
@implementation DumpTimer
- (void)fire:(NSTimer *)t { }
@end

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class viewCls = UIView.class;
        MSHookMessageEx(viewCls, @selector(setBounds:), (IMP)HookSetBounds, &OrigSetBounds);
        MSHookMessageEx(viewCls, @selector(setFrame:), (IMP)HookSetFrame, &OrigSetFrame);
        MSHookMessageEx(viewCls, @selector(setCenter:), (IMP)HookSetCenter, &OrigSetCenter);
        MSHookMessageEx(viewCls, @selector(setTransform:), (IMP)HookSetTransform, &OrigSetTransform);
    });
    Log("SthenoBounds v3.4.4 loaded (method enum + setBounds observe)\n");
    // 延迟等 Stheno 加载完再枚举
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FindAllSthenoClasses(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FindAllSthenoClasses(); });
}

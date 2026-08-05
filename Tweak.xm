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

// Stheno 观测版 v3.4.5 - hook ReflectManager -offsetFilter
// 发现: ReflectManager 唯一 ObjC 方法 = offsetFilter, SwiftUI OffsetEffect 用它定位小窗
// 安全返回约定: 16字节 struct (CGPoint/CGSize 均为16字节寄存器返回; 标量也兼容低8字节)

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[1024]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 1023 ? n : 1023));
    close(fd);
}

typedef struct { double a, b; } Ret16;
static Ret16 (*OrigOffsetFilter)(id, SEL);
static NSUInteger offsetCalls;
static BOOL typeLogged;
static double lastX = 1e9, lastY = 1e9;

static Ret16 HookOffsetFilter(id self, SEL _cmd) {
    if (!typeLogged) {
        Method m = class_getInstanceMethod(object_getClass(self), _cmd);
        if (m) {
            const char *t = method_getReturnType(m);
            Log("offsetFilter return type encoding: %s\n", t ? t : "?");
        }
        typeLogged = YES;
    }
    Ret16 r = OrigOffsetFilter(self, _cmd);   // 原样调用, 行为不变
    offsetCalls++;
    BOOL changed = (fabs(r.a - lastX) > 0.5 || fabs(r.b - lastY) > 0.5);
    if (offsetCalls <= 15 || changed) {
        lastX = r.a; lastY = r.b;
        Log("offsetFilter[%lu]: x=%.1f y=%.1f\n", (unsigned long)offsetCalls, r.a, r.b);
    }
    return r;
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *names[] = {"_TtC6Stheno14ReflectManager", "Stheno.ReflectManager", NULL};
        for (int i = 0; names[i]; i++) {
            Class cls = NSClassFromString([NSString stringWithUTF8String:names[i]]);
            if (!cls) continue;
            SEL sel = NSSelectorFromString(@"offsetFilter");
            if (sel && [cls instancesRespondToSelector:sel]) {
                MSHookMessageEx(cls, sel, (IMP)HookOffsetFilter, (IMP *)&OrigOffsetFilter);
                Log("hooked %s -offsetFilter\n", names[i]);
                break;
            } else {
                Log("class %s found but no -offsetFilter\n", names[i]);
            }
        }
    });
    Log("SthenoBounds v3.4.5 loaded (offsetFilter observe)\n");
}

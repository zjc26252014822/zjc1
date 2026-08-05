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

// Stheno 观测版 v3.4.6 - hook ReflectManager -offsetFilter (延迟+重试)
// 修复 v3.4.5: constructor 立即执行时 Stheno 类未注册, NSClassFromString 返回 nil 被静默跳过
// 方案: 延迟 3s 开始尝试, 每 1.5s 重试直到成功或 12 次

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
            char *t = method_copyReturnType(m);
            Log("offsetFilter return type encoding: %s\n", t ? t : "?");
            if (t) free(t);
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

static void TryHook(void) {
    static int attempt = 0;
    const char *names[] = {"_TtC6Stheno14ReflectManager", "Stheno.ReflectManager", NULL};
    for (int i = 0; names[i]; i++) {
        Class cls = NSClassFromString([NSString stringWithUTF8String:names[i]]);
        if (!cls) {
            Log("try[%d]: %s not found yet\n", attempt, names[i]);
            continue;
        }
        SEL sel = NSSelectorFromString(@"offsetFilter");
        if (sel && [cls instancesRespondToSelector:sel]) {
            if (OrigOffsetFilter == NULL) {
                MSHookMessageEx(cls, sel, (IMP)HookOffsetFilter, (IMP *)&OrigOffsetFilter);
                Log("HOOKED %s -offsetFilter (attempt %d)\n", names[i], attempt);
            }
            return;
        } else {
            Log("try[%d]: %s found, no -offsetFilter\n", attempt, names[i]);
        }
    }
    attempt++;
    if (attempt < 12) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ TryHook(); });
    } else {
        Log("give up after %d attempts\n", attempt);
    }
}

__attribute__((constructor)) static void Start(void) {
    Log("SthenoBounds v3.4.6 loaded (offsetFilter observe, delayed retry)\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TryHook(); });
}

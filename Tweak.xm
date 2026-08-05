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

// Stheno 观测版 v3.4.8 - hook CALayer setPosition 记录所有移动明显的 layer
// 发现: SwiftUI 内部渲染 layer 无 delegate, 之前的过滤漏掉了真正移动的层
//       (no-delegate layer pos 到了 645,1398 屏幕外!)
// 新策略: 记录所有 position 变化 > 1pt 的 layer, 向上追溯 superlayer 链找 Stheno 祖先

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
static NSUInteger movedCount, sthenoAncestorCount;
static NSMutableDictionary *lastPosByKey;   // key: 类名 -> last pos

// 向上追溯 superlayer 链, 找最近的 Stheno 相关祖先 (delegate 或类名)
static const char *FindSthenoAncestor(CALayer *layer, int depth) {
    if (!layer || depth > 8) return NULL;
    id d = layer.delegate;
    if (d) {
        const char *n = class_getName(object_getClass(d));
        if (n && (strstr(n, "Stheno") || strstr(n, "Reflect"))) return n;
    }
    const char *ln = class_getName(object_getClass(layer));
    if (ln && (strstr(ln, "PlatformViewHost") || strstr(ln, "UIHostingView") ||
               strstr(ln, "Stheno") || strstr(ln, "Reflect")))
        return ln;
    return FindSthenoAncestor(layer.superlayer, depth + 1);
}

static void HookSetPosition(CALayer *self, SEL _cmd, CGPoint pos) {
    // 记录移动明显的 layer (与上次 position 比较)
    static NSMutableDictionary *lastMap;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastMap = [NSMutableDictionary dictionary]; });
    const char *cls = class_getName(object_getClass(self));
    const char *ancestor = FindSthenoAncestor(self, 0);
    NSString *key = [NSString stringWithFormat:@"%s|%s", cls, ancestor ? ancestor : "-"];
    NSValue *lastVal = lastMap[key];
    BOOL moved = NO;
    if (lastVal) {
        CGPoint last = lastVal.CGPointValue;
        moved = (fabs(pos.x - last.x) > 1.0 || fabs(pos.y - last.y) > 1.0);
    }
    lastMap[key] = [NSValue valueWithCGPoint:pos];
    if (moved) {
        movedCount++;
        BOOL stheno = (ancestor != NULL);
        if (stheno) sthenoAncestorCount++;
        // 节流: Stheno 相关的全记, 其他的只记前 30 个
        if (stheno || movedCount <= 30) {
            id d = self.delegate;
            Log("moved[%lu]: %s pos=(%.0f,%.0f) frame=(%.0f,%.0f %.0fx%.0f) ancestor=%s delegate=%s\n",
                (unsigned long)movedCount, cls,
                pos.x, pos.y,
                self.frame.origin.x, self.frame.origin.y,
                self.frame.size.width, self.frame.size.height,
                ancestor ? ancestor : "-",
                d ? class_getName(object_getClass(d)) : "none");
        }
    }
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self, _cmd, pos);
}

__attribute__((constructor)) static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class layerCls = CALayer.class;
        MSHookMessageEx(layerCls, @selector(setPosition:), (IMP)HookSetPosition, &OrigSetPosition);
    });
    Log("SthenoBounds v3.4.8 loaded (track moved layers, find Stheno ancestor)\n");
}

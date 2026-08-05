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

// Stheno 边界修复 v3.4.9 - clamp 小窗 layer position
// 定位成功: 小窗 = 303x303 纯 CALayer, 挂在 _UIHostingView...Stheno9Container (全屏0,0) 下,
//           通过 setPosition: 移动 (v3.4.8 日志实证)
// 修复: hook CALayer setPosition:, 识别小窗层 (Stheno 祖先 + 尺寸150-400),
//       把 position clamp 到屏幕内 (Container 全屏在 0,0, frame 即屏幕坐标)

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
static const CGFloat TopInset = 47.0;    // 状态栏
static const CGFloat BottomInset = 34.0; // home indicator
static const CGFloat SideInset = 0.0;    // 贴边

// 向上追溯 superlayer 链找 Stheno 祖先
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
        // 只看 150-400 尺寸的层 (小窗本体, 过滤小图标)
        CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
        if (w >= 150 && w <= 420 && h >= 150 && h <= 420 && HasSthenoAncestor(self, 0)) {
            CGRect screen = UIScreen.mainScreen.bounds;
            // position 是 layer 中心点 (相对父 layer); Container 全屏在 0,0 -> frame 即屏幕坐标
            CGFloat halfW = w / 2.0, halfH = h / 2.0;
            CGFloat minX = SideInset + halfW;
            CGFloat maxX = screen.size.width - SideInset - halfW;
            CGFloat minY = TopInset + halfH;
            CGFloat maxY = screen.size.height - BottomInset - halfH;
            CGFloat nx = MIN(MAX(pos.x, minX), maxX);
            CGFloat ny = MIN(MAX(pos.y, minY), maxY);
            if (nx != pos.x || ny != pos.y) {
                clampCount++;
                if (clampCount <= 30 || clampCount % 10 == 0) {
                    Log("CLAMP[%lu]: %.0fx%.0f pos=(%.0f,%.0f) -> (%.0f,%.0f) [screen %.0fx%.0f]\n",
                        (unsigned long)clampCount, w, h,
                        pos.x, pos.y, nx, ny,
                        screen.size.width, screen.size.height);
                }
                newPos = CGPointMake(nx, ny);
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
    Log("SthenoBounds v3.4.9 loaded (CLAMP small-window layer position)\n");
}

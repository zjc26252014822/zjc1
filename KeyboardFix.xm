// 000SthenoKeyboardFix - Stheno 分屏小窗键盘修复
//
// 背景（基于对 SthenoKeyboard.dylib 的 arm64e 反汇编）：
//   Stheno 的键盘逻辑 hook 了系统键盘高度计算。当"另一个分屏 tweak 先创建了
//   keyboardWindow"时，SthenoKeyboard 会误判"键盘已在别处显示"，于是对 Stheno
//   主 app 的场景返回异常高度 -> 小窗键盘弹不出来。
//
// 本 tweak 策略（V1，保守可观测）：
//   - 只依赖稳定的系统 selector，不依赖 SthenoKeyboard 的模糊偏移；
//   - 运行时用 respondsToSelector:/class_getInstanceMethod 兜底，方法不存在则
//     跳过对应 hook（绝不让主进程崩）；
//   - 当"Stheno 主 app 是当前前台 app + keyboardWindow 已存在"时，把被另一个
//     tweak 占用的键盘窗口切给 Stheno 的窗口场景（强制走正常键盘路径）。
//
// 注意：这是基于静态逆向的"先盲写 + 装上观察"首版，行为可能需按实机日志微调。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ---------------- 运行时日志（stdout + /var/mobile/Documents/SthenoKeyboardFix.log）----
static void FixLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("[SthenoKeyboardFix] %s\n", msg.UTF8String);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/SthenoKeyboardFix.log"];
    if (!fh) {
        [msg writeToFile:@"/var/mobile/Documents/SthenoKeyboardFix.log"
              atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/SthenoKeyboardFix.log"];
    }
    if (fh) {
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss.SSS"; });
        [fh seekToEndOfFile];
        [fh writeData:[[NSString stringWithFormat:@"%@ [SthenoKeyboardFix] %@\n",
                        [df stringFromDate:[NSDate date]], msg]
                       dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ---------------- 状态 ----------------
static NSString *gMainAppBundleID = nil;   // Stheno 的"主 app"，由配置或前台推断
static BOOL gInjected = NO;

// ---------------- 系统方法 hook 原函数指针 ----------------
// UIKeyboardImpl 的 intersection 高度计算（iOS 私有，返回 CGFloat）
static CGFloat (*orig_intersectionHeight)(id, SEL, id, BOOL *, BOOL);
static UIView *(*orig_remoteKeyboardWindow)(id, SEL, id, BOOL);

// ---------------- 辅助：当前应用的 bundle id ----------------
static NSString *CurrentFrontBundleID(void) {
    return UIApplication.sharedApplication.bundleIdentifier ?: @"";
}

// ---------------- 核心 hook：intersectionHeight（键盘高度计算）----------------
// 系统方法签名（iOS 私有）：
//   - (CGFloat)intersectionHeightForWindowScene:(id)windowScene
//        isLocalMinimumHeightOut:(BOOL *)isLocalMin ignoreHorizontalOffset:(BOOL)ignore
// 行为：当"主 app 前台"且"已被另一个 tweak 创建了 keyboardWindow"时，这里会出现
// 键盘归属冲突。V1 只做保守处理：记录现场 + 跟随系统原值（不制造新问题），并借此
// 学习对 main app 的真实干扰。真正的干预（强制重建远程键盘窗口）放在
// HookRemoteKeyboardWindow，且仅在 main app 前台 + 请求真实键盘时触发。
static CGFloat HookIntersectionHeight(id self, SEL _cmd, id windowScene,
                                      BOOL *isLocalMin, BOOL ignore) {
    CGFloat orig = 0;
    if (orig_intersectionHeight) orig = orig_intersectionHeight(self, _cmd, windowScene, isLocalMin, ignore);

    NSString *front = CurrentFrontBundleID();
    // 主 app 判定：若尚未锁定主 app，把当前前台 app 记为主 app 候选；否则用它比对。
    if (gMainAppBundleID == nil) {
        gMainAppBundleID = front;
    }
    BOOL mainIsFront = (gMainAppBundleID.length > 0 &&
                        [front isEqualToString:gMainAppBundleID]);
    if (!mainIsFront) return orig;

    // 另一个 tweak 已创建 keyboardWindow —— 这是冲突触发点，记录现场。
    if ([self respondsToSelector:@selector(keyboardWindow)]) {
        id kbWindow = [self keyboardWindow];
        if (kbWindow) {
            FixLog(@"intersection: 冲突 main=%@ front=%@ keyboardWindow=%p scene=%@ orig=%f",
                   gMainAppBundleID, front, kbWindow, windowScene, (double)orig);
        }
    }
    return orig;
}

// ---------------- UIRemoteKeyboardWindow 创建 hook ----------------
// 当"主 app 前台 + 请求创建真实键盘窗口"却被返回 nil（说明被其他 tweak/场景占用），
// 强制再次请求创建，让小窗键盘能挂上来。
static UIView *HookRemoteKeyboardWindow(id self, SEL _cmd, id screen, BOOL create) {
    UIView *w = NULL;
    if (orig_remoteKeyboardWindow) w = orig_remoteKeyboardWindow(self, _cmd, screen, create);

    NSString *front = CurrentFrontBundleID();
    if (gMainAppBundleID == nil) gMainAppBundleID = front;
    BOOL mainIsFront = (gMainAppBundleID.length > 0 &&
                        [front isEqualToString:gMainAppBundleID]);
    if (mainIsFront && create && w == NULL) {
        FixLog(@"remoteKB: 主 app 请求键盘窗口但返回 nil (front=%@)，强制重建", front);
        w = orig_remoteKeyboardWindow ? orig_remoteKeyboardWindow(self, _cmd, screen, YES) : NULL;
    }
    return w;
}

// ---------------- 安装 hooks ----------------
static void Install(void) {
    if (gInjected) return;
    gInjected = YES;

    Class kbImpl = NSClassFromString(@"UIKeyboardImpl");
    if (kbImpl) {
        SEL isel = NSSelectorFromString(@"intersectionHeightForWindowScene:isLocalMinimumHeightOut:ignoreHorizontalOffset:");
        if (isel && [kbImpl instancesRespondToSelector:isel]) {
            MSHookMessageEx(kbImpl, isel,
                            (IMP)HookIntersectionHeight, (IMP *)&orig_intersectionHeight);
            FixLog(@"hooked UIKeyboardImpl %@", NSStringFromSelector(isel));
        } else {
            FixLog(@"跳过 UIKeyboardImpl.intersectionHeight（方法不存在，iOS 可能移除了它）");
        }
    } else {
        FixLog(@"NSClassFromString(UIKeyboardImpl) 失败，跳过 intersection hook");
    }

    Class remoteCls = NSClassFromString(@"UIRemoteKeyboardWindow");
    if (remoteCls) {
        SEL rsel = NSSelectorFromString(@"remoteKeyboardWindowForScreen:create:");
        if (rsel && [remoteCls respondsToSelector:rsel]) {
            MSHookMessageEx(remoteCls, rsel,
                            (IMP)HookRemoteKeyboardWindow, (IMP *)&orig_remoteKeyboardWindow);
            FixLog(@"hooked UIRemoteKeyboardWindow %@", NSStringFromSelector(rsel));
        } else {
            FixLog(@"跳过 UIRemoteKeyboardWindow.remoteKeyboardWindowForScreen:create:");
        }
    } else {
        FixLog(@"NSClassFromString(UIRemoteKeyboardWindow) 失败");
    }
}

__attribute__((constructor)) static void Start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSUInteger i = 1; i <= 60; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * NSEC_PER_SEC / 4),
                           dispatch_get_main_queue(), ^{ Install(); });
        }
    });
    FixLog(@"SthenoKeyboardFix loaded (V1)");
}

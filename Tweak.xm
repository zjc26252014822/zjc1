#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <mach/mach.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
extern void MSHookFunction(void *,void *,void **);
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

// 边界修复 v3.3.0 - 崩溃安全版 (修复 v3.2.0 use-after-free)
// 策略:
//   1. 只 hook 0x4da68 (标准 ObjC init, 返回值必然有效对象), 不 hook 0x4da44
//      (无 prologue 的拷贝函数, 可能是 Swift struct copy helper, dest 不一定是对象)
//   2. objc_retain 强持有收集的对象 (不再 __unsafe_unretained)
//   3. IsReflectManager 用 vm_region 验证指针可读后才 object_getClass, 杜绝垃圾指针崩溃
//   4. 不做每帧 CADisplayLink 扫描; 改为拖拽手势结束时 clamp 一次
//   5. 全路径日志 /var/mobile/Documents/SthenoBounds.log

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[512]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 511 ? n : 511));
    close(fd);
}

typedef void *(*InitFn)(void*,void*); static InitFn OrigInit;
static __unsafe_unretained id managers[32]; static NSUInteger managerCount;
static uintptr_t frameOff, offsetOff; static BOOL offsetsReady;
static const CGFloat margin=12.0, topSafe=59.0, bottomSafe=34.0;
static NSUInteger hookInitHits, rejectedNonReflect, clampRuns, clampFixed;
static IMP OrigPanSetState;

// 用 vm_region 验证指针指向可读内存 (防止 object_getClass 对垃圾指针崩溃)
static BOOL MemoryReadable(uintptr_t addr) {
    vm_address_t a = (vm_address_t)addr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    kern_return_t kr = vm_region_64(mach_task_self(), &a, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt);
    if (kr != KERN_SUCCESS) return NO;
    return (info.protection & VM_PROT_READ) != 0;
}

static BOOL IsReflectManager(id o) {
    if (!o) return NO;
    uintptr_t p = (uintptr_t)o;
    if (p < 0x100000 || (p & 7)) return NO;       // 排除 tagged/小指针/未对齐
    if (!MemoryReadable(p)) return NO;              // 不可读 -> 不是堆对象
    Class c = object_getClass(o);
    if (!c || !MemoryReadable((uintptr_t)c)) return NO;
    const char *n = class_getName(c);
    if (!n) return NO;
    return strstr(n, "Reflect") != NULL;
}

static void *HookInit(void*a,void*b){
    void *o = OrigInit ? OrigInit(a,b) : NULL;
    if (o) {
        hookInitHits++;
        id obj = (__bridge id)o;
        if (IsReflectManager(obj)) {
            if (managerCount < 32) {
                objc_retain(obj);
                managers[managerCount++] = obj;
                Log("remember: %s %p total=%lu initHits=%lu\n",
                    class_getName(object_getClass(obj)), o,
                    (unsigned long)managerCount, (unsigned long)hookInitHits);
            }
        } else {
            rejectedNonReflect++;
            if (rejectedNonReflect <= 5)
                Log("reject: %p class=%s\n", o,
                    (MemoryReadable((uintptr_t)object_getClass(o)) ?
                     (class_getName(object_getClass(o)) ?: "?") : "?"));
        }
    }
    return o;
}

static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Prepare(id object) {
    if (offsetsReady || !object || !IsReflectManager(object)) return;
    const uintptr_t *fields = (const uintptr_t *)((uintptr_t)[object class] + 10 * sizeof(uintptr_t));
    uintptr_t f16 = fields[16], f18 = fields[18];
    Log("prepare: %s fields[16]=%#llx [18]=%#llx\n",
        class_getName(object_getClass(object)),
        (unsigned long long)f16, (unsigned long long)f18);
    if (!Good(f16) || !Good(f18)) { Log("prepare: bad offsets, skip\n"); return; }
    frameOff = f16; offsetOff = f18; offsetsReady = YES;
    Log("prepare: OK frameOff=%#llx offsetOff=%#llx\n",
        (unsigned long long)frameOff, (unsigned long long)offsetOff);
}
static void ClampAll(void) {
    @try {
    CGRect screen = UIScreen.mainScreen.bounds;
    for (NSUInteger i=0; i<managerCount; i++) {
        id object = managers[i];
        if (!object || !IsReflectManager(object)) continue;
        Prepare(object); if (!offsetsReady) continue;
        uint8_t *base = (uint8_t *)(__bridge void *)object;
        double *frame = (double *)(base + frameOff);
        double *offset = (double *)(base + offsetOff);
        double width=frame[0], height=frame[1];
        if (!isfinite(width) || !isfinite(height) || width < 80 || height < 80) continue;
        double baseX=(screen.size.width-width)*.5;
        double baseY=(screen.size.height-height)*.5;
        double minX=margin-baseX, maxX=screen.size.width-margin-width-baseX;
        double minY=topSafe+margin-baseY, maxY=screen.size.height-bottomSafe-margin-height-baseY;
        double nx=offset[0], ny=offset[1];
        if (minX <= maxX && isfinite(offset[0])) nx = MIN(MAX(nx, minX), maxX);
        if (minY <= maxY && isfinite(offset[1])) ny = MIN(MAX(ny, minY), maxY);
        clampRuns++;
        if (nx != offset[0] || ny != offset[1]) {
            clampFixed++;
            Log("clamp: %s %.0fx%.0f off %.0f,%.0f -> %.0f,%.0f\n",
                class_getName(object_getClass(object)),
                width, height, offset[0], offset[1], nx, ny);
            offset[0]=nx; offset[1]=ny;
        }
    }
    } @catch (NSException *e) {
        Log("clampAll exception: %@", e.name);
    }
}
// 低频兜底: 1Hz 强持有对象 clamp (对象不会释放, 访问安全), 防止手势 hook 不触发时边界无人修
@interface ClampTimer : NSObject @end
@implementation ClampTimer
- (void)fire:(NSTimer *)t { ClampAll(); }
@end
static void HookPanSetState(UIPanGestureRecognizer *self, SEL cmd, UIGestureRecognizerState state) {
    ((void(*)(id,SEL,UIGestureRecognizerState))OrigPanSetState)(self,cmd,state);
    if (state == UIGestureRecognizerStateEnded ||
        state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ClampAll(); });
    }
}
static void Added(const struct mach_header*h,intptr_t slide){
    static BOOL done; if(done)return;
    Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    Log("found Stheno.dylib at %p\n", h);
    // 只 hook 0x4da68: 标准 ObjC init (stp x29,x30 prologue, 拷贝72字节, 返回 self)
    MSHookFunction((void*)((uintptr_t)h+0x4da68),(void*)HookInit,(void**)&OrigInit);
    done=YES;
    Log("hook installed: init@0x4da68\n");
}
__attribute__((constructor))static void Start(void){
    _dyld_register_func_for_add_image(Added);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UIPanGestureRecognizer.class;
        MSHookMessageEx(cls, @selector(setState:), (IMP)HookPanSetState, &OrigPanSetState);
    });
    // 1Hz 低频兜底 clamp (强持有对象, 安全; 每帧级修正由手势结束触发)
    ClampTimer *ct = [ClampTimer new];
    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 target:ct selector:@selector(fire:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    Log("SthenoBounds v3.3.0 loaded\n");
}

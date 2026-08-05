#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
extern void MSHookFunction(void *,void *,void **);

// 边界修复 v3.2.0 - 日志版
// 修正: hook 真正的 init (0x4da68) 而非 0x4da60 (那是 copy 函数的结尾 ret)
// 日志: /var/mobile/Documents/SthenoBounds.log

static void Log(const char *fmt, ...) {
    int fd = open("/var/mobile/Documents/SthenoBounds.log", O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd < 0) return;
    char b[512]; va_list a; va_start(a, fmt);
    int n = vsnprintf(b, sizeof(b), fmt, a);
    va_end(a);
    if (n > 0) write(fd, b, (size_t)(n < 511 ? n : 511));
    close(fd);
}

// 两个候选函数: 0x4da44 (copy, 拷贝72字节struct) 和 0x4da68 (init, 标准序言)
typedef void *(*InitFn)(void*,void*); static InitFn OrigInit;
typedef void *(*CopyFn)(void*,void*); static CopyFn OrigCopy;
static __unsafe_unretained id instances[32]; static NSUInteger count;
static CADisplayLink *guardLink; static BOOL offsetsReady;
static uintptr_t frameOff, offsetOff;
static const CGFloat margin=12.0, topSafe=59.0, bottomSafe=34.0;
static NSUInteger hookInitHits, hookCopyHits, clampRuns, clampFixed;

static void *HookInit(void*a,void*b){
    void*o = OrigInit? OrigInit(a,b) : NULL;
    if(o && count<32){ instances[count++]=(__bridge id)o; hookInitHits++; Log("init: new obj %p total=%lu\n", o, (unsigned long)count); }
    return o;
}
static void *HookCopy(void*a,void*b){
    void*o = OrigCopy? OrigCopy(a,b) : NULL;
    if(o && count<32){ instances[count++]=(__bridge id)o; hookCopyHits++; Log("copy: new obj %p total=%lu\n", o, (unsigned long)count); }
    return o;
}
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){
    if(offsetsReady||!o)return;
    const uintptr_t*v=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));
    Log("setup: class=%p v16=%#llx v17=%#llx v18=%#llx v19=%#llx\n",
        [o class],
        (unsigned long long)v[16],(unsigned long long)v[17],
        (unsigned long long)v[18],(unsigned long long)v[19]);
    if(!Good(v[16])||!Good(v[18])){ Log("setup: bad offsets, retry later\n"); return; }
    frameOff=v[16];offsetOff=v[18];offsetsReady=YES;
    Log("setup: OK frameOff=%#llx offsetOff=%#llx\n",(unsigned long long)frameOff,(unsigned long long)offsetOff);
}
static void Clamp(id o){
    if(!o)return; Setup(o); if(!offsetsReady)return;
    uint8_t *base=(uint8_t*)(__bridge void*)o;
    double *frame=(double*)(base+frameOff), *offset=(double*)(base+offsetOff);
    double w=frame[0],h=frame[1];
    if(!isfinite(w)||!isfinite(h)||w<80||h<80)return;
    CGRect screen=UIScreen.mainScreen.bounds;
    double baseX=(screen.size.width-w)*.5;
    double baseY=(screen.size.height-h)*.5;
    double minX=margin-baseX, maxX=screen.size.width-margin-w-baseX;
    double minY=topSafe+margin-baseY, maxY=screen.size.height-bottomSafe-margin-h-baseY;
    double nx=offset[0], ny=offset[1];
    if(minX<=maxX) nx=MIN(MAX(nx,minX),maxX);
    if(minY<=maxY) ny=MIN(MAX(ny,minY),maxY);
    clampRuns++;
    if(nx!=offset[0]||ny!=offset[1]){
        clampFixed++;
        Log("clamp: obj=%p frame=%.0fx%.0f offset %.0f,%.0f -> %.0f,%.0f (screen %.0fx%.0f base %.0f,%.0f)\n",
            o, w, h, offset[0], offset[1], nx, ny,
            screen.size.width, screen.size.height, baseX, baseY);
        offset[0]=nx; offset[1]=ny;
    }
}
@interface OffsetGuard:NSObject@end
@implementation OffsetGuard
-(void)tick:(CADisplayLink*)unused{
    static NSTimeInterval lastLog=0; NSTimeInterval now=CACurrentMediaTime();
    for(NSUInteger i=0;i<count;i++)Clamp(instances[i]);
    if(now-lastLog>5.0){ lastLog=now;
        Log("tick: count=%lu initHits=%lu copyHits=%lu clamps=%lu fixed=%lu offsetsReady=%d\n",
            (unsigned long)count,(unsigned long)hookInitHits,(unsigned long)hookCopyHits,
            (unsigned long)clampRuns,(unsigned long)clampFixed, offsetsReady);
    }
}
@end
static void Added(const struct mach_header*h,intptr_t slide){
    static BOOL done; if(done)return;
    Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    Log("found Stheno.dylib at %p\n", h);
    // 0x4da68 = 真正的 init (标准序言); 0x4da44 = copy 函数开头
    MSHookFunction((void*)((uintptr_t)h+0x4da68),(void*)HookInit,(void**)&OrigInit);
    MSHookFunction((void*)((uintptr_t)h+0x4da44),(void*)HookCopy,(void**)&OrigCopy);
    done=YES;
    Log("hooks installed: init@0x4da68 copy@0x4da44\n");
}
__attribute__((constructor))static void Start(void){
    _dyld_register_func_for_add_image(Added);
    OffsetGuard*g=[OffsetGuard new];
    guardLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];
    objc_setAssociatedObject(guardLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(),^{[guardLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});
    Log("SthenoBounds v3.2.0 loaded\n");
}

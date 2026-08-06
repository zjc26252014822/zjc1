#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
extern void MSHookFunction(void *, void *, void **);

// Targeted only at Stheno's verified active ReflectManager (the ninth
// constructor instance). No CoreAnimation or global gesture hooks.
typedef void *(*InitFn)(void *, void *);
static InitFn OrigInit;
static __unsafe_unretained id activeManager;
static NSUInteger created;
static uintptr_t frameOffset, dragOffset;
static BOOL ready, pending, haveSample;
static double lastX, lastY;
static NSUInteger stableFrames;
static CADisplayLink *watchLink;
static const CGFloat Edge=12.0, Top=59.0, Bottom=34.0;

static void *HookReflectInit(void *a, void *b) {
    void *o=OrigInit(a,b);
    if (++created == 9) activeManager=(__bridge id)o;
    return o;
}
static BOOL Valid(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){
    if(ready||!o)return;
    const uintptr_t *f=(const uintptr_t *)((uintptr_t)[o class]+10*sizeof(uintptr_t));
    if(!Valid(f[16])||!Valid(f[18]))return;
    frameOffset=f[16];dragOffset=f[18];ready=YES;
}
static void Rebound(void) {
    // Keep pending set until Stheno changes offset again; this guarantees
    // one correction per completed drag rather than a per-frame write.
    id o=activeManager;Setup(o);if(!ready)return;
    uint8_t *base=(uint8_t *)(__bridge void *)o;
    double *frame=(double *)(base+frameOffset),*offset=(double *)(base+dragOffset);
    double w=frame[0],h=frame[1],x=offset[0],y=offset[1];
    if(!isfinite(w)||!isfinite(h)||!isfinite(x)||!isfinite(y)||w<80||h<80)return;
    CGRect s=UIScreen.mainScreen.bounds;
    // Trace showed finalFrame=(scaled width,height,scale,...); offset is
    // displacement from the centered card. Clamp only after the motion has
    // settled, so Stheno's drag state remains untouched during dragging.
    double cx=(s.size.width-w)*.5,cy=(s.size.height-h)*.5;
    double loX=Edge-cx,hiX=s.size.width-Edge-w-cx;
    double loY=Top+Edge-cy,hiY=s.size.height-Bottom-Edge-h-cy;
    if(loX>hiX||loY>hiY)return;
    double nx=MIN(MAX(x,loX),hiX),ny=MIN(MAX(y,loY),hiY);
    if(nx==x&&ny==y)return;
    // One delayed write: it is a post-drag snap, not a per-frame fight.
    offset[0]=nx;offset[1]=ny;
}
static void ObserveOffset(void){
    id o=activeManager;Setup(o);if(!ready)return;
    double *p=(double *)((uint8_t *)(__bridge void *)o+dragOffset);
    if(!isfinite(p[0])||!isfinite(p[1]))return;
    if(!haveSample||fabs(p[0]-lastX)>.08||fabs(p[1]-lastY)>.08){
        lastX=p[0];lastY=p[1];haveSample=YES;stableFrames=0;pending=NO;return;
    }
    // Offset stable for 12 frames: Stheno's own post-drag physics is done.
    if(++stableFrames>=12&&!pending){pending=YES;Rebound();}
}
@interface OffsetObserver:NSObject@end
@implementation OffsetObserver
-(void)tick:(CADisplayLink*)unused{ObserveOffset();}
@end
static void Added(const struct mach_header*h,intptr_t slide){
    static BOOL hooked;if(hooked)return;Dl_info d={0};
    if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    MSHookFunction((void *)((uintptr_t)h+0x4da60),(void *)HookReflectInit,(void **)&OrigInit);hooked=YES;
}
__attribute__((constructor))static void Start(void){
    _dyld_register_func_for_add_image(Added);
    OffsetObserver *observer=[OffsetObserver new];
    watchLink=[CADisplayLink displayLinkWithTarget:observer selector:@selector(tick:)];
    objc_setAssociatedObject(watchLink,@selector(tick:),observer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(),^{[watchLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});
}

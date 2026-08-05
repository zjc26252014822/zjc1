#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
extern void MSHookFunction(void *, void *, void **);

// Device trace established: field 16 contains (scaledWidth, scaledHeight,
// scale, ...), and field 18's first two doubles are the live card offset.
// Never hook UIKit gestures. Only correct an offset after it has been stable
// for 12 display frames (~0.2s), which is after Stheno's own drag state ends.
typedef void *(*InitFn)(void *, void *);
static InitFn OrigInit;
static __unsafe_unretained id managers[16]; static NSUInteger managerCount;
static uintptr_t frameOff, offsetOff; static BOOL offsetsReady;
static CADisplayLink *settleLink;
static double lastX, lastY; static NSUInteger stableFrames; static BOOL haveLast, corrected;
static const CGFloat Edge=12.0, Top=59.0, Bottom=34.0;

static void *HookInit(void *a, void *b) { void *o=OrigInit(a,b); if(o&&managerCount<16) managers[managerCount++]=(__bridge id)o; return o; }
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){if(offsetsReady||!o)return;const uintptr_t*v=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));if(!Good(v[16])||!Good(v[18]))return;frameOff=v[16];offsetOff=v[18];offsetsReady=YES;}
static BOOL ClampOne(id o) {
    if(!o)return NO; Setup(o); if(!offsetsReady)return NO;
    uint8_t *base=(uint8_t*)(__bridge void*)o;
    double *frame=(double*)(base+frameOff), *offset=(double*)(base+offsetOff);
    double w=frame[0],h=frame[1],x=offset[0],y=offset[1];
    if(!isfinite(w)||!isfinite(h)||!isfinite(x)||!isfinite(y)||w<80||h<80)return NO;
    CGRect s=UIScreen.mainScreen.bounds;
    double cx=(s.size.width-w)*.5, cy=(s.size.height-h)*.5;
    double minX=Edge-cx,maxX=s.size.width-Edge-w-cx;
    double minY=Top+Edge-cy,maxY=s.size.height-Bottom-Edge-h-cy;
    double nx=(minX<=maxX)?MIN(MAX(x,minX),maxX):x;
    double ny=(minY<=maxY)?MIN(MAX(y,minY),maxY):y;
    if(nx==x&&ny==y)return NO;
    offset[0]=nx;offset[1]=ny;return YES;
}
@interface StableGuard:NSObject@end
@implementation StableGuard
-(void)tick:(CADisplayLink*)unused {
    // I8 was the active instance in device trace, but scan all safely.
    BOOL moving=NO;
    for(NSUInteger i=0;i<managerCount;i++){id o=managers[i];if(!o)continue;Setup(o);if(!offsetsReady)continue;double*p=(double*)((uint8_t*)(__bridge void*)o+offsetOff);if(!isfinite(p[0])||!isfinite(p[1]))continue;if(!haveLast||fabs(p[0]-lastX)>.05||fabs(p[1]-lastY)>.05){lastX=p[0];lastY=p[1];haveLast=YES;moving=YES;}}
    if(moving){stableFrames=0;corrected=NO;return;}
    if(!haveLast||corrected)return;
    if(++stableFrames<12)return;
    for(NSUInteger i=0;i<managerCount;i++) ClampOne(managers[i]);
    corrected=YES;
}
@end
static void Added(const struct mach_header*h,intptr_t slide){static BOOL done;if(done)return;Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)HookInit,(void**)&OrigInit);done=YES;}
__attribute__((constructor))static void Start(void){_dyld_register_func_for_add_image(Added);StableGuard*g=[StableGuard new];settleLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(settleLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);dispatch_async(dispatch_get_main_queue(),^{[settleLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});}

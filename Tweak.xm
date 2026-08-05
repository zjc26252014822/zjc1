#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
extern void MSHookFunction(void *,void *,void **);

// Confirmed by device trace: instance 8 changes finalOffset (field 18).
// finalFrame (field 16) = scaledWidth, scaledHeight, scale, verticalState.
typedef void *(*InitFn)(void*,void*); static InitFn OrigInit;
static __unsafe_unretained id instances[16]; static NSUInteger count;
static CADisplayLink *guardLink; static BOOL offsetsReady;
static uintptr_t frameOff, offsetOff;
static const CGFloat margin=12.0, topSafe=59.0, bottomSafe=34.0;
static void *HookInit(void*a,void*b){void*o=OrigInit(a,b);if(o&&count<16)instances[count++]=(__bridge id)o;return o;}
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){if(offsetsReady||!o)return;const uintptr_t*v=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));if(!Good(v[16])||!Good(v[18]))return;frameOff=v[16];offsetOff=v[18];offsetsReady=YES;}
static void Clamp(id o){
 if(!o)return; Setup(o); if(!offsetsReady)return;
 uint8_t *base=(uint8_t*)(__bridge void*)o;
 // Tracing established both fields are four doubles. finalFrame[0,1] is
 // the rendered card size; finalOffset[0,1] is drag displacement from center.
 double *frame=(double*)(base+frameOff), *offset=(double*)(base+offsetOff);
 double w=frame[0],h=frame[1]; if(!isfinite(w)||!isfinite(h)||w<80||h<80)return;
 CGRect screen=UIScreen.mainScreen.bounds;
 double baseX=(screen.size.width-w)*.5;
 double baseY=(screen.size.height-h)*.5;
 double minX=margin-baseX, maxX=screen.size.width-margin-w-baseX;
 double minY=topSafe+margin-baseY, maxY=screen.size.height-bottomSafe-margin-h-baseY;
 if(minX<=maxX) offset[0]=MIN(MAX(offset[0],minX),maxX);
 if(minY<=maxY) offset[1]=MIN(MAX(offset[1],minY),maxY);
}
@interface OffsetGuard:NSObject@end
@implementation OffsetGuard
-(void)tick:(CADisplayLink*)unused{for(NSUInteger i=0;i<count;i++)Clamp(instances[i]);}
@end
static void Added(const struct mach_header*h,intptr_t slide){static BOOL done;if(done)return;Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)HookInit,(void**)&OrigInit);done=YES;}
__attribute__((constructor))static void Start(void){_dyld_register_func_for_add_image(Added);OffsetGuard*g=[OffsetGuard new];guardLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(guardLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);dispatch_async(dispatch_get_main_queue(),^{[guardLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});}

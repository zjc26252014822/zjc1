#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
extern void MSHookFunction(void *, void *, void **);

typedef void *(*InitFn)(void *, void *);
static InitFn OrigInit; static __unsafe_unretained id activeManager;
static NSUInteger created, stableFrames; static uintptr_t frameOffset,dragOffset;
static BOOL ready,pending,haveSample; static double lastX,lastY;
static CADisplayLink *watchLink; static const CGFloat Edge=12,Top=59,Bottom=34;
static void Log(const char*f,...){int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(d<0)return;char b[360];va_list a;va_start(a,f);int n=vsnprintf(b,sizeof b,f,a);va_end(a);if(n>0)write(d,b,(unsigned long)(n<359?n:359));close(d);}
static void*H(void*a,void*b){void*o=OrigInit(a,b);created++;if(created==9){activeManager=(__bridge id)o;Log("ACTIVE ctor=9 ptr=%p\n",o);}return o;}
static BOOL Valid(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){if(ready||!o)return;const uintptr_t*f=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));if(!Valid(f[16])||!Valid(f[18])){Log("BAD offsets f=%#llx o=%#llx\n",(unsigned long long)f[16],(unsigned long long)f[18]);return;}frameOffset=f[16];dragOffset=f[18];ready=YES;Log("READY frame=%#llx offset=%#llx\n",(unsigned long long)frameOffset,(unsigned long long)dragOffset);}
static void Rebound(void){id o=activeManager;Setup(o);if(!ready){Log("SKIP not-ready\n");return;}uint8_t*base=(uint8_t*)(__bridge void*)o;double*f=(double*)(base+frameOffset),*p=(double*)(base+dragOffset);double w=f[0],h=f[1],x=p[0],y=p[1];if(!isfinite(w)||!isfinite(h)||!isfinite(x)||!isfinite(y)||w<80||h<80){Log("SKIP values f=%.2f %.2f off=%.2f %.2f\n",w,h,x,y);return;}CGRect s=UIScreen.mainScreen.bounds;double cx=(s.size.width-w)*.5,cy=(s.size.height-h)*.5;double loX=Edge-cx,hiX=s.size.width-Edge-w-cx,loY=Top+Edge-cy,hiY=s.size.height-Bottom-Edge-h-cy;double nx=MIN(MAX(x,loX),hiX),ny=MIN(MAX(y,loY),hiY);Log("SETTLE off=(%.2f,%.2f) size=(%.2f,%.2f) x=[%.2f,%.2f] y=[%.2f,%.2f] new=(%.2f,%.2f)\n",x,y,w,h,loX,hiX,loY,hiY,nx,ny);if(loX<=hiX&&loY<=hiY&&(nx!=x||ny!=y)){p[0]=nx;p[1]=ny;Log("WROTE offset\n");}else Log("NO-WRITE\n");}
@interface G:NSObject@end
@implementation G
-(void)tick:(CADisplayLink*)x{id o=activeManager;Setup(o);if(!ready)return;double*p=(double*)((uint8_t*)(__bridge void*)o+dragOffset);if(!isfinite(p[0])||!isfinite(p[1]))return;if(!haveSample||fabs(p[0]-lastX)>.08||fabs(p[1]-lastY)>.08){lastX=p[0];lastY=p[1];haveSample=YES;stableFrames=0;pending=NO;return;}if(++stableFrames>=12&&!pending){pending=YES;Rebound();}}
@end
static void Add(const struct mach_header*h,intptr_t slide){static BOOL done;if(done)return;Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)H,(void**)&OrigInit);done=YES;Log("hooked Stheno\n");}
__attribute__((constructor))static void S(void){_dyld_register_func_for_add_image(Add);G*g=[G new];watchLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(watchLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);dispatch_async(dispatch_get_main_queue(),^{[watchLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});}

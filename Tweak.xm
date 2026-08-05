#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
extern void MSHookFunction(void *,void *,void **);

typedef void *(*InitFn)(void*,void*); static InitFn OrigInit;
static __unsafe_unretained id activeManager=nil; static NSUInteger created;
static uintptr_t frameOff,offsetOff; static BOOL ready;
static CADisplayLink *diagnosticLink; static double lx,ly; static BOOL have; static NSUInteger stable; static BOOL reported;
static void Log(const char*f,...){int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(d<0)return;char b[300];va_list a;va_start(a,f);int n=vsnprintf(b,sizeof b,f,a);va_end(a);if(n>0)write(d,b,(unsigned long)(n<299?n:299));close(d);}
static void*H(void*a,void*b){void*o=OrigInit(a,b);created++;/* trace proved active card was I8 (zero-index), i.e. ninth ctor */if(created==9){activeManager=(__bridge id)o;Log("active ctor 9 %p\n",o);}return o;}
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Setup(id o){if(ready||!o)return;const uintptr_t*v=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));if(!Good(v[16])||!Good(v[18])){Log("bad offsets\n");return;}frameOff=v[16];offsetOff=v[18];ready=YES;Log("offsets frame=%#llx offset=%#llx\n",(unsigned long long)frameOff,(unsigned long long)offsetOff);}
@interface G:NSObject@end
@implementation G
-(void)tick:(CADisplayLink*)x{id o=activeManager;if(!o)return;Setup(o);if(!ready)return;uint8_t*base=(uint8_t*)(__bridge void*)o;double*f=(double*)(base+frameOff),*p=(double*)(base+offsetOff);if(!isfinite(p[0])||!isfinite(p[1]))return;if(!have||fabs(p[0]-lx)>.05||fabs(p[1]-ly)>.05){lx=p[0];ly=p[1];have=YES;stable=0;reported=NO;return;}if(++stable<12||reported)return;CGRect s=UIScreen.mainScreen.bounds;double w=f[0],h=f[1],cx=(s.size.width-w)*.5,cy=(s.size.height-h)*.5;double minX=12-cx,maxX=s.size.width-12-w-cx,minY=71-cy,maxY=s.size.height-46-h-cy;Log("settled off %.2f %.2f size %.2f %.2f boundsX %.2f %.2f boundsY %.2f %.2f\n",p[0],p[1],w,h,minX,maxX,minY,maxY);reported=YES;}
@end
static void Add(const struct mach_header*h,intptr_t slide){static BOOL done;if(done)return;Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)H,(void**)&OrigInit);done=YES;Log("diagnostic armed\n");}
__attribute__((constructor))static void S(void){_dyld_register_func_for_add_image(Add);G*g=[G new];diagnosticLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(diagnosticLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);dispatch_async(dispatch_get_main_queue(),^{[diagnosticLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});}

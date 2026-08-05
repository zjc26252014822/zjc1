#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
extern void MSHookFunction(void *symbol, void *replace, void **result);

typedef void *(*ReflectInitFn)(void *, void *);
static ReflectInitFn OrigReflectInit;
static __unsafe_unretained id objects[8];
static NSUInteger count=0; static CADisplayLink *traceLink;
static uintptr_t frameOff=0, cardOff=0; static BOOL offsetsReady=NO;
static CGRect previous[8]; static BOOL seen[8];
static void Log(const char *fmt, ...) {
 int fd=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644); if(fd<0)return;
 char b[320]; va_list ap;va_start(ap,fmt);int n=vsnprintf(b,sizeof(b),fmt,ap);va_end(ap);if(n>0)write(fd,b,(unsigned long)(n<319?n:319));close(fd);
}
static void *HookInit(void *a,void *b){ void *o=OrigReflectInit(a,b); if(o&&count<8){objects[count++]=(__bridge id)o;Log("ctor %lu ptr=%p\n",(unsigned long)count,o);}return o; }
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Offsets(id o){if(offsetsReady||!o)return;uintptr_t m=(uintptr_t)[o class];const uintptr_t *v=(const uintptr_t *)(m+10*sizeof(uintptr_t));uintptr_t a=v[16],b=v[19];if(!Good(a)||!Good(b)){Log("invalid offsets f=%#llx c=%#llx\n",(unsigned long long)a,(unsigned long long)b);return;}frameOff=a;cardOff=b;offsetsReady=YES;Log("offsets frame=%#llx card=%#llx\n",(unsigned long long)a,(unsigned long long)b);}
@interface TraceGuard:NSObject @end
@implementation TraceGuard
-(void)tick:(CADisplayLink*)x { for(NSUInteger i=0;i<count;i++){id o=objects[i];if(!o)continue;Offsets(o);if(!offsetsReady)continue;CGRect f=*(CGRect *)((uint8_t *)(__bridge void*)o+cardOff);if(!isfinite(f.origin.x)||!isfinite(f.origin.y)||f.size.width<1||f.size.height<1)continue;if(!seen[i]||!CGRectEqualToRect(f,previous[i])){Log("%lu card %.1f %.1f %.1f %.1f\n",(unsigned long)i,f.origin.x,f.origin.y,f.size.width,f.size.height);previous[i]=f;seen[i]=YES;}}}
@end
static void Install(void){static BOOL done;if(done)return;for(uint32_t i=0;i<_dyld_image_count();i++){const char*n=_dyld_get_image_name(i);if(!n||!strstr(n,"Stheno.dylib"))continue;const struct mach_header*h=_dyld_get_image_header(i);MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)HookInit,(void**)&OrigReflectInit);TraceGuard*g=[TraceGuard new];traceLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(traceLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[traceLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];Log("trace ready\n");done=YES;return;}}
__attribute__((constructor))static void Start(void){dispatch_async(dispatch_get_main_queue(),^{for(NSUInteger i=1;i<=80;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/4),dispatch_get_main_queue(),^{Install();});});}

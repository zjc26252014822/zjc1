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
extern void MSHookFunction(void *symbol, void *replace, void **result);

typedef void *(*ReflectInitFn)(void *, void *);
static ReflectInitFn OrigReflectInit;
static __unsafe_unretained id objects[8]; static NSUInteger count;
static CADisplayLink *traceLink; static BOOL hooked;
static BOOL offsetsReady; static uintptr_t cardOff;
static CGRect prior[8]; static BOOL seen[8];
static void Log(const char *fmt,...){int fd=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(fd<0)return;char b[256];va_list a;va_start(a,fmt);int n=vsnprintf(b,sizeof(b),fmt,a);va_end(a);if(n>0)write(fd,b,(unsigned long)(n<255?n:255));close(fd);}
static void *HookInit(void *a,void *b){void*o=OrigReflectInit(a,b);if(o&&count<8){objects[count++]=(__bridge id)o;Log("ctor %lu %p\n",(unsigned long)count,o);}return o;}
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
static void Offsets(id o){if(offsetsReady||!o)return;uintptr_t m=(uintptr_t)[o class];const uintptr_t*v=(const uintptr_t*)(m+10*sizeof(uintptr_t));if(!Good(v[19])){Log("bad card offset %#llx\n",(unsigned long long)v[19]);return;}cardOff=v[19];offsetsReady=YES;Log("card offset %#llx\n",(unsigned long long)cardOff);}
@interface TraceGuard:NSObject@end
@implementation TraceGuard
-(void)tick:(CADisplayLink*)x{for(NSUInteger i=0;i<count;i++){id o=objects[i];if(!o)continue;Offsets(o);if(!offsetsReady)continue;CGRect f=*(CGRect*)((uint8_t*)(__bridge void*)o+cardOff);if(!isfinite(f.origin.x)||!isfinite(f.origin.y)||f.size.width<1||f.size.height<1)continue;if(!seen[i]||!CGRectEqualToRect(f,prior[i])){Log("%lu card %.1f %.1f %.1f %.1f\n",(unsigned long)i,f.origin.x,f.origin.y,f.size.width,f.size.height);prior[i]=f;seen[i]=YES;}}}
@end
static void ImageAdded(const struct mach_header *header, intptr_t slide){
    if(hooked)return; Dl_info info={0}; if(!dladdr(header,&info)||!info.dli_fname)return;
    if(!strstr(info.dli_fname,"Stheno.dylib"))return;
    // __TEXT vmaddr is zero in the supplied arm64e Stheno slice.
    MSHookFunction((void*)((uintptr_t)header+0x4da60),(void*)HookInit,(void**)&OrigReflectInit);
    hooked=YES;Log("hooked Stheno image slide=%p\n",(void*)slide);
}
__attribute__((constructor))static void Start(void){
    // Called immediately for currently loaded images and for each later image.
    _dyld_register_func_for_add_image(ImageAdded);
    TraceGuard*g=[TraceGuard new];traceLink=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(traceLink,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(),^{[traceLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});
    Log("dyld trace armed\n");
}

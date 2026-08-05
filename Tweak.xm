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
typedef void *(*InitFn)(void*,void*);static InitFn Orig;static __unsafe_unretained id obj[16];static NSUInteger n;static CADisplayLink *dl;static uintptr_t off;static BOOL ready;static uint8_t old[16][32];
static void L(const char*f,...){int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(d<0)return;char b[360];va_list a;va_start(a,f);int z=vsnprintf(b,sizeof b,f,a);va_end(a);if(z>0)write(d,b,(unsigned long)(z<359?z:359));close(d);}
static void *H(void*a,void*b){void*o=Orig(a,b);if(o&&n<16){obj[n++]=(__bridge id)o;L("ctor %lu %p\n",(unsigned long)n,o);}return o;}
static BOOL Good(uintptr_t x){return x>=16&&x<=0x1000&&!(x&7);}
@interface G:NSObject@end
@implementation G
-(void)tick:(CADisplayLink*)x{for(NSUInteger i=0;i<n;i++){id o=obj[i];if(!o)continue;if(!ready){const uintptr_t*v=(const uintptr_t*)((uintptr_t)[o class]+10*sizeof(uintptr_t));if(!Good(v[19]))continue;off=v[19];ready=YES;L("card offset %#llx\n",(unsigned long long)off);}uint8_t *p=(uint8_t*)(__bridge void*)o+off;if(memcmp(old[i],p,32)){memcpy(old[i],p,32);double*q=(double*)p;L("raw %lu %.3f %.3f %.3f %.3f | %02x%02x%02x%02x\n",(unsigned long)i,q[0],q[1],q[2],q[3],p[0],p[1],p[2],p[3]);}}}
@end
static void Add(const struct mach_header*h,intptr_t slide){static BOOL done;if(done)return;Dl_info d={0};if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;MSHookFunction((void*)((uintptr_t)h+0x4da60),(void*)H,(void**)&Orig);done=YES;L("raw trace hooked\n");}
__attribute__((constructor))static void S(void){_dyld_register_func_for_add_image(Add);G*g=[G new];dl=[CADisplayLink displayLinkWithTarget:g selector:@selector(tick:)];objc_setAssociatedObject(dl,@selector(tick:),g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);dispatch_async(dispatch_get_main_queue(),^{[dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];});}

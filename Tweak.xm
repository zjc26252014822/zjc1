#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

extern void MSHookFunction(void *, void *, void **);
typedef CGSize (*TranslationFn)(void *);
static TranslationFn OrigTranslation;
static NSUInteger events;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[260]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<259?n:259)); close(d);
}
/* Stheno's own SwiftUI DragGesture.Value.translation import stub. */
static CGSize Translation(void *value) {
    CGSize r=OrigTranslation(value);
    if(events<160&&isfinite(r.width)&&isfinite(r.height)){
        void *ra=__builtin_return_address(0); Dl_info d={0}; uintptr_t rel=0;
        if(dladdr(ra,&d)&&d.dli_fbase)rel=(uintptr_t)ra-(uintptr_t)d.dli_fbase;
        Log("TRANSLATION %lu value=%p xy=(%.2f,%.2f) caller=%#llx\n",(unsigned long)++events,value,r.width,r.height,(unsigned long long)rel);
    }
    return r;
}
static void Add(const struct mach_header *h, intptr_t slide) {
    static BOOL done; if(done)return; Dl_info d={0};
    if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    MSHookFunction((void *)((uintptr_t)h+0xae9c4),(void *)Translation,(void **)&OrigTranslation);
    done=YES; Log("translation stub trace armed\n");
}
__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace"); _dyld_register_func_for_add_image(Add);
}

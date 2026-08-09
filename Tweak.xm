#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

extern void MSHookFunction(void *, void *, void **);
typedef void (*CandidateFn)(void *, void *);
static CandidateFn OrigA,OrigB,OrigC;
static NSUInteger countA,countB,countC;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[240]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<239?n:239)); close(d);
}
/* Candidate private callbacks that directly read DragGesture.Value.translation. */
static void A(void *value, void *capture){if(countA<40)Log("CAND-A %lu value=%p capture=%p\n",++countA,value,capture);OrigA(value,capture);}
static void B(void *value, void *capture){if(countB<40)Log("CAND-B %lu value=%p capture=%p\n",++countB,value,capture);OrigB(value,capture);}
static void C(void *value, void *capture){if(countC<40)Log("CAND-C %lu value=%p capture=%p\n",++countC,value,capture);OrigC(value,capture);}

static void Add(const struct mach_header *h, intptr_t slide) {
    static BOOL done; if(done)return; Dl_info d={0};
    if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    MSHookFunction((void *)((uintptr_t)h+0x4a780),(void *)A,(void **)&OrigA);
    MSHookFunction((void *)((uintptr_t)h+0x61100),(void *)B,(void **)&OrigB);
    MSHookFunction((void *)((uintptr_t)h+0x7fd88),(void *)C,(void **)&OrigC);
    done=YES; Log("candidate trace armed\n");
}
__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace"); _dyld_register_func_for_add_image(Add);
}

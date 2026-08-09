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

typedef void (*DragChangedFn)(void *, void *, uintptr_t);
static DragChangedFn OrigDragChanged;
static NSUInteger events;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[240]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<239?n:239)); close(d);
}

/* Stheno.dylib + 0x2f894 is its private DragGesture.onChanged callback. */
static void DragChanged(void *value, void *capture, uintptr_t flags) {
    if(events<48){
        events++;
        Log("DRAG %lu value=%p capture=%p flags=%#llx\n",(unsigned long)events,value,capture,(unsigned long long)flags);
    }
    OrigDragChanged(value,capture,flags);
}

static void Add(const struct mach_header *h, intptr_t slide) {
    static BOOL done; if(done)return; Dl_info d={0};
    if(!dladdr(h,&d)||!d.dli_fname||!strstr(d.dli_fname,"Stheno.dylib"))return;
    MSHookFunction((void *)((uintptr_t)h+0x2f894),(void *)DragChanged,(void **)&OrigDragChanged);
    done=YES; Log("drag trace armed slide=%#llx\n",(unsigned long long)slide);
}

__attribute__((constructor))static void Start(void) {
    _dyld_register_func_for_add_image(Add);
}

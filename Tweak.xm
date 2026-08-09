#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[280]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<279?n:279)); close(d);
}

static void FindSceneImplementations(void) {
    SEL target=sel_registerName("_scene:interceptUpdateWithNewSettings:");
    int count=objc_getClassList(NULL,0); Class *classes=(Class *)calloc((size_t)count,sizeof(Class));
    if(!classes)return;
    count=objc_getClassList(classes,count); NSUInteger hits=0;
    for(int i=0;i<count;i++){
        Method m=class_getInstanceMethod(classes[i],target);
        if(!m)continue;
        /* Only log classes that implement the selector themselves, not inherited copies. */
        unsigned n=0; Method *methods=class_copyMethodList(classes[i],&n); BOOL own=NO;
        for(unsigned j=0;j<n;j++)if(method_getName(methods[j])==target){own=YES;break;}
        free(methods); if(!own)continue;
        Log("SCENE-IMPL %s imp=%p\n",class_getName(classes[i]),method_getImplementation(m));
        if(++hits>=24)break;
    }
    Log("scene scan complete hits=%lu\n",(unsigned long)hits); free(classes);
}

__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    dispatch_async(dispatch_get_main_queue(),^{FindSceneImplementations();});
}

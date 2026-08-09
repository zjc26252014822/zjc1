#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void MSHookMessageEx(Class, SEL, IMP, IMP *);
typedef void (*SceneUpdateFn)(id, SEL, id, id);
static SceneUpdateFn OrigSceneUpdate;
static BOOL scanned;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[300]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<299?n:299)); close(d);
}
static BOOL Relevant(const char *s) {
    return s&&(strstr(s,"frame")||strstr(s,"Frame")||strstr(s,"bounds")||strstr(s,"Bounds")||strstr(s,"size")||strstr(s,"Size")||strstr(s,"position")||strstr(s,"Position")||strstr(s,"transform")||strstr(s,"Transform")||strstr(s,"placement")||strstr(s,"Placement")||strstr(s,"coordinate")||strstr(s,"Coordinate"));
}
static void ScanSettingsClass(Class c) {
    NSUInteger total=0;
    for(int level=0;c&&level<6;level++,c=class_getSuperclass(c)){
        Log("SETTINGS-CLASS %s\n",class_getName(c));
        unsigned mc=0; Method *methods=class_copyMethodList(c,&mc);
        for(unsigned i=0;i<mc&&total<120;i++){
            SEL s=method_getName(methods[i]); const char *n=sel_getName(s);
            if(Relevant(n)){Log("METHOD %s %s\n",n,method_getTypeEncoding(methods[i]));total++;}
        }
        free(methods);
        unsigned ic=0; Ivar *ivars=class_copyIvarList(c,&ic);
        for(unsigned i=0;i<ic&&total<160;i++){
            const char *n=ivar_getName(ivars[i]);
            if(Relevant(n)){Log("IVAR %s %s off=%td\n",n,ivar_getTypeEncoding(ivars[i]),ivar_getOffset(ivars[i]));total++;}
        }
        free(ivars);
    }
    Log("settings scan complete candidates=%lu\n",(unsigned long)total);
}

/* Observe the actual settings class once, then only inspect its API. */
static void SceneUpdate(id self, SEL cmd, id scene, id settings) {
    if(!scanned&&settings){scanned=YES;Log("settings runtime class=%s\n",object_getClassName(settings));ScanSettingsClass(object_getClass(settings));}
    OrigSceneUpdate(self,cmd,scene,settings);
}

__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Class c=objc_getClass("SBMainDisplaySceneManager");
    SEL s=sel_registerName("_scene:interceptUpdateWithNewSettings:");
    if(!c||!class_getInstanceMethod(c,s)){Log("Medusa method unavailable\n");return;}
    MSHookMessageEx(c,s,(IMP)SceneUpdate,(IMP *)&OrigSceneUpdate);
    Log("settings API scan armed\n");
}

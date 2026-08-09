#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

extern void MSHookMessageEx(Class, SEL, IMP, IMP *);
typedef void (*SceneUpdateFn)(id, SEL, id, id);
static SceneUpdateFn OrigSceneUpdate;
static NSUInteger events;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[280]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<279?n:279)); close(d);
}

/* The runtime scan confirmed this is Stheno's real Medusa scene-update owner. */
static void SceneUpdate(id self, SEL cmd, id scene, id settings) {
    if(events<80){
        events++;
        Log("MEDUSA %lu mgr=%s scene=%s settings=%s\n",(unsigned long)events,object_getClassName(self),object_getClassName(scene),object_getClassName(settings));
    }
    OrigSceneUpdate(self,cmd,scene,settings);
}

__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Class c=objc_getClass("SBMainDisplaySceneManager");
    SEL s=sel_registerName("_scene:interceptUpdateWithNewSettings:");
    if(!c||!class_getInstanceMethod(c,s)){Log("Medusa method unavailable\n");return;}
    MSHookMessageEx(c,s,(IMP)SceneUpdate,(IMP *)&OrigSceneUpdate);
    Log("Medusa scene trace armed\n");
}

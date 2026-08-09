#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

extern void MSHookMessageEx(Class, SEL, IMP, IMP *);
@interface FBSSceneSettings : NSObject
- (CGRect)frame;
@end

typedef void (*SceneUpdateFn)(id, SEL, id, FBSSceneSettings *);
static SceneUpdateFn OrigSceneUpdate;
static NSUInteger events;

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[280]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<279?n:279)); close(d);
}

/* Log scene-local frame updates. No settings are changed in this version. */
static void SceneUpdate(id self, SEL cmd, id scene, FBSSceneSettings *settings) {
    if(events<120&&settings&&[settings respondsToSelector:@selector(frame)]){
        events++; CGRect f=[settings frame];
        Log("FRAME %lu scene=%p settings=%p cls=%s (%.1f,%.1f %.1fx%.1f)\n",(unsigned long)events,scene,settings,object_getClassName(settings),f.origin.x,f.origin.y,f.size.width,f.size.height);
    }
    OrigSceneUpdate(self,cmd,scene,settings);
}

__attribute__((constructor))static void Start(void) {
    unlink("/var/mobile/Documents/SthenoBounds.trace");
    Class c=objc_getClass("SBMainDisplaySceneManager");
    SEL s=sel_registerName("_scene:interceptUpdateWithNewSettings:");
    if(!c||!class_getInstanceMethod(c,s)){Log("Medusa method unavailable\n");return;}
    MSHookMessageEx(c,s,(IMP)SceneUpdate,(IMP *)&OrigSceneUpdate);
    Log("Medusa frame trace armed\n");
}

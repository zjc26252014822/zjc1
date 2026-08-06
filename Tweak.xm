#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

static IMP OrigSetPosition;
static NSUInteger eventNo;
static BOOL enabled;
static void Log(const char *fmt,...) {
    int fd=open("/var/mobile/Documents/SthenoLayer.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(fd<0)return;
    char b[640];va_list a;va_start(a,fmt);int n=vsnprintf(b,sizeof b,fmt,a);va_end(a);if(n>0)write(fd,b,(unsigned long)(n<639?n:639));close(fd);
}
static BOOL IsCandidate(CALayer *l) {
    if (!l || l.hidden || l.opacity < .01) return NO;
    CGSize z=l.bounds.size;
    // Actual card in the other trace is 303x303. Avoid status/keyboard/fullscreen layers.
    return z.width >= 250 && z.width <= 500 && z.height >= 250 && z.height <= 1000;
}
static void Describe(CALayer *l, char *out, size_t cap) {
    size_t used=0;
    for (int i=0;l&&i<5;i++,l=l.superlayer) {
        CGSize z=l.bounds.size; CGPoint p=l.position;
        int n=snprintf(out+used,cap-used," L%d=%s(%.0fx%.0f@%.0f,%.0f)",i,object_getClassName(l),z.width,z.height,p.x,p.y);
        if(n<0||(size_t)n>=cap-used)break;used+=(size_t)n;
    }
}
static void HookSetPosition(CALayer *self,SEL cmd,CGPoint p) {
    ((void(*)(id,SEL,CGPoint))OrigSetPosition)(self,cmd,p);
    if(!enabled || !IsCandidate(self)) return;
    // Only record the first 120 candidate position changes; no mutation.
    if(eventNo>=120)return; eventNo++;
    char chain[440]={0};Describe(self,chain,sizeof chain);
    Log("E%lu pos=(%.0f,%.0f)%s\n",(unsigned long)eventNo,p.x,p.y,chain);
}
extern void MSHookMessageEx(Class, SEL, IMP, IMP *);
__attribute__((constructor)) static void Start(void) {
    MSHookMessageEx(CALayer.class,@selector(setPosition:),(IMP)HookSetPosition,&OrigSetPosition);
    // Avoid startup noise. User opens/drags Stheno after this delay.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{enabled=YES;Log("layer trace armed\n");});
}

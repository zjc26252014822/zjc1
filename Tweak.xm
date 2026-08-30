#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <objc/message.h>
#include <objc/objc.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[300]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<299?n:279)); close(d);
}

/* Strategy from the reference repo: constrain Stheno windows to screen bounds.
   This build enumerates windows via plain runtime C calls. */
static void ScanWindows(void) {
    typedef id (*SM)(id,SEL);
    typedef id (*SM1)(id,SEL,NSUInteger);
    typedef CGRect (*SF)(id,SEL);
    typedef void (*SFSet)(id,SEL,CGRect);
    SM smFn; SM1 sm1; SF sfFn; SFSet sfSet;
    *(void **)&smFn=(void *)objc_msgSend;
    *(void **)&sm1=(void *)objc_msgSend;
    *(void **)&sfFn=(void *)objc_msgSend;
    *(void **)&sfSet=(void *)objc_msgSend;

    // Get UIApplication windows
    id UIApplicationClass=(id)objc_getClass("UIApplication");
    if(!UIApplicationClass){Log("no UIApplication class\n");return;}
    SEL sa=sel_registerName("sharedApplication"); id app=smFn(UIApplicationClass,sa);
    if(!app){Log("no UIApplication instance\n");return;}
    SEL wp=sel_registerName("windows"); id wins=smFn(app,wp);

    // Get screen bounds for clamping
    id UIScreenClass=(id)objc_getClass("UIScreen");
    SEL ms=sel_registerName("mainScreen"); id screen=smFn(UIScreenClass, ms);
    SEL bd=sel_registerName("bounds"); CGRect screenRect = sfFn(screen, bd);

    SEL fr=sel_registerName("frame");
    NSUInteger idx=[(id)wins count]; NSUInteger i;
    id stheno=nil;
    for(i=0;i<idx;i++){
        SEL oai=sel_registerName("objectAtIndex:"); id w=sm1(wins,oai,i);
        NSString *cn=NSStringFromClass(object_getClass(w));
        CGRect f=sfFn(w,fr);
        // Clamp to screen bounds if this is Stheno window
        if([cn containsString:@"Stheno"]){
            stheno=w;
            CGRect newF = f;
            if(newF.origin.x < 0) newF.origin.x = 0;
            if(newF.origin.y < 0) newF.origin.y = 0;
            if(newF.origin.x + newF.size.width > screenRect.size.width)
                newF.origin.x = screenRect.size.width - newF.size.width;
            if(newF.origin.y + newF.size.height > screenRect.size.height)
                newF.origin.y = screenRect.size.height - newF.size.height;
            if(newF.origin.x != f.origin.x || newF.origin.y != f.origin.y){
                sfSet(w, sel_registerName("setFrame:"), newF);
                Log("Adjusted Stheno WINDOW %p to frame=(%.0f,%.0f %.0fx%.0f)\n", (__bridge void *)w, newF.origin.x, newF.origin.y, newF.size.width, newF.size.height);
            } else {
                Log("WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n", (__bridge void *)w, cn.UTF8String, f.origin.x, f.origin.y, f.size.width, f.size.height);
            }
        } else {
            Log("WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n", (__bridge void *)w, cn.UTF8String, f.origin.x, f.origin.y, f.size.width, f.size.height);
        }
    }
    Log("window count=%lu\n",(unsigned long)idx);
    // Also ensure the stored Stheno window is clamped (in case the loop missed)
    if(sttheno){
        CGRect f=sfFn(sttheno,fr);
        CGRect newF = f;
        if(newF.origin.x < 0) newF.origin.x = 0;
        if(newF.origin.y < 0) newF.origin.y = 0;
        if(newF.origin.x + newF.size.width > screenRect.size.width)
            newF.origin.x = screenRect.size.width - newF.size.width;
        if(newF.origin.y + newF.size.height > screenRect.size.height)
            newF.origin.y = screenRect.size.height - newF.size.height;
        if(newF.origin.x != f.origin.x || newF.origin.y != f.origin.y){
            sfSet(sttheno, sel_registerName("setFrame:"), newF);
            Log("Adjusted STHENO-WINDOW %p to frame=(%.0f,%.0f %.0fx%.0f)\n", (__bridge void *)sttheno, newF.origin.x, newF.origin.y, newF.size.width, newF.size.height);
        } else {
            Log("STHENO-WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n", (__bridge void *)sttheno, NSStringFromClass(object_getClass(sttheno)).UTF8String, f.origin.x, f.origin.y, f.size.width, f.size.height);
        }
    } else {Log("no Stheno-prefixed window found\n");}
}

static void Init(void){unlink("/var/mobile/Documents/SthenoBounds.trace"); Log("scan started\n"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3LL*NSEC_PER_SEC),dispatch_get_main_queue(),^{ScanWindows();}); }
__attribute__((constructor))static void Start(void){ dispatch_async(dispatch_get_main_queue(),^{ Init(); }); }

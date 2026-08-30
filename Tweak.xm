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
   This build enumerates windows via plain runtime C calls. No setFrame hook yet. */
static void ScanWindows(void) {
    typedef id (*SM)(id,SEL); typedef id (*SM1)(id,SEL,NSUInteger); typedef CGRect (*SF)(id,SEL);
    SM smFn; SM1 sm1; SF sfFn;
    *(void **)&smFn=(void *)objc_msgSend;
    *(void **)&sm1=(void *)objc_msgSend;
    *(void **)&sfFn=(void *)objc_msgSend;
    id UIApplicationClass=(id)objc_getClass("UIApplication");
    if(!UIApplicationClass){Log("no UIApplication class\n");return;}
    SEL sa=sel_registerName("sharedApplication"); id app=smFn(UIApplicationClass,sa);
    if(!app){Log("no UIApplication instance\n");return;}
    SEL wp=sel_registerName("windows"); id wins=smFn(app,wp);
    SEL ct=sel_registerName("count"); NSUInteger idx=[(NSArray *)wins count]; NSUInteger i;
    id stheno=nil;
    for(i=0;i<idx;i++){
        SEL oai=sel_registerName("objectAtIndex:"); id w=sm1(wins,oai,i);
        SEL cs=sel_registerName("class"); id wc=smFn(w,cs); NSString *cn=NSStringFromClass((__bridge Class)wc);
        CGRect f=sfFn(w,sel_registerName("frame"));
        Log("WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n",(__bridge void *)w,cn.UTF8String,f.origin.x,f.origin.y,f.size.width,f.size.height);
        if([cn containsString:@"Stheno"]){stheno=w;}
    }
    Log("window count=%lu\n",(unsigned long)idx);
    if(stheno){
        id sc=smFn(stheno,cs); CGRect f=sfFn(stheno,sel_registerName("frame"));
        Log("STHENO-WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n",(__bridge void *)stheno,NSStringFromClass((__bridge Class)sc).UTF8String,f.origin.x,f.origin.y,f.size.width,f.size.height);
    }else{Log("no Stheno-prefixed window found\n");}
}
static void Init(void){unlink("/var/mobile/Documents/SthenoBounds.trace"); Log("scan started\n"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3LL*NSEC_PER_SEC),dispatch_get_main_queue(),^{ScanWindows();}); }
__attribute__((constructor))static void Start(void){ dispatch_async(dispatch_get_main_queue(),^{ Init(); }); }

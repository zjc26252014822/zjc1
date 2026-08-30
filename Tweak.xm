#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

static void Log(const char *f, ...) {
    int d=open("/var/mobile/Documents/SthenoBounds.trace",O_WRONLY|O_CREAT|O_APPEND,0644);
    if(d<0)return;
    char b[300]; va_list a; va_start(a,f); int n=vsnprintf(b,sizeof b,f,a); va_end(a);
    if(n>0)write(d,b,(unsigned long)(n<299?n:299)); close(d);
}

/* Strategy from the reference repo: constrain Stheno windows to screen bounds.
   This build only enumerates window classes to confirm the real class name. */
static void ScanWindows(void) {
    UIWindow *key=nil; BOOL found=0;
    for(UIWindow *w in UIApplication.sharedApplication.windows){
        NSString *cn=NSStringFromClass([w class]); CGRect f=w.frame;
        Log("WINDOW %p class=%s frame=(%.0f,%.0f %.0fx%.0f)\n",w,cn.UTF8String,f.origin.x,f.origin.y,f.size.width,f.size.height);
        if([cn containsString:@"Stheno"]){key=w;found=1;}
    }
    if(found&&key){NSString *cn=NSStringFromClass([key class]);Log("STHENO-WINDOW %p class=%s\n",key,cn.UTF8String);}else Log("no Stheno window in UIApplication.windows\n");
}
static void Init(void){unlink("/var/mobile/Documents/SthenoBounds.trace"); Log("scan started\n"); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3LL*NSEC_PER_SEC),dispatch_get_main_queue(),^{ScanWindows();}); }
__attribute__((constructor))static void Start(void){ dispatch_async(dispatch_get_main_queue(),^{ Init(); }); }

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

static IMP OrigTransform, OrigAffine;
static NSUInteger number; static BOOL armed;
static void Log(const char*f,...){int d=open("/var/mobile/Documents/SthenoTransform.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(d<0)return;char b[420];va_list a;va_start(a,f);int n=vsnprintf(b,sizeof b,f,a);va_end(a);if(n>0)write(d,b,(unsigned long)(n<419?n:419));close(d);}
static BOOL IsHost(CALayer *l){if(!l||l.hidden||l.opacity<.01)return NO;CGSize z=l.bounds.size;return z.width>420&&z.width<440&&z.height>920&&z.height<945;}
static void Chain(CALayer*l,char*out,size_t cap){size_t u=0;for(int i=0;l&&i<4;i++,l=l.superlayer){int n=snprintf(out+u,cap-u," L%d=%s",i,object_getClassName(l));if(n<0||(size_t)n>=cap-u)break;u+=(size_t)n;}}
static void HTransform(CALayer*self,SEL cmd,CATransform3D t){((void(*)(id,SEL,CATransform3D))OrigTransform)(self,cmd,t);if(!armed||!IsHost(self)||number>=160)return;number++;char c[200]={0};Chain(self,c,sizeof c);Log("T%lu m11=%.3f m22=%.3f tx=%.2f ty=%.2f tz=%.2f%s\n",(unsigned long)number,t.m11,t.m22,t.m41,t.m42,t.m43,c);}
static void HAffine(CALayer*self,SEL cmd,CGAffineTransform t){((void(*)(id,SEL,CGAffineTransform))OrigAffine)(self,cmd,t);if(!armed||!IsHost(self)||number>=160)return;number++;char c[200]={0};Chain(self,c,sizeof c);Log("A%lu a=%.3f d=%.3f tx=%.2f ty=%.2f%s\n",(unsigned long)number,t.a,t.d,t.tx,t.ty,c);}
extern void MSHookMessageEx(Class,SEL,IMP,IMP*);
__attribute__((constructor))static void Start(void){MSHookMessageEx(CALayer.class,@selector(setTransform:),(IMP)HTransform,&OrigTransform);MSHookMessageEx(CALayer.class,@selector(setAffineTransform:),(IMP)HAffine,&OrigAffine);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{armed=YES;Log("transform trace armed\n");});}

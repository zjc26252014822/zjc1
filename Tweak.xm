#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>

static IMP OrigTransform,OrigAffine,OrigPosition; static BOOL armed; static NSUInteger events;
static NSHashTable *seen;
static void Log(const char*f,...){int d=open("/var/mobile/Documents/SthenoTransform.trace",O_WRONLY|O_CREAT|O_APPEND,0644);if(d<0)return;char b[700];va_list a;va_start(a,f);int n=vsnprintf(b,sizeof b,f,a);va_end(a);if(n>0)write(d,b,(unsigned long)(n<699?n:699));close(d);}
static BOOL Candidate(CALayer*l){if(!l||l.hidden||l.opacity<.01)return NO;CGSize z=l.bounds.size;return z.width>=250&&z.width<=500&&z.height>=250&&z.height<=1000;}
static void Chain(CALayer*l,char*out,size_t cap){size_t u=0;for(int i=0;l&&i<6;i++,l=l.superlayer){CGSize z=l.bounds.size;CGPoint p=l.position,ap=l.anchorPoint;int n=snprintf(out+u,cap-u," L%d=%s(%.0fx%.0f p%.0f,%.0f a%.2f,%.2f)",i,object_getClassName(l),z.width,z.height,p.x,p.y,ap.x,ap.y);if(n<0||(size_t)n>=cap-u)break;u+=(size_t)n;}}
static void Record(CALayer*l,const char*kind,double a,double b,double c,double d){if(!armed||!Candidate(l)||events>=80)return;BOOL important=(fabs(a-1)>.015||fabs(b-1)>.015||fabs(c)>.5||fabs(d)>.5);if(!important)return;if([seen containsObject:l])return;[seen addObject:l];events++;char ch[450]={0};Chain(l,ch,sizeof ch);Log("E%lu %s %.3f %.3f %.2f %.2f%s\n",(unsigned long)events,kind,a,b,c,d,ch);}
static void HT(CALayer*self,SEL s,CATransform3D t){((void(*)(id,SEL,CATransform3D))OrigTransform)(self,s,t);Record(self,"T",t.m11,t.m22,t.m41,t.m42);}
static void HA(CALayer*self,SEL s,CGAffineTransform t){((void(*)(id,SEL,CGAffineTransform))OrigAffine)(self,s,t);Record(self,"A",t.a,t.d,t.tx,t.ty);}
static void HP(CALayer*self,SEL s,CGPoint p){((void(*)(id,SEL,CGPoint))OrigPosition)(self,s,p);if(!armed||!Candidate(self))return;CALayer*pres=self.presentationLayer;if(!pres)return;CGPoint q=pres.position;if(fabs(q.x-p.x)<.5&&fabs(q.y-p.y)<.5)return;Record(self,"P",1,1,p.x,p.y);}
extern void MSHookMessageEx(Class,SEL,IMP,IMP*);
__attribute__((constructor))static void S(void){seen=[NSHashTable weakObjectsHashTable];MSHookMessageEx(CALayer.class,@selector(setTransform:),(IMP)HT,&OrigTransform);MSHookMessageEx(CALayer.class,@selector(setAffineTransform:),(IMP)HA,&OrigAffine);MSHookMessageEx(CALayer.class,@selector(setPosition:),(IMP)HP,&OrigPosition);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{armed=YES;Log("dedup transform trace armed\n");});}

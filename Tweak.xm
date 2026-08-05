#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>

// Stheno's binary hooks this private scene-update method. The card is positioned
// through FrontBoard scene settings, so enforce bounds immediately after each update.
static IMP OrigSceneUpdate;
static __thread BOOL fixing = NO;
static const CGFloat M=12.0;

static BOOL Clamp(UIView *v, UIView *host) {
    if (!v||v.hidden||v.alpha<.01||v==host||fixing) return NO;
    CGRect h=host.bounds,f=v.frame; UIEdgeInsets s=host.safeAreaInsets;
    if (f.size.width<120||f.size.height<120||f.size.width>h.size.width*1.3||f.size.height>h.size.height*1.3) return NO;
    CGFloat l=s.left+M,r=h.size.width-s.right-M,t=s.top+M,b=h.size.height-s.bottom-M,dx=0,dy=0;
    if(CGRectGetMinX(f)<l)dx=l-CGRectGetMinX(f); else if(CGRectGetMaxX(f)>r)dx=r-CGRectGetMaxX(f);
    if(CGRectGetMinY(f)<t)dy=t-CGRectGetMinY(f); else if(CGRectGetMaxY(f)>b)dy=b-CGRectGetMaxY(f);
    if(!dx&&!dy)return NO; fixing=YES; CGPoint c=v.center;c.x+=dx;c.y+=dy;v.center=c;fixing=NO;return YES;
}
static BOOL Scan(UIView *v,UIView *host,NSUInteger d){ if(d>14)return NO; for(UIView *x in [v.subviews reverseObjectEnumerator])if(Scan(x,host,d+1))return YES; return Clamp(v,host); }
static void CorrectController(id controller) {
    if(![controller respondsToSelector:@selector(view)])return;
    UIView *root=((id(*)(id,SEL))objc_msgSend)(controller,@selector(view));
    if(root&&root.superview) Scan(root,root.superview,0);
}
// Selector from Stheno.dylib: _scene:interceptUpdateWithNewSettings:
static void HookSceneUpdate(id self,SEL cmd,id scene,id settings){ ((void(*)(id,SEL,id,id))OrigSceneUpdate)(self,cmd,scene,settings); CorrectController(self); }
static void Install(void){ static Class c; if(c)return; c=NSClassFromString(@"SBDeviceApplicationSceneViewController"); if(!c)return; SEL s=NSSelectorFromString(@"_scene:interceptUpdateWithNewSettings:"); if([c instancesRespondToSelector:s]) MSHookMessageEx(c,s,(IMP)HookSceneUpdate,&OrigSceneUpdate); }
%ctor{dispatch_async(dispatch_get_main_queue(),^{for(NSUInteger i=1;i<=40;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(),^{Install();});});}

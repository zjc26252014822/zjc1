#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>

static IMP OrigHidden, OrigFrame;
static BOOL shown = NO;
static void Toast(UIWindow *w, NSString *event) {
    if (shown || !w) return; shown=YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect f=w.frame; CGAffineTransform t=w.transform;
        NSString *s=[NSString stringWithFormat:@"Stheno captured via %@\nf=(%.0f,%.0f %.0fx%.0f)\ntx=%.1f ty=%.1f\nchildren=%lu",event,f.origin.x,f.origin.y,f.size.width,f.size.height,t.tx,t.ty,(unsigned long)w.subviews.count];
        UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(35,115,360,105)]; l.numberOfLines=0; l.text=s; l.textAlignment=NSTextAlignmentCenter; l.font=[UIFont systemFontOfSize:14]; l.textColor=UIColor.whiteColor; l.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:.82]; l.layer.cornerRadius=12; l.layer.masksToBounds=YES; [w addSubview:l];
        [UIView animateWithDuration:.25 delay:4 options:0 animations:^{l.alpha=0;} completion:^(__unused BOOL done){[l removeFromSuperview];}];
    });
}
static void SetHidden(UIWindow *w, SEL cmd, BOOL hidden) { ((void(*)(id,SEL,BOOL))OrigHidden)(w,cmd,hidden); if(!hidden) Toast(w,@"setHidden:NO"); }
static void SetFrame(UIWindow *w, SEL cmd, CGRect frame) { ((void(*)(id,SEL,CGRect))OrigFrame)(w,cmd,frame); Toast(w,@"setFrame:"); }
static void Install(void) {
    static Class c; if(c)return; c=NSClassFromString(@"Stheno.SthenoWindow"); if(!c)return;
    MSHookMessageEx(c,@selector(setHidden:),(IMP)SetHidden,&OrigHidden);
    MSHookMessageEx(c,@selector(setFrame:),(IMP)SetFrame,&OrigFrame);
}
%ctor { dispatch_async(dispatch_get_main_queue(),^{for(NSUInteger i=1;i<=40;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*NSEC_PER_SEC/2),dispatch_get_main_queue(),^{Install();});}); }

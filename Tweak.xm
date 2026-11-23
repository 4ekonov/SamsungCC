#import "SCC.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kSCCKey = &kSCCKey;

static BOOL SCCEnabled(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"];
    id v = [d objectForKey:@"enabled"];
    return v ? [v boolValue] : YES;
}

@interface CCUIModularControlCenterOverlayViewController : UIViewController
@end

static void SCCDismiss(UIViewController *vc) {
    // пробуем несколько вариантов, т.к. сигнатуры отличаются между iOS 15/16/17
    SEL s1 = NSSelectorFromString(@"dismissAnimated:");
    if ([vc respondsToSelector:s1]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, s1, YES);
        return;
    }
    Class c = objc_getClass("SBControlCenterController");
    id ctl = nil;
    if ([c respondsToSelector:NSSelectorFromString(@"sharedInstance")])
        ctl = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedInstance"));
    if ([ctl respondsToSelector:s1])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(ctl, s1, YES);
}

%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidLayoutSubviews {
    %orig;
    SCCView *scc = objc_getAssociatedObject(self, kSCCKey);
    if (!SCCEnabled()) {
        // твик выключен в настройках: вернуть оригинальный ЦУ
        [scc removeFromSuperview];
        for (UIView *v in self.view.subviews) v.hidden = NO;
        return;
    }
    if (!scc) {
        scc = [[SCCView alloc] initWithFrame:self.view.bounds];
        scc.presenter = self;
        __weak UIViewController *wself = self;
        scc.dismissBlock = ^{ if (wself) SCCDismiss(wself); };
        objc_setAssociatedObject(self, kSCCKey, scc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (scc.superview != self.view) [self.view addSubview:scc];
    scc.frame = self.view.bounds;
    [self.view bringSubviewToFront:scc];
    // прячем оригинальный контрольный центр
    for (UIView *v in self.view.subviews) if (v != scc) v.hidden = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SCCView *scc = objc_getAssociatedObject(self, kSCCKey);
    [scc willShow];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SCCView *scc = objc_getAssociatedObject(self, kSCCKey);
    [scc didHide];
}

%end

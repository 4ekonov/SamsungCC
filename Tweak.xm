#import "SCC.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface CCUIModularControlCenterOverlayViewController : UIViewController
@end

static BOOL SCCDeviceUnlocked(void) {
    Class c = objc_getClass("SBLockScreenManager");
    SEL si = NSSelectorFromString(@"sharedInstance");
    SEL sl = NSSelectorFromString(@"isUILocked");
    if (![c respondsToSelector:si]) return NO;
    id m = ((id (*)(id, SEL))objc_msgSend)(c, si);
    if (![m respondsToSelector:sl]) return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(m, sl);
}

// --- запуск: создать окно с жестами ---
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [[SCCManager shared] setup]; });
}
%end

// --- системный пункт управления -> наша шторка (быстрые настройки) ---
%hook SBControlCenterController
- (void)presentAnimated:(BOOL)a {
    if (SCCIsEnabled()) { [[SCCManager shared] openPage:1 animated:YES]; return; }
    %orig;
}
- (void)presentAnimated:(BOOL)a completion:(id)c {
    if (SCCIsEnabled()) { [[SCCManager shared] openPage:1 animated:YES]; return; }
    %orig;
}
%end

%hook CCUIModularControlCenterOverlayViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    self.view.hidden = SCCIsEnabled();
}
%end

// --- системная шторка уведомлений -> наша (только на разблокированном экране, сразу после касания верха) ---
%hook SBCoverSheetPresentationManager
- (void)setCoverSheetPresented:(BOOL)p animated:(BOOL)a withCompletion:(id)c {
    if (p && SCCIsEnabled() && SCCDeviceUnlocked() && [[SCCManager shared] topTouchRecent]) {
        [[SCCManager shared] openPage:0 animated:YES];
        %orig(NO, NO, c);
        return;
    }
    %orig;
}
%end

// --- сбор уведомлений для нашей шторки ---
%hook NCNotificationMasterList
- (void)insertNotificationRequest:(id)r { %orig; SCCNotifInsert(r, self); }
- (void)modifyNotificationRequest:(id)r { %orig; SCCNotifInsert(r, self); }
- (void)removeNotificationRequest:(id)r { %orig; SCCNotifRemove(r); }
%end

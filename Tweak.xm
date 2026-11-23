#import "SCC.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <strings.h>

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

// ---------------------------------------------------------------
// Полное отключение стоковых жестов пункта управления и шторки
// ---------------------------------------------------------------
static NSHashTable *gKilled;
static const void *kKilledKey = &kKilledKey;

static BOOL NameHas(const char *n, const char *s) { return n && s && strcasestr(n, s) != NULL; }

static void SCCConsider(UIGestureRecognizer *g, id target, SEL action) {
    if (!g || !target || !action) return;
    const char *cn = object_getClassName(target);
    const char *an = sel_getName(action);
    if (!cn || !an) return;

    BOOL cc = NameHas(cn, "ControlCenter") || NameHas(cn, "CCUI");
    BOOL cs = NameHas(cn, "CoverSheet") || NameHas(cn, "DashBoard") || NameHas(cn, "NotificationCenter");
    BOOL sg = NameHas(cn, "SystemGesture");
    if (!(cc || cs || sg)) return;

    BOOL kill = NO;
    if (cc) kill = NameHas(an, "present") || (NameHas(an, "show") && NameHas(an, "control"));
    if (cs) kill = NameHas(an, "present") || (NameHas(an, "show") && (NameHas(an, "cover") || NameHas(an, "notif")));
    kill = kill && SCCIsEnabled();

    SCCLog([NSString stringWithFormat:@"gesture %s target=%s action=%s kill=%d", object_getClassName(g), cn, an, kill]);

    if (kill) {
        objc_setAssociatedObject(g, kKilledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gKilled) gKilled = [NSHashTable weakObjectsHashTable];
        [gKilled addObject:g];
        g.enabled = NO;
    }
}

%hook UIGestureRecognizer
- (id)initWithTarget:(id)t action:(SEL)a {
    id r = %orig;
    if (r) SCCConsider(r, t, a);
    return r;
}
- (void)addTarget:(id)t action:(SEL)a {
    %orig;
    SCCConsider(self, t, a);
}
- (void)setEnabled:(BOOL)e {
    if (e && objc_getAssociatedObject(self, kKilledKey) && SCCIsEnabled()) e = NO;
    %orig(e);
}
%end

// для диагностики: какие системные жесты регистрируются
%hook SBSystemGestureManager
- (void)addGestureRecognizer:(id)g withType:(unsigned long long)t {
    SCCLog([NSString stringWithFormat:@"systemGesture type=%llu class=%s", t, object_getClassName(g)]);
    %orig;
}
%end

static void SCCPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL en = SCCIsEnabled();
        for (UIGestureRecognizer *g in gKilled.allObjects) [g setEnabled:!en];
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SCCPrefsChanged,
        CFSTR("com.samsungcc.tweak/prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

// ---------------------------------------------------------------
// Запуск: создать окно с нашими жестами
// ---------------------------------------------------------------
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [[SCCManager shared] setup]; });
}
%end

// ---------------------------------------------------------------
// Запасные перехваты: если стоковый ЦУ / шторка всё же попытаются открыться
// ---------------------------------------------------------------
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

// ---------------------------------------------------------------
// Сбор уведомлений для нашей шторки
// ---------------------------------------------------------------
%hook NCNotificationMasterList
- (void)insertNotificationRequest:(id)r { %orig; SCCNotifInsert(r, self); }
- (void)modifyNotificationRequest:(id)r { %orig; SCCNotifInsert(r, self); }
- (void)removeNotificationRequest:(id)r { %orig; SCCNotifRemove(r); }
%end

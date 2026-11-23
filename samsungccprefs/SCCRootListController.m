#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SCCRootListController : PSListController
@end

@implementation SCCRootListController
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)resetLayout {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.samsungcc.tweak"];
    [d removeObjectForKey:@"SCC.layout.v1"];
    [d synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.samsungcc.tweak/reset"), NULL, NULL, YES);
}
@end

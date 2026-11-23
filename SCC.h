#import <UIKit/UIKit.h>

@interface SCCView : UIView
/// VC, из которого показываются алерты (Add / Power / Reset)
@property (nonatomic, weak) UIViewController *presenter;
/// Закрыть контрольный центр
@property (nonatomic, copy) void (^dismissBlock)(void);
- (void)dismissCC;
- (void)willShow;   // обновить состояния
- (void)didHide;    // выйти из режима редактирования
@end

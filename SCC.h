#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
BOOL SCCIsEnabled(void);
void SCCNotifInsert(id request, id master);
void SCCNotifRemove(id request);
void SCCLog(NSString *msg);
#ifdef __cplusplus
}
#endif

/// Шторка (две страницы: 0 = уведомления, 1 = быстрые настройки)
@interface SCCView : UIView
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) void (^closeBlock)(void);
@property (nonatomic, readonly) NSInteger currentPage;
- (void)prepareForPage:(NSInteger)page;
- (void)showPage:(NSInteger)page animated:(BOOL)animated;
- (void)setProgress:(CGFloat)p;
- (void)animateOpen:(BOOL)open velocity:(CGFloat)v completion:(void (^)(void))completion;
- (void)dismissCC;
- (void)willShow;
- (void)didHide;
- (void)reloadNotifications;
@end

/// Управляет окном сверху и жестами (слева сверху = уведомления, справа сверху = быстрые настройки)
@interface SCCManager : NSObject
@property (nonatomic, readonly) BOOL isOpen;
+ (instancetype)shared;
- (void)setup;
- (void)openPage:(NSInteger)page animated:(BOOL)animated;
- (void)closeAnimated:(BOOL)animated;
- (void)notesChanged;
- (BOOL)topTouchRecent;
@end

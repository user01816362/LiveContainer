#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic, null_unspecified) AppSceneViewController* appSceneVC;
@property(nonatomic, null_unspecified) UIStackView *view;
@property(nonatomic, null_unspecified) UINavigationBar *navigationBar;
@property(nonatomic, null_unspecified) UINavigationItem *navigationItem;
@property(nonatomic, null_unspecified) UIView *resizeHandle;
@property(nonatomic, null_unspecified) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype _Null_unspecified)initWindowName:(NSString * _Null_unspecified)windowName bundleId:(NSString * _Null_unspecified)bundleId dataUUID:(NSString * _Null_unspecified)dataUUID rootVC:(UIViewController * _Null_unspecified)rootVC;
- (void)minimizeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;
@property(nonatomic, copy, nullable) void (^ NS_SWIFT_SENDABLE pidAvailableHandler)(NSNumber * _Nullable pid, NSError * _Nullable error);
@end


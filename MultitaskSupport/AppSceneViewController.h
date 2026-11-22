//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "FoundationPrivate.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

NS_SWIFT_UI_ACTOR
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(nonnull AppSceneViewController*)vc;
- (void)appSceneVC:(nonnull AppSceneViewController*)vc didInitializeWithError:(nullable NSError*)error;
@optional
- (void)appSceneVC:(nonnull AppSceneViewController*)vc didUpdateFromSettings:(nonnull UIMutableApplicationSceneSettings *)settings transitionContext:(nullable id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(nonnull AppSceneViewController *)vc;
@end

@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic, null_unspecified) NSString* bundleId;
@property(nonatomic, null_unspecified) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic, null_unspecified) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic, readonly) BOOL hasSpoofedViewport;
@property(nonatomic, readonly) CGSize emulatedViewportSize;
@property(nonatomic, readonly, nullable) NSString *emulatedViewportLabel;
@property(nonatomic) BOOL emulatedViewportEnabled;
- (void)applyViewportLayoutForAvailableSize:(CGSize)availableSize interfaceOrientation:(UIInterfaceOrientation)orientation;
@property(nonatomic, nullable) UIView* contentView;
@property(nonatomic, nullable) _UIScenePresenter *presenter;
@property(nonatomic, nullable) _UISceneHostingController *hostingController;
- (instancetype _Null_unspecified)initWithBundleId:(NSString * _Null_unspecified)bundleId dataUUID:(NSString * _Null_unspecified)dataUUID delegate:(id<AppSceneViewControllerDelegate> _Null_unspecified)delegate;
- (instancetype _Null_unspecified)initWithBundleId:(NSString * _Null_unspecified)bundleId dataUUID:(NSString * _Null_unspecified)dataUUID debugMode:(BOOL)debugMode delegate:(id<AppSceneViewControllerDelegate> _Null_unspecified)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^ _Null_unspecified)(UIMutableApplicationSceneSettings * _Null_unspecified settings))block;
- (void)updateSettingsWithBlock:(void (^ _Null_unspecified)(UIMutableApplicationSceneSettings * _Null_unspecified settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString * _Null_unspecified)urlString;
- (void)handleStatusBarTapAction:(nonnull UIAction *)action;
@end


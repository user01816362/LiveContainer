//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@property(nonatomic) BOOL isTerminating;
@property(nonatomic) BOOL isRegisteredForSceneDiff;
@end

static UIScreen *LCFallbackActiveScreen(void) {
    UIScreen *fallbackScreen = nil;
    for (UISceneSession *session in UIApplication.sharedApplication.openSessions) {
        if (![session.scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)session.scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene.screen;
        }
        if (!fallbackScreen) {
            fallbackScreen = windowScene.screen;
        }
    }
    return fallbackScreen;
}

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    return [self initWithBundleId:bundleId dataUUID:dataUUID debugMode:NO delegate:delegate];
}

- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID debugMode:(BOOL)debugMode delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) {
        return nil;
    }
    if (bundleId.length == 0 || dataUUID.length == 0) {
        NSError *error = [NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Missing bundle identifier or container identifier."}];
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(!_extension || error) {
        [delegate appSceneVC:self didInitializeWithError:error ?: [NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize LiveProcess extension."}]];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme ?: @"livecontainer",
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
        @"debugMode": @(debugMode),
        @"debugStudioHosted": @(debugMode),
    }.mutableCopy;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        if(bookmarkData) {
            [bookmarks addObject:bookmarkData];
        }
    } else {
        bool isSharedApp = false;
        NSBundle* bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
        // when mutlitask with private app, we can restrict its sandbox to only its own container
        if (!isSharedApp) {
            NSURL *dataURL = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
            NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
            NSData* bundleBookmark = [bundle.bundleURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(bundleBookmark) {
                [bookmarks addObject:bundleBookmark];
            }
            NSData* containerBookmark = [dataURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(containerBookmark) {
                [bookmarks addObject:containerBookmark];
            }
            NSData* tweaksBookmark = [tweaksURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(tweaksBookmark) {
                [bookmarks addObject:tweaksBookmark];
            }
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf appTerminationCleanUp];
            [strongSelf.delegate appSceneVC:strongSelf didInitializeWithError:error];
        });
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appTerminationCleanUp];
        });
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (strongSelf.isTerminating || strongSelf.isAppTerminationCleanUpCalled) {
                if (identifier) {
                    [strongSelf.extension _kill:SIGTERM];
                }
                [strongSelf appTerminationCleanUp];
                return;
            }
            if(identifier) {
                [MultitaskManager registerMultitaskContainerWithContainer:strongSelf.dataUUID];
                strongSelf.identifier = identifier;
                strongSelf.pid = [strongSelf.extension pidForRequestIdentifier:strongSelf.identifier];
                [strongSelf.delegate appSceneVC:strongSelf didInitializeWithError:nil];
                [strongSelf setUpAppPresenter];
            } else {
                NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
                [strongSelf.delegate appSceneVC:strongSelf didInitializeWithError:error];
            }
        });
    }];
    
    return self;
}

- (void)unregisterHostSceneDiffAction {
    if (!self.sceneID) {
        self.hostScene = nil;
        self.isRegisteredForSceneDiff = NO;
        return;
    }
    UIWindowScene *sceneToUnregister = self.hostScene ?: (self.isViewLoaded ? self.view.window.windowScene : nil);
    if (sceneToUnregister) {
        [sceneToUnregister _unregisterSettingsDiffActionArrayForKey:self.sceneID];
    }
    self.hostScene = nil;
    self.isRegisteredForSceneDiff = NO;
}

- (void)setUpAppPresenter {
    if (self.isTerminating || self.isAppTerminationCleanUpCalled || self.pid <= 0) {
        return;
    }
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    if (!processHandle || !processHandle.identity) {
        [self appTerminationCleanUp];
        return;
    }
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        UIScreen *targetScreen = self.view.window.windowScene.screen ?: self.hostScene.screen ?: LCFallbackActiveScreen();
        if (targetScreen) {
            settings.displayConfiguration = targetScreen.displayConfiguration;
        }
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    // Use _UISceneHostingController (iOS 26/27+)
    _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
    config.sceneSpecification = specification;
    self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
    UIViewController *sceneVC = self.hostingController.sceneViewController;
    if (!sceneVC) {
        [self appTerminationCleanUp];
        return;
    }
    // Use sceneViewController.view rather than sceneView so the child VC owns its responder chain cleanly
    self.contentView = sceneVC.view;
    self.contentView.clipsToBounds = NO;
    @try {
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
    } @catch (NSException *exception) {
        NSLog(@"[LC] Unable to read _scenePresenter via KVC: %@", exception);
    }
    self.sceneID = self.presenter.identifier;
    FBScene *scene = self.presenter.scene;
    [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
    }];
    
    /// Fix keyboard focus by setting up event deferring extension.
    _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
    if (deferringComponent) {
        @try {
            /// Replicate -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
        } @catch (NSException *exception) {
            NSLog(@"[LC] Unable to set _firstResponderTrackingSelectionPath: %@", exception);
        }
        deferringComponent.grantBehavior = 2;
        deferringComponent.selectionRequestBehavior = 2;
    }
    
    // Now it's time to get the initial settings from decorated VC
    [self.delegate appSceneVCWillActivateScene:self];
    [self addChildViewController:sceneVC];
    
    // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
    [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
    [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf appTerminationCleanUp];
        });
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    self.hostScene = self.view.window.windowScene;
    if (self.hostScene && self.sceneID && !self.isTerminating && !self.isAppTerminationCleanUpCalled) {
        [self.hostScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
        self.isRegisteredForSceneDiff = YES;
    }
}

- (void)terminate {
    self.isTerminating = YES;
    if (NSThread.isMainThread) {
        [self unregisterHostSceneDiffAction];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self unregisterHostSceneDiffAction];
        });
    }
    if(self.isAppRunning) {
        NSExtension *ext = self.extension;
        int targetPid = self.pid;
        [ext _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (targetPid > 0 && getpgid(targetPid) > 0) {
                [ext _kill:SIGKILL];
            }
        });
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if (self.isTerminating || self.isAppTerminationCleanUpCalled || !self.isAppRunning) {
        [self unregisterHostSceneDiffAction];
        [self appTerminationCleanUp];
        return;
    }
    if (!diff || !self.presenter || !self.presenter.scene) {
        return;
    }
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken || self.isTerminating || self.isAppTerminationCleanUpCalled || !self.presenter) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.effectiveGeometry.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    // Properties are applied through _UISceneHostingViewController (or pre-scene setup before contentView exists)
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        // Discard position
        frame.origin = CGPointZero;
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    self.isTerminating = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self unregisterHostSceneDiffAction];
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
            self.sceneID = nil;
        }
        if(self.hostingController) {
            [self.hostingController invalidate];
            [self.hostingController.sceneViewController willMoveToParentViewController:nil];
            [self.hostingController.sceneViewController.view removeFromSuperview];
            [self.hostingController.sceneViewController removeFromParentViewController];
            self.hostingController = nil;
        }
        self.contentView = nil;
        self.presenter = nil;

        [LCSharedUtils wipeStrictContainerForDataUUIDIfNeeded:self.dataUUID];
        
        id<AppSceneViewControllerDelegate> delegate = self.delegate;
        self.delegate = nil;
        [delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    (void)enabled;
    // Keep the hosted scene foregrounded so FBSSceneObserver does not push unwanted resign-active transitions
    [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.foreground = YES;
        settings.deactivationReasons = 0;
    }];
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        [self unregisterHostSceneDiffAction];
        if (!self.isAppRunning || self.isTerminating || self.isAppTerminationCleanUpCalled) {
            self.delegate = nil;
        }
    } else if (!self.isTerminating && !self.isAppTerminationCleanUpCalled) {
        self.hostScene = newWindow.windowScene;
        if (self.sceneID && self.hostScene && !self.isRegisteredForSceneDiff) {
            [self.hostScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
            self.isRegisteredForSceneDiff = YES;
        }
    }
}

- (void)dealloc {
    UIWindowScene *hostScene = _hostScene;
    NSString *sceneID = _sceneID;
    _hostScene = nil;
    _isRegisteredForSceneDiff = NO;
    if (hostScene && sceneID) {
        if ([NSThread isMainThread]) {
            [hostScene _unregisterSettingsDiffActionArrayForKey:sceneID];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [hostScene _unregisterSettingsDiffActionArrayForKey:sceneID];
            });
        }
    }
}

- (void)openURLScheme:(NSString *)urlString {
    if (urlString.length == 0) {
        return;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
#pragma clang diagnostic pop
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

@end
 

//
//  PiPManager.h
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
@import Foundation;
@import AVKit;
@import UIKit;
#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

NS_SWIFT_UI_ACTOR
@interface PiPManager : NSObject<AVPictureInPictureControllerDelegate>
@property (class, nonatomic, readonly) PiPManager *shared;
@property (nonatomic, readonly) bool isPiP;
- (BOOL)isPiPWithVC:(AppSceneViewController*)vc;
- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc;
- (void)stopPiP;
- (void)startPiPWithVC:(AppSceneViewController*)vc;

@end

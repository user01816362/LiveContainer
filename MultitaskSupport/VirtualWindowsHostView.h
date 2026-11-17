//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;

@interface VirtualWindowsHostView: UIView
@property(nonatomic) BOOL shouldForwardTapAction;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
@end

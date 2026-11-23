//
//  ResizeHandleView.m
//  LiveContainer
//
//  Created by Duy Tran on 2/6/25.
//
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"

@interface ResizeHandleView ()
@property (nonatomic, strong) LCLiquidGlassResizeHandleHostingView *glassHostingView;
@property (nonatomic, assign) BOOL isPanResizing;
@property (nonatomic, assign) BOOL isHovering;
@end

@implementation ResizeHandleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;

        LCLiquidGlassResizeHandleHostingView *hostingView = [[LCLiquidGlassResizeHandleHostingView alloc] initWithFrame:self.bounds];
        hostingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:hostingView];
        _glassHostingView = hostingView;

        UIHoverGestureRecognizer *hoverGesture = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(handleHover:)];
        [self addGestureRecognizer:hoverGesture];
    }
    return self;
}

- (void)handleHover:(UIHoverGestureRecognizer *)recognizer {
    self.isHovering = (recognizer.state == UIGestureRecognizerStateBegan || recognizer.state == UIGestureRecognizerStateChanged);
    [self updateVisualActiveState];
}

- (void)setResizing:(BOOL)resizing {
    self.isPanResizing = resizing;
    [self updateVisualActiveState];
}

- (void)setWindowCornerRadius:(CGFloat)cornerRadius {
    [self.glassHostingView setWindowCornerRadius:cornerRadius];
}

- (void)updateVisualActiveState {
    [self.glassHostingView setResizing:(self.isPanResizing || self.isHovering)];
}

@end

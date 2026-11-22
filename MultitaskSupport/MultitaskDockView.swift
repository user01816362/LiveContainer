//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
@MainActor
final class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = infoCacheByUUID[dataUUID] {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                infoCacheByUUID[dataUUID] = appInfo
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = infoCacheByName[appName] {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    infoCacheByName[appName] = appInfo
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        infoCacheByUUID.removeAll()
        infoCacheByName.removeAll()
    }
}

// MARK: - App Model for Dock
@MainActor @objc final class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@MainActor @objc public final class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var isAutoHidden: Bool = false
    @Published var settingsChanged: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?
    private var autoHideTask: Task<Void, Never>?
    private weak var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
    private weak var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
    private var isUserInteracting: Bool = false
    private var lastActivityResetTime: CFTimeInterval = 0

    private var isAutoHideEnabled: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: "LCAutoHideMultitaskDock")
    }

    private var autoHideDelaySeconds: Double {
        let stored = LCUtils.appGroupUserDefault.double(forKey: "LCAutoHideMultitaskDockDelay")
        return stored >= 1.0 ? stored : 3.0
    }

    private var isEffectivelyHidden: Bool {
        isDockHidden || isAutoHidden
    }

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        static let iconToWidthRatio: CGFloat = 0.75
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction
        static var dockHiddenOffset: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans * 2 / 3
                } else {
                    return 50
                }
            }
        }
        static var hideGestureThreshold: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans / 5
                } else {
                    return 16
                }
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let buttonSize = calculateButtonSize(for: userWidth)
            let baseHeight = expandedDockBaseHeight(for: userWidth, buttonSize: buttonSize)
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let spacingCount = max(self.apps.count + 1, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize * 2 + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    public var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ??
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    private var safeAreaHeight: CGFloat {
        let bounds = keyWindow?.bounds ?? .zero
        return max(0, bounds.height - safeAreaInsets.top - safeAreaInsets.bottom)
    }
    
    override init() {
        super.init()
        keyWindow?.rootViewController?.view.subviews.first?.addSubview(self.windowHostingView)
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc nonisolated private func deviceOrientationDidChange() {
        Task { @MainActor [weak self] in
            guard let self, self.isVisible else { return }
            self.updateDockFrame()
        }
    }
    
    @objc nonisolated private func userDefaultsDidChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.settingsChanged.toggle()
            if !self.isAutoHideEnabled {
                self.cancelAutoHideTimer()
                if self.isAutoHidden {
                    self.isAutoHidden = false
                    self.setupEdgeGestureRecognizers()
                }
            } else if self.isVisible && self.isCollapsed && !self.isAutoHidden && !self.isDockHidden {
                self.scheduleAutoHideIfNeeded()
            }
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    private func setupDockView() {
        let dockView = AnyView(MultitaskDockSwiftView()
            .environmentObject(self))
        
        self.hostingController = UIHostingController(rootView: dockView)
        self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
        self.hostingController?.view.backgroundColor = .clear
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController,
              let screenBounds = keyWindow?.bounds else { return }
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX(isDockHidden: self.isEffectivelyHidden, 
                                    isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)
        
        applyNewFrame(newFrame, for: hostingController, animated: animated)
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }
            
            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }
        
        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        self.apps.removeAll { $0.appUUID == appUUID }
        
        if self.apps.isEmpty {
            self.hideDock()
        } else if self.isVisible {
            self.updateDockFrame()
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow else { return }
        
        self.isVisible = true
        self.isAutoHidden = false
        
        let screenBounds = keyWindow.bounds
        let currentDockWidth = self.dockWidth
        let initialHeight = Constants.initialDockShowHeight
        
        // If not already in view hierarchy, add it
        if hostingController.view.superview == nil {
            keyWindow.addSubview(hostingController.view)
            hostingController.view.frame = CGRect(
                x: screenBounds.width - currentDockWidth,
                y: (screenBounds.height - initialHeight) / 2,
                width: currentDockWidth,
                height: initialHeight
            )
        }
        
        self.updateDockFrame(animated: false) 
        
        self.setupEdgeGestureRecognizers()
        
        hostingController.view.alpha = 0
        let initialScale = Constants.initialScale
        hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.showHideSpringDamping,
            initialSpringVelocity: Constants.showHideSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.alpha = 1
            hostingController.view.transform = .identity
        }
        self.scheduleAutoHideIfNeeded()
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        self.cancelAutoHideTimer()
        self.isAutoHidden = false
        self.removeTrackedEdgeGestures()
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.showHideSpringDamping,
            initialSpringVelocity: Constants.showHideSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.alpha = 0
            let finalScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
            // Move off-screen to hide, but keep in view hierarchy
            let screenBounds = self.keyWindow?.bounds ?? .zero
            let currentDockWidth = self.dockWidth
            let targetX = self.calculateTargetX(isDockHidden: true, isOnRightSide: hostingController.view.frame.midX > screenBounds.width / 2, dockWidth: currentDockWidth, screenWidth: screenBounds.width)
            let targetY = hostingController.view.frame.origin.y // Keep current Y
            hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
        } completion: { _ in
            self.isVisible = false
            hostingController.view.transform = .identity
        }
    }

    private func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    func scheduleAutoHideIfNeeded() {
        cancelAutoHideTimer()
        guard isVisible, isCollapsed, isAutoHideEnabled, !isUserInteracting, !isAutoHidden, !isDockHidden else {
            return
        }
        let delay = autoHideDelaySeconds
        autoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard self.isVisible, self.isCollapsed, self.isAutoHideEnabled, !self.isUserInteracting, !self.isDockHidden else {
                return
            }
            self.isAutoHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }

    @objc public func noteHostTouchActivity() {
        let now = CACurrentMediaTime()
        if !isAutoHidden && (now - lastActivityResetTime) < 0.25 {
            return
        }
        noteUserActivity(wakeDock: true)
    }

    func noteUserActivity(wakeDock: Bool = true) {
        guard isVisible else { return }
        if wakeDock && isAutoHidden {
            isAutoHidden = false
            updateDockFrame()
            setupEdgeGestureRecognizers()
        }
        lastActivityResetTime = CACurrentMediaTime()
        scheduleAutoHideIfNeeded()
    }

    func setUserInteracting(_ interacting: Bool) {
        isUserInteracting = interacting
        if interacting {
            cancelAutoHideTimer()
            if isAutoHidden {
                isAutoHidden = false
                updateDockFrame()
                setupEdgeGestureRecognizers()
            }
        } else {
            scheduleAutoHideIfNeeded()
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        guard let screenWidth = keyWindow?.bounds.width else { return false }
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)
        
        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isEffectivelyHidden else { return false }
            if self.isDockHidden {
                self.showDockFromHidden()
            } else {
                self.noteUserActivity(wakeDock: true)
            }
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }
    
    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        
        guard !self.isDockHidden, horizontalDistance > verticalDistance,
              let screenWidth = keyWindow?.bounds.width else {
            return false
        }
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        guard !self.isDockHidden else { return false }
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
        }
    }
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        self.noteUserActivity(wakeDock: true)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                animateViewAppearance(targetView, from: center, in: window)
                return true
            }
        }
        
        return false
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            
            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)
        
        self.apps.append(appModel)
        
        if self.apps.count == 1 {
            self.showDock()
        } else if self.isVisible {
            self.updateDockFrame()
        }
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        self.noteUserActivity(wakeDock: true)
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               vc != except {
                app.view?.layer.removeAllAnimations()
                vc.minimizeWindow()
            }
        }
    }
    
    @objc public func toggleDockCollapse() {
        self.isCollapsed.toggle()
        if !self.isCollapsed {
            self.cancelAutoHideTimer()
            if self.isAutoHidden {
                self.isAutoHidden = false
                self.setupEdgeGestureRecognizers()
            }
        }
        self.updateDockFrame()
        self.notifyDockCollapseChanged()
        if self.isCollapsed {
            self.scheduleAutoHideIfNeeded()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        self.isDockHidden.toggle()
        if self.isDockHidden {
            self.cancelAutoHideTimer()
            self.isAutoHidden = false
        } else {
            self.noteUserActivity(wakeDock: false)
        }
        self.updateDockFrame()
        self.setupEdgeGestureRecognizers()
    }
    
    @objc public func showDockFromHidden() {
        self.isDockHidden = false
        self.isAutoHidden = false
        self.updateDockFrame()
        self.setupEdgeGestureRecognizers()
        self.noteUserActivity(wakeDock: false)
    }
    
    @objc public func hideDockToSide() {
        self.cancelAutoHideTimer()
        self.isAutoHidden = false
        self.isDockHidden = true
        self.updateDockFrame()
        self.setupEdgeGestureRecognizers()
    }

    private func removeTrackedEdgeGestures() {
        if let left = leftEdgeGesture {
            left.view?.removeGestureRecognizer(left)
            leftEdgeGesture = nil
        }
        if let right = rightEdgeGesture {
            right.view?.removeGestureRecognizer(right)
            rightEdgeGesture = nil
        }
    }
    
    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        removeTrackedEdgeGestures()
        guard let keyWindow = self.keyWindow else { return }
        
        if isVisible && isEffectivelyHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            leftEdgeGesture.cancelsTouchesInView = false
            keyWindow.addGestureRecognizer(leftEdgeGesture)
            self.leftEdgeGesture = leftEdgeGesture
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            rightEdgeGesture.cancelsTouchesInView = false
            keyWindow.addGestureRecognizer(rightEdgeGesture)
            self.rightEdgeGesture = rightEdgeGesture
        }
    }
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isEffectivelyHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }
        
        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)
        
        if swipeDistance > Constants.edgeSwipeThreshold {
            if isDockHidden {
                showDockFromHidden()
            } else {
                noteUserActivity(wakeDock: true)
            }
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - SwiftUI Dock View
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @Namespace private var dockGlassNamespace
    @State private var dragOffset = CGSize.zero
    @State private var isMoving: Bool = false
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            let containerRadius = (dockManager.adaptiveIconSize * 0.2667) + dynamicPadding
            GlassEffectContainer(spacing: 8) {
                if dockManager.isCollapsed {
                    CollapsedDockView(isHidden: dockManager.isDockHidden)
                        .glassEffectID("multitaskDockSurface", in: dockGlassNamespace)
                        .onTapGesture {
                            if dockManager.isAutoHidden {
                                dockManager.noteUserActivity(wakeDock: true)
                            } else {
                                dockManager.toggleDockCollapse()
                            }
                        }
                } else {
                    VStack(spacing: 8) {
                        CollapseButtonView()
                            .onTapGesture {
                                dockManager.toggleDockCollapse()
                            }
                        
                        MinimizeAllButtonView()
                            .onTapGesture {
                                dockManager.minimizeAllWindows()
                            }
                        
                        ForEach(dockManager.apps) { app in
                            AppIconView(app: app)
                        }
                    }
                    .padding(dynamicPadding)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: containerRadius, style: .continuous))
                    .glassEffectID("multitaskDockSurface", in: dockGlassNamespace)
                    .allowsHitTesting(!dockManager.isAutoHidden)
                    .overlay {
                        if dockManager.isAutoHidden {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    dockManager.noteUserActivity(wakeDock: true)
                                }
                        }
                    }
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            .opacity(
                dockManager.isAutoHidden
                    ? 0.01
                    : (dockManager.isDockHidden ? (hideCollapsedDock && dockManager.isCollapsed ? 0.01 : 0.4) : 1.0)
            )
            .animation(.easeInOut(duration: 0.25), value: dockManager.isAutoHidden)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                if !self.isMoving {
                    dockManager.setUserInteracting(true)
                }
                self.isMoving = true
                self.dragOffset = value.translation
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation),
                   let screenBounds = dockManager.keyWindow?.bounds {
                    let targetX = dockManager.calculateTargetX(isDockHidden: false, isOnRightSide: currentPhysicalFrame.midX > screenBounds.width / 2, dockWidth: dockManager.dockWidth, screenWidth: screenBounds.width)
                    
                    let safeAreaInsets = dockManager.safeAreaInsets
                    let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                    let minY = safeAreaInsets.top + dockVerticalMargin
                    let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                    let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                    
                    let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                    
                    let newOffset = CGSize(
                        width: finalPhysicalPosition.x - hcFrame.origin.x,
                        height: finalPhysicalPosition.y - hcFrame.origin.y
                    )
                    
                    let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                    
                    withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = newOffset
                    }
                    
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(animationDuration))
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
                        self.isMoving = false
                        dockManager.setUserInteracting(false)
                    }
                    return
                }
                
                if dockManager.handleSwipeToHideOrShowGesture(for: hcFrame, translation: value.translation) {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(MultitaskDockManager.Constants.longAnimationDuration))
                        self.isMoving = false
                        dockManager.setUserInteracting(false)
                    }
                    return
                }
                
                guard let screenBounds = dockManager.keyWindow?.bounds else {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    self.isMoving = false
                    dockManager.setUserInteracting(false)
                    return
                }
                let safeAreaInsets = dockManager.safeAreaInsets
                let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                let minY = safeAreaInsets.top + dockVerticalMargin
                let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                
                let targetX: CGFloat

                let isOnRightSide = hcFrame.origin.x > screenBounds.width / 2
                targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden || dockManager.isAutoHidden, isOnRightSide: isOnRightSide, dockWidth: currentPhysicalFrame.width, screenWidth: screenBounds.width)
                
                let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                
                let newOffset = CGSize(
                    width: finalPhysicalPosition.x - hcFrame.origin.x,
                    height: finalPhysicalPosition.y - hcFrame.origin.y
                )
                
                let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                
                withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                    self.dragOffset = newOffset
                }
                
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(animationDuration))
                    dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                    
                    self.dragOffset = .zero
                    
                    self.isMoving = false
                    dockManager.setUserInteracting(false)
                }
            }
        )
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isDockHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
struct CollapsedDockView: View {
    let isHidden: Bool
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        let buttonSize = max(44, dockManager.adaptiveIconSize)
        Image(systemName: isHidden ? "eye.slash" : "chevron.up")
            .font(.system(size: buttonSize * 0.38, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isHidden ? .secondary : .primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(isHidden ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHidden)
            .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Collapse Button View
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        let radius = dockManager.adaptiveIconSize * 0.2667
        Image(systemName: "chevron.down")
            .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Minimize All Button View
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        let radius = dockManager.adaptiveIconSize * 0.2667
        Image(systemName: "rectangle.stack.badge.minus")
            .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Icon Cache Manager
@MainActor
final class IconCacheManager {
    static let shared = IconCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cache.setObject(icon, forKey: key as NSString)
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }
}
// MARK: - App Icon View
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: { 
                isPressed = true
            },
            onRelease: { location in 
                isPressed = false
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        var finalIcon: UIImage?
        if let appInfo = self.app.appInfo {
            finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
        } else if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
            finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
        }
        
        self.isLoading = false
        if let icon = finalIcon {
            self.appIcon = icon
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.2)
        }
    }
}

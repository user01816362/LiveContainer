//
//  LCDebugStudioView.swift
//  LiveContainerSwiftUI
//
//  Framed developer debugging studio hosting the guest app inside a scalable
//  viewport alongside Liquid Glass telemetry, 3-detent collapsible inspector
//  drawer (Portrait) or side-by-side split (Landscape), and full modal detail sheets.
//

import SwiftUI
import UIKit

private struct LCDebugGuestSceneRepresentable: UIViewControllerRepresentable {
    let relativeBundlePath: String
    let dataUUID: String
    let terminateSignal: Bool
    let onInitialized: (Int32, Error?) -> Void
    let onExit: () -> Void

    @MainActor
    final class Coordinator: NSObject, AppSceneViewControllerDelegate {
        let onInitialized: (Int32, Error?) -> Void
        let onExit: () -> Void
        var didTerminate = false

        init(onInitialized: @escaping (Int32, Error?) -> Void, onExit: @escaping () -> Void) {
            self.onInitialized = onInitialized
            self.onExit = onExit
        }

        func appSceneVCAppDidExit(_ vc: AppSceneViewController) {
            onExit()
        }

        func appSceneVC(_ vc: AppSceneViewController, didInitializeWithError error: (any Error)?) {
            let pid = vc.pid
            onInitialized(pid, error)
        }

        func appSceneVCWillActivateScene(_ vc: AppSceneViewController) {
            vc.updateSettings { settings in
                guard let settings else { return }
                let safeTop: CGFloat = 12
                let safeBottom: CGFloat = 8
                settings.peripheryInsets = .zero
                settings.safeAreaInsetsPortrait = UIEdgeInsets(top: safeTop, left: 0, bottom: safeBottom, right: 0)
                settings.deviceOrientation = UIDevice.current.orientation
                let orientation = vc.view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
                settings.setInterfaceOrientation(orientation)
                if settings.interfaceOrientation().isLandscape {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.height, height: vc.view.frame.size.width))
                } else {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.width, height: vc.view.frame.size.height))
                }
            }
            vc.contentView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        func appSceneVC(_ vc: AppSceneViewController, didUpdateFrom settings: UIMutableApplicationSceneSettings, transitionContext context: Any?, lifecycleActionType actionType: UInt32) {
            guard !didTerminate, let scene = vc.presenter?.scene else { return }
            settings.interruptionPolicy = 0
            scene.updateSettings(settings, withTransitionContext: context, completion: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInitialized: onInitialized, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard let vc = AppSceneViewController(bundleId: relativeBundlePath, dataUUID: dataUUID, debugMode: true, delegate: context.coordinator) else {
            return UIViewController()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if terminateSignal {
            if !context.coordinator.didTerminate, let vc = uiViewController as? AppSceneViewController {
                context.coordinator.didTerminate = true
                vc.terminate()
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        if !coordinator.didTerminate, let vc = uiViewController as? AppSceneViewController {
            coordinator.didTerminate = true
            vc.terminate()
        }
    }
}

struct LCDebugStudioView: View {
    @ObservedObject var appModel: LCAppModel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var manager = LCDebugStudioManager()

    @State private var launchError: String? = nil
    @State private var statusText: String = "Preparing container & signing…"
    @State private var readyRelativePath: String? = nil
    @State private var readyDataUUID: String? = nil
    @State private var terminateSignal = false
    @State private var hasDismissed = false

    @State private var viewportScale: CGFloat = 0.86
    @State private var drawerDetent: LCDebugDrawerDetent = .docked
    @State private var selectedTab: LCDebugInspectorTab = .network
    @State private var copiedBanner: String? = nil

    var body: some View {
        @Bindable var networkStore = manager.networkStore
        @Bindable var inspectorStore = manager.inspectorStore

        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { rootGeo in
                let isLandscape = rootGeo.size.width > rootGeo.size.height && rootGeo.size.width >= 660
                let isPortraitExpanded = !isLandscape && drawerDetent == .expanded
                let inspectorHeight = portraitInspectorHeight(totalHeight: rootGeo.size.height)
                let splitLayout = isLandscape
                    ? AnyLayout(HStackLayout(spacing: 12))
                    : AnyLayout(VStackLayout(spacing: 8))

                VStack(spacing: 8) {
                    LCDebugStudioHeaderBar(
                        appModel: appModel,
                        darkModeIcon: darkModeIcon,
                        manager: manager,
                        telemetryStore: manager.telemetryStore,
                        isSideSplit: isLandscape,
                        viewportScale: $viewportScale,
                        drawerDetent: $drawerDetent,
                        onStopAndDismiss: stopAndDismiss
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                    LCDebugTelemetryBar(
                        telemetryStore: manager.telemetryStore,
                        isConnected: manager.isConnected,
                        onCopyLANURL: { url in
                            copyWithFeedback(url, message: "Copied Mac LAN URL")
                        }
                    )
                    .padding(.horizontal, 12)

                    if let jitBanner = manager.jitStatusBanner {
                        Text(jitBanner)
                            .font(.caption.monospaced())
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 12)
                            .lineLimit(2)
                    }

                    splitLayout {
                        VStack(spacing: 8) {
                            guestViewportSection
                                .frame(maxWidth: .infinity, maxHeight: isPortraitExpanded ? 0 : .infinity)
                                .opacity(isPortraitExpanded ? 0 : 1)
                                .allowsHitTesting(!isPortraitExpanded)
                                .clipped()

                            selectedViewBannerIfPresent

                            quickActionDock(isSideSplit: isLandscape)
                        }
                        .frame(
                            width: isLandscape ? min(rootGeo.size.width * 0.42, 420) : nil
                        )

                        LCDebugInspectorTrayView(
                            manager: manager,
                            selectedTab: $selectedTab,
                            drawerDetent: isLandscape ? .constant(.expanded) : $drawerDetent,
                            isSideSplit: isLandscape,
                            onSelectTab: { tab in
                                selectedTab = tab
                                if !isLandscape && drawerDetent == .collapsed {
                                    withAnimation(.spring(duration: 0.25)) {
                                        drawerDetent = .docked
                                    }
                                }
                                triggerTabLoad(tab)
                            },
                            onCopyWithFeedback: copyWithFeedback
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: isLandscape ? nil : inspectorHeight,
                            maxHeight: isLandscape ? .infinity : inspectorHeight
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, isLandscape ? 8 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: manager.isConnected) { _, connected in
            if connected {
                triggerTabLoad(selectedTab)
            }
        }
        .sheet(item: $networkStore.selectedTransaction) { entry in
            LCDebugNetworkDetailSheet(entry: entry, manager: manager)
        }
        .sheet(item: $networkStore.replayTarget) { target in
            LCDebugNetworkReplaySheet(initialTarget: target, manager: manager)
        }
        .sheet(isPresented: $networkStore.showSettingsSheet) {
            LCDebugNetworkSettingsSheet(manager: manager)
        }
        .sheet(item: $inspectorStore.selectedClassDetail) { detail in
            ObjCClassInspectorSheet(detail: detail, onCopyWithFeedback: copyWithFeedback)
        }
        .sheet(isPresented: $inspectorStore.showSelectedViewSheet) {
            if let sv = manager.inspectorStore.selectedView {
                LCDebugViewDetailSheet(info: sv, onCopy: copyWithFeedback)
            }
        }
        .overlay(alignment: .top) {
            if let copiedBanner {
                Text(copiedBanner)
                    .font(.caption.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .task {
            await prepareAndLaunchDebugSession()
        }
        .onDisappear {
            terminateSignal = true
            manager.disconnect()
        }
    }

    private func portraitInspectorHeight(totalHeight: CGFloat) -> CGFloat {
        switch drawerDetent {
        case .collapsed:
            return 52
        case .docked:
            return max(220, min(330, totalHeight * 0.40))
        case .expanded:
            return max(340, totalHeight * 0.74)
        }
    }

    @ViewBuilder
    private var selectedViewBannerIfPresent: some View {
        if let sv = manager.inspectorStore.selectedView {
            LCDebugSelectedViewPill(info: sv) {
                manager.inspectorStore.showSelectedViewSheet = true
            } onClear: {
                manager.inspectorStore.selectedView = nil
            }
        }
    }

    private var guestViewportSection: some View {
        LCDebugGuestViewportContainer(
            appModel: appModel,
            telemetryStore: manager.telemetryStore,
            launchError: launchError,
            statusText: statusText,
            readyRelativePath: readyRelativePath,
            readyDataUUID: readyDataUUID,
            terminateSignal: terminateSignal,
            viewportScale: viewportScale,
            onInitialized: { pid, error in
                if let error {
                    launchError = error.localizedDescription
                } else {
                    manager.startConnecting(expectedPID: pid)
                }
            },
            onExit: stopAndDismiss
        )
    }

    private func quickActionDock(isSideSplit: Bool) -> some View {
        LCDebugViewportActionDock(
            telemetryStore: manager.telemetryStore,
            isSideSplit: isSideSplit,
            drawerDetent: $drawerDetent,
            onToggleXRay: { Task { await manager.toggleXRay() } },
            onToggleTapInspect: { Task { await manager.toggleTapInspect() } },
            onToggleNetPause: { Task { await manager.setNetworkPaused(!manager.telemetryStore.networkPaused) } },
            onMemoryWarning: { Task { await manager.simulateMemoryWarning() } }
        )
    }

    private func triggerTabLoad(_ tab: LCDebugInspectorTab) {
        Task {
            switch tab {
            case .events: await manager.loadEvents()
            case .hierarchy: await manager.loadHierarchy()
            case .runtime:
                await manager.loadDylibs()
                await manager.searchObjCClasses(query: "")
                await manager.loadFridaInfo()
            case .sandbox: await manager.loadSandbox()
            default: break
            }
        }
    }

    private func prepareAndLaunchDebugSession() async {
        guard LCUtils.liveProcessBundleIdentifier() != nil else {
            launchError = "LiveProcess extension is required for Framed Debug Studio. Reinstall LiveContainer with Keep Extensions enabled."
            return
        }

        if appModel.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                guard try await LCUtils.authenticateUser() else {
                    dismiss()
                    return
                }
            } catch {
                launchError = error.localizedDescription
                return
            }
        }

        if appModel.uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer.makeNewContainer(folderName: newName, name: newName, isShared: appModel.uiIsShared)
            appModel.uiContainers.append(newContainer)
            if appModel.uiSelectedContainer == nil {
                appModel.uiSelectedContainer = newContainer
            }
            appModel.appInfo.containers = appModel.uiContainers
            newContainer.makeLCContainerInfoPlist(
                appIdentifier: appModel.bundleIdentifier,
                keychainGroupId: LCContainer.allocateKeychainGroupId()
            )
            appModel.appInfo.dataUUID = newName
            appModel.uiDefaultDataFolder = newName
        }

        guard let relPath = appModel.appInfo.relativeBundlePath,
              let dataUUID = appModel.uiSelectedContainer?.folderName ?? appModel.uiDefaultDataFolder else {
            launchError = "Unable to resolve app bundle path or data container."
            return
        }

        if MultitaskManager.isUsing(container: dataUUID) {
            launchError = "This app container is already running in Multitask. Close it first to launch Debug Studio."
            return
        }

        statusText = "Signing & verifying binary…"
        do {
            try await appModel.signApp(force: false)
        } catch {
            launchError = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }

        LCDebugStudioManager.clearStaleSessionMetadata()
        UserDefaults.lcShared().set(appModel.bundleIdentifier, forKey: "LCDebugPendingBundleID")
        UserDefaults.lcShared().set(relPath, forKey: "LCDebugPendingRelativePath")
        statusText = "Launching Debug Process…"
        readyDataUUID = dataUUID
        readyRelativePath = relPath
    }

    private func stopAndDismiss() {
        terminateSignal = true
        manager.disconnect()
        guard !hasDismissed else { return }
        hasDismissed = true
        dismiss()
    }

    private func copyWithFeedback(_ value: String, message: String) {
        UIPasteboard.general.string = value
        withAnimation { copiedBanner = message }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                if copiedBanner == message {
                    copiedBanner = nil
                }
            }
        }
    }
}

// MARK: - Modular Chrome Subviews

private struct LCDebugStudioHeaderBar: View {
    let appModel: LCAppModel
    let darkModeIcon: Bool
    let manager: LCDebugStudioManager
    let telemetryStore: LCDebugTelemetryStore
    let isSideSplit: Bool
    @Binding var viewportScale: CGFloat
    @Binding var drawerDetent: LCDebugDrawerDetent
    let onStopAndDismiss: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                if let icon = appModel.appInfo.iconIsDarkIcon(darkModeIcon) {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(.rect(cornerRadius: 7))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(appModel.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(manager.isConnected ? Color.green : (manager.connectionError != nil ? Color.red : Color.yellow))
                            .frame(width: 6, height: 6)
                        Text(connectionLabel)
                            .font(.caption2)
                            .foregroundStyle(manager.connectionError != nil ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if !manager.isConnected && manager.connectionError != nil {
                    Button("Retry") {
                        manager.reconnect()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }

                Button {
                    Task { await manager.setMacLAN(enabled: !telemetryStore.isMacLANEnabled) }
                } label: {
                    Label(telemetryStore.isMacLANEnabled ? "LAN ON" : "LAN", systemImage: telemetryStore.isMacLANEnabled ? "wifi" : "wifi.slash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(telemetryStore.isMacLANEnabled ? .green : .gray)
                .controlSize(.small)

                Menu {
                    Picker("Viewport Scale", selection: $viewportScale) {
                        Text("Compact (64%)").tag(CGFloat(0.64))
                        Text("Balanced (76%)").tag(CGFloat(0.76))
                        Text("Focus (86%)").tag(CGFloat(0.86))
                        Text("Large (94%)").tag(CGFloat(0.94))
                    }
                    Divider()
                    Button("Attach Optional JIT", systemImage: "bolt.fill") {
                        Task { await manager.attachJIT(for: appModel) }
                    }
                    Button("Reconnect Debug Agent", systemImage: "arrow.clockwise") {
                        manager.reconnect()
                    }
                    if !isSideSplit {
                        Divider()
                        Picker("Inspector Height", selection: $drawerDetent) {
                            Text("Collapsed").tag(LCDebugDrawerDetent.collapsed)
                            Text("Docked").tag(LCDebugDrawerDetent.docked)
                            Text("Expanded").tag(LCDebugDrawerDetent.expanded)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button(action: onStopAndDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private var connectionLabel: String {
        if manager.isConnected {
            return "Debug Agent Connected"
        }
        if let err = manager.connectionError {
            return err
        }
        return manager.isConnecting ? "Connecting to Agent…" : "Waiting to Launch"
    }
}

private struct LCDebugGuestViewportContainer: View {
    let appModel: LCAppModel
    let telemetryStore: LCDebugTelemetryStore
    let launchError: String?
    let statusText: String
    let readyRelativePath: String?
    let readyDataUUID: String?
    let terminateSignal: Bool
    let viewportScale: CGFloat
    let onInitialized: (Int32, Error?) -> Void
    let onExit: () -> Void

    private var borderColor: Color {
        if telemetryStore.isTapInspectEnabled { return .cyan }
        if telemetryStore.isXRayEnabled { return .orange }
        return Color.white.opacity(0.24)
    }

    var body: some View {
        GeometryReader { geo in
            let availW = max(geo.size.width - 12, 120)
            let availH = max(geo.size.height - 4, 120)
            let frameW = min(availW * viewportScale, availH * 0.54)
            let frameH = min(availH * max(viewportScale, 0.78), frameW * 2.16)
            let finalW = max(min(frameW, availW), 140)
            let finalH = max(min(frameH, availH), 180)

            ZStack {
                if let launchError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text(launchError)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                        Button("Close", action: onExit)
                            .buttonStyle(.glassProminent)
                    }
                    .padding()
                    .frame(width: finalW, height: finalH)
                } else if let relPath = readyRelativePath, let dataUUID = readyDataUUID {
                    LCDebugGuestSceneRepresentable(
                        relativeBundlePath: relPath,
                        dataUUID: dataUUID,
                        terminateSignal: terminateSignal,
                        onInitialized: onInitialized,
                        onExit: onExit
                    )
                    .frame(width: finalW, height: finalH)
                    .background(Color.black)
                    .clipShape(.rect(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(borderColor, lineWidth: (telemetryStore.isTapInspectEnabled || telemetryStore.isXRayEnabled) ? 2.5 : 1.5)
                    }
                    .shadow(color: borderColor.opacity(0.25), radius: 16)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: finalW, height: finalH)
                    .background(Color.black.opacity(0.5), in: .rect(cornerRadius: 28, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LCDebugViewportActionDock: View {
    let telemetryStore: LCDebugTelemetryStore
    let isSideSplit: Bool
    @Binding var drawerDetent: LCDebugDrawerDetent
    let onToggleXRay: () -> Void
    let onToggleTapInspect: () -> Void
    let onToggleNetPause: () -> Void
    let onMemoryWarning: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onToggleXRay) {
                        Label("X-Ray", systemImage: "viewfinder")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(telemetryStore.isXRayEnabled ? .orange : .secondary.opacity(0.35))

                    Button(action: onToggleTapInspect) {
                        Label("Inspect", systemImage: "hand.tap.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(telemetryStore.isTapInspectEnabled ? .cyan : .secondary.opacity(0.35))

                    Button(action: onToggleNetPause) {
                        Label(
                            telemetryStore.networkPaused ? "Net Off" : "Net On",
                            systemImage: telemetryStore.networkPaused ? "pause.circle.fill" : "dot.radiowaves.left.and.right"
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .tint(telemetryStore.networkPaused ? .red : .teal.opacity(0.75))

                    Button(action: onMemoryWarning) {
                        Label("MemWarn", systemImage: "memorychip")
                    }
                    .buttonStyle(.glass)

                    if !isSideSplit {
                        Button {
                            withAnimation(.spring(duration: 0.25)) {
                                switch drawerDetent {
                                case .collapsed: drawerDetent = .docked
                                case .docked: drawerDetent = .expanded
                                case .expanded: drawerDetent = .docked
                                }
                            }
                        } label: {
                            Label(
                                drawerDetent == .expanded ? "Show App" : (drawerDetent == .collapsed ? "Open Panel" : "Expand"),
                                systemImage: drawerDetent == .expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                            )
                        }
                        .buttonStyle(.glass)
                    }
                }
                .font(.caption.weight(.semibold))
                .controlSize(.small)
                .padding(.horizontal, 2)
            }
        }
    }
}

private struct LCDebugSelectedViewPill: View {
    let info: LCDebugSelectedView
    let onOpenDetail: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDetail) {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(info.viewClass)\(info.viewController.isEmpty ? "" : " · \(info.viewController)")")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text("Frame: \(info.frame) · Subviews: \(info.subviewCount) · Tap for full details")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

private struct LCDebugInspectorTrayView: View {
    let manager: LCDebugStudioManager
    @Binding var selectedTab: LCDebugInspectorTab
    @Binding var drawerDetent: LCDebugDrawerDetent
    let isSideSplit: Bool
    let onSelectTab: (LCDebugInspectorTab) -> Void
    let onCopyWithFeedback: (String, String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if !isSideSplit {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 36, height: 4)
                    .padding(.top, 2)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) {
                            drawerDetent = (drawerDetent == .docked) ? .expanded : (drawerDetent == .expanded ? .collapsed : .docked)
                        }
                    }
            }

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LCDebugInspectorTab.allCases) { tab in
                            let isSelected = (isSideSplit || drawerDetent != .collapsed) && selectedTab == tab
                            Button {
                                onSelectTab(tab)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: tab.systemImage)
                                    Text(tabLabel(tab))
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.blue.opacity(0.72) : Color.white.opacity(0.08), in: .capsule)
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !isSideSplit && drawerDetent != .collapsed {
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            drawerDetent = (drawerDetent == .expanded) ? .docked : .expanded
                        }
                    } label: {
                        Image(systemName: drawerDetent == .expanded ? "chevron.down" : "chevron.up")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
            }

            if isSideSplit || drawerDetent != .collapsed {
                panelContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedTab {
        case .console:
            LCDebugConsolePanel(
                consoleStore: manager.consoleStore,
                isConnected: manager.isConnected,
                manager: manager,
                onCopyWithFeedback: onCopyWithFeedback
            )
        case .network:
            LCDebugNetworkPanelView(
                networkStore: manager.networkStore,
                manager: manager,
                onCopyWithFeedback: onCopyWithFeedback
            )
        case .events:
            LCDebugEventsPanel(
                inspectorStore: manager.inspectorStore,
                telemetryStore: manager.telemetryStore,
                manager: manager
            )
        case .hierarchy:
            LCDebugHierarchyPanel(
                inspectorStore: manager.inspectorStore,
                manager: manager,
                onCopyWithFeedback: onCopyWithFeedback
            )
        case .runtime:
            LCDebugRuntimePanel(
                inspectorStore: manager.inspectorStore,
                manager: manager,
                onCopyWithFeedback: onCopyWithFeedback
            )
        case .sandbox:
            LCDebugSandboxPanel(
                inspectorStore: manager.inspectorStore,
                manager: manager,
                onCopyWithFeedback: onCopyWithFeedback
            )
        }
    }

    private func tabLabel(_ tab: LCDebugInspectorTab) -> String {
        switch tab {
        case .console:
            let errs = manager.consoleStore.errorCount
            return errs > 0 ? "Console (\(manager.consoleStore.totalCount) · \(errs)!)" : "Console (\(manager.consoleStore.totalCount))"
        case .network:
            return "Network (\(manager.networkStore.totalCount))"
        case .events:
            return "Events (\(manager.inspectorStore.totalEventCount))"
        default:
            return tab.rawValue
        }
    }
}

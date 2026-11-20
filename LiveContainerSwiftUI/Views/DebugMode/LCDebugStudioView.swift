//
//  LCDebugStudioView.swift
//  LiveContainerSwiftUI
//
//  Framed developer debugging studio: hosts the guest app inside a centered,
//  scalable device viewport surrounded by interactive Liquid Glass debug border
//  controls, live telemetry, Console, HTTP Sniffer, UI X-Ray, Tap Inspect,
//  View Hierarchy, Dylibs/ObjC browser, Sandbox viewer, and Mac LAN Web Console.
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
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        func appSceneVC(_ vc: AppSceneViewController, didUpdateFrom settings: UIMutableApplicationSceneSettings, transitionContext context: Any?, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
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
        if terminateSignal, !context.coordinator.didTerminate, let vc = uiViewController as? AppSceneViewController {
            context.coordinator.didTerminate = true
            vc.terminate()
        }
    }
}

struct LCDebugStudioView: View {
    @ObservedObject var appModel: LCAppModel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @StateObject private var manager = LCDebugStudioManager()

    @State private var launchError: String? = nil
    @State private var statusText: String = "Preparing container & signing…"
    @State private var readyRelativePath: String? = nil
    @State private var readyDataUUID: String? = nil
    @State private var terminateSignal = false

    @State private var viewportScale: CGFloat = 0.80
    @State private var isInspectorOpen = true
    @State private var selectedTab: LCDebugInspectorTab = .console

    private enum LogStreamFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case stdio = "Stdio"
        case nslog = "NSLog"
        case oslog = "OSLog"
        case webview = "Web"
        case errors = "Errors"

        var id: String { rawValue }
    }

    @State private var logSearch = ""
    @State private var logFilter: LogStreamFilter = .all
    @State private var networkSearch = ""
    @State private var eventSearch = ""
    @State private var classSearch = ""
    @State private var hideSystemDylibs = true
    @State private var copiedBanner: String? = nil

    private var frameBorderColor: Color {
        if manager.isTapInspectEnabled {
            return .cyan
        } else if manager.isXRayEnabled {
            return .orange
        }
        return Color.white.opacity(0.24)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.14), Color(red: 0.02, green: 0.03, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBorderBar
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                if let macURL = manager.macLANURLString {
                    macNetworkBanner(url: macURL)
                        .padding(.horizontal, 12)
                }

                if let connError = manager.connectionError {
                    connectionStatusBanner(message: connError, isError: true)
                        .padding(.horizontal, 12)
                } else if readyRelativePath != nil && !manager.isConnected {
                    connectionStatusBanner(message: manager.isConnecting ? "Connecting to JIT-Less Debug Agent…" : "Waiting for Debug Agent…", isError: false)
                        .padding(.horizontal, 12)
                }

                if let jitBanner = manager.jitStatusBanner {
                    Text(jitBanner)
                        .font(.caption.monospaced())
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12)
                        .lineLimit(2)
                }

                // Centered non-fullscreen guest app viewport framed by interactive border tools
                centeredViewportArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                borderToolStrip
                    .padding(.horizontal, 12)

                if let tapView = manager.selectedView {
                    selectedViewCallout(tapView)
                        .padding(.horizontal, 12)
                }

                if isInspectorOpen {
                    inspectorDrawer
                        .frame(height: 230)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: Binding(
            get: { manager.selectedClassDetail.map { IdentifiedClassDetail(detail: $0) } },
            set: { if $0 == nil { manager.selectedClassDetail = nil } }
        )) { wrapped in
            ObjCClassInspectorSheet(detail: wrapped.detail)
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

    // MARK: - Top Debug Border Bar

    private var topBorderBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if let icon = appModel.appInfo.iconIsDarkIcon(darkModeIcon) {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        telemetryPill("PID \(manager.pid)")
                        telemetryPill("\(String(format: "%.0f", manager.cpuPercent))%")
                        telemetryPill("\(String(format: "%.0f", manager.memoryMB))M")
                        telemetryPill("\(manager.fps)FPS")
                        telemetryPill(manager.isJIT ? "JIT" : "JIT-Less", tint: manager.isJIT ? .green : .mint)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    Task { await manager.setMacLAN(enabled: !manager.isMacLANEnabled) }
                } label: {
                    Label(manager.isMacLANEnabled ? "LAN ON" : "Mac LAN", systemImage: manager.isMacLANEnabled ? "wifi" : "wifi.slash")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(manager.isMacLANEnabled ? .green : .gray)
                .controlSize(.small)

                Menu {
                    Picker("Viewport Scale", selection: $viewportScale) {
                        Text("Compact (62%)").tag(CGFloat(0.62))
                        Text("Balanced (74%)").tag(CGFloat(0.74))
                        Text("Focus (82%)").tag(CGFloat(0.82))
                        Text("Large (92%)").tag(CGFloat(0.92))
                    }
                    Button(isInspectorOpen ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.squares.bottom") {
                        withAnimation(.spring(duration: 0.25)) {
                            isInspectorOpen.toggle()
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .padding(6)
                }
                .buttonStyle(.glass)

                Button {
                    stopAndDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func telemetryPill(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint == .secondary ? Color.white.opacity(0.88) : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.white.opacity(0.08), in: .capsule)
    }

    private func connectionStatusBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            if isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.cyan)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
                .lineLimit(2)
            Spacer()
            if isError {
                Button("Reconnect") {
                    manager.reconnect()
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func macNetworkBanner(url: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macbook.and.iphone")
                .foregroundStyle(.green)
            Text("Mac Console:")
                .font(.caption.bold())
            Text(url)
                .font(.caption.monospaced())
                .foregroundStyle(.cyan)
                .lineLimit(1)
            Spacer()
            Button("Copy URL") {
                copyWithFeedback(url, message: "Copied Mac Console URL")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Centered Framed Guest App Viewport

    private var centeredViewportArea: some View {
        GeometryReader { geo in
            let availW = max(geo.size.width - 28, 120)
            let availH = max(geo.size.height - 8, 120)
            let frameW = min(availW * viewportScale, availH * 0.56)
            let frameH = min(availH * max(viewportScale, 0.72), frameW * 2.16)
            let finalW = max(min(frameW, availW), 160)
            let finalH = max(min(frameH, availH), 220)

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
                        Button("Close") { stopAndDismiss() }
                            .buttonStyle(.glassProminent)
                    }
                    .padding()
                    .frame(width: finalW, height: finalH)
                } else if let relPath = readyRelativePath, let dataUUID = readyDataUUID {
                    LCDebugGuestSceneRepresentable(
                        relativeBundlePath: relPath,
                        dataUUID: dataUUID,
                        terminateSignal: terminateSignal,
                        onInitialized: { pid, error in
                            if let error {
                                launchError = error.localizedDescription
                            } else {
                                manager.startConnecting(expectedPID: pid)
                            }
                        },
                        onExit: {
                            stopAndDismiss()
                        }
                    )
                    .frame(width: finalW, height: finalH)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(frameBorderColor, lineWidth: (manager.isTapInspectEnabled || manager.isXRayEnabled) ? 2.5 : 1.5)
                    }
                    .shadow(color: frameBorderColor.opacity(0.28), radius: 18)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: finalW, height: finalH)
                    .background { Color.black.opacity(0.5) }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Interactive Border Control Strip

    private var borderToolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        Task { await manager.toggleXRay() }
                    } label: {
                        Label("UI X-Ray", systemImage: "viewfinder")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(manager.isXRayEnabled ? .orange : .secondary.opacity(0.35))

                    Button {
                        Task { await manager.toggleTapInspect() }
                    } label: {
                        Label("Tap Inspect", systemImage: "hand.tap.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(manager.isTapInspectEnabled ? .cyan : .secondary.opacity(0.35))

                    Button {
                        Task { await manager.attachJIT(for: appModel) }
                    } label: {
                        Label("JIT (Optional)", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.glass)

                    Button {
                        Task { await manager.simulateMemoryWarning() }
                    } label: {
                        Label("Mem Warn", systemImage: "memorychip")
                    }
                    .buttonStyle(.glass)

                    Divider().frame(height: 18)

                    ForEach(LCDebugInspectorTab.allCases) { tab in
                        let isSelected = isInspectorOpen && selectedTab == tab
                        Button {
                            withAnimation(.spring(duration: 0.2)) {
                                if isInspectorOpen && selectedTab == tab {
                                    isInspectorOpen = false
                                } else {
                                    selectedTab = tab
                                    isInspectorOpen = true
                                }
                            }
                            triggerTabLoad(tab)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.systemImage)
                                Text(tabTitle(tab))
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(isSelected ? .blue : .secondary.opacity(0.28))
                    }
                }
                .font(.caption.weight(.semibold))
                .controlSize(.small)
                .padding(.horizontal, 4)
            }
        }
    }

    private func tabTitle(_ tab: LCDebugInspectorTab) -> String {
        switch tab {
        case .console:
            return "Console (\(manager.logs.count))"
        case .network:
            return "Network (\(manager.networkEntries.count))"
        case .events:
            return "Events (\(manager.uiEvents.count))"
        default:
            return tab.rawValue
        }
    }

    private func selectedViewCallout(_ info: LCDebugSelectedView) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.viewClass) \(info.viewController.isEmpty ? "" : "• VC: \(info.viewController)")")
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("Frame: \(info.frame) · Subviews: \(info.subviewCount)\(info.accessibilityIdentifier.isEmpty ? "" : " · ID: \(info.accessibilityIdentifier)")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                manager.selectedView = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: - Bottom Inspector Drawer

    @ViewBuilder
    private var inspectorDrawer: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .console:
                consolePanel
            case .network:
                networkPanel
            case .events:
                eventsPanel
            case .hierarchy:
                hierarchyPanel
            case .dylibs:
                dylibsPanel
            case .sandbox:
                sandboxPanel
            case .frida:
                fridaPanel
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var consolePanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Filter stdout / NSLog / OSLog / Web…", text: $logSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button {
                    Task { await manager.refreshStatusAndSnapshots() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                Button("Copy") {
                    let allText = filteredLogs.map {
                        let sub = ($0.subsystem?.isEmpty == false) ? ":\($0.subsystem!)" : ""
                        return "[\($0.stream)\(sub)] \($0.text)"
                    }.joined(separator: "\n")
                    copyWithFeedback(allText, message: "Copied Console Logs")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                Button("Clear") {
                    Task { await manager.clearLogs() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LogStreamFilter.allCases) { filter in
                        Button(filter.rawValue) {
                            logFilter = filter
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(logFilter == filter ? Color.blue.opacity(0.75) : Color.white.opacity(0.08), in: .capsule)
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if filteredLogs.isEmpty {
                        Text(manager.isConnected ? "No matching logs yet. Output from print(), NSLog, OSLog, WKWebView, and crashes will stream here live." : "Connecting to guest Debug Agent…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.stream.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(logStreamColor(entry))
                                if let sub = entry.subsystem, !sub.isEmpty {
                                    Text(sub)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(entry.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(entry.isErrorLike ? .red : .white)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func logStreamColor(_ entry: LCDebugLogEntry) -> Color {
        if entry.isErrorLike { return .red }
        switch entry.stream {
        case "nslog": return .yellow
        case "oslog": return .mint
        case "webview": return .purple
        case "debug": return .orange
        default: return .cyan
        }
    }

    private var filteredLogs: [LCDebugLogEntry] {
        let q = logSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.logs.filter { entry in
            switch logFilter {
            case .all: break
            case .stdio:
                guard entry.stream == "stdout" || entry.stream == "stderr" else { return false }
            case .nslog:
                guard entry.stream == "nslog" else { return false }
            case .oslog:
                guard entry.stream == "oslog" else { return false }
            case .webview:
                guard entry.stream == "webview" else { return false }
            case .errors:
                guard entry.isErrorLike else { return false }
            }
            guard !q.isEmpty else { return true }
            return entry.text.localizedCaseInsensitiveContains(q)
                || entry.stream.localizedCaseInsensitiveContains(q)
                || (entry.subsystem?.localizedCaseInsensitiveContains(q) ?? false)
                || (entry.category?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var networkPanel: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Filter URL / Method / Source…", text: $networkSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Clear") {
                    Task { await manager.clearNetwork() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            List(filteredNetwork) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(item.displaySource) · \(item.bytes) B · \(item.mimeType)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy cURL") {
                                copyWithFeedback(item.curl, message: "Copied cURL Command")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                        }
                        if !item.requestHeaders.isEmpty {
                            Text("Request Headers:\n\(formatHeaders(item.requestHeaders))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !item.requestBodyPreview.isEmpty {
                            Text("Request Body:\n\(item.requestBodyPreview)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.yellow)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                        if !item.responseHeaders.isEmpty {
                            Text("Response Headers:\n\(formatHeaders(item.responseHeaders))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !item.responseBodyPreview.isEmpty {
                            Text("Response:\n\(item.responseBodyPreview)")
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(10)
                                .textSelection(.enabled)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.method)
                            .font(.caption2.bold().monospaced())
                            .foregroundStyle(.cyan)
                        Text("\(item.statusCode)")
                            .font(.caption2.bold().monospaced())
                            .foregroundStyle((200...299).contains(item.statusCode) ? .green : (item.statusCode == 101 ? .cyan : .red))
                        Text(item.url)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.durationMs)ms")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func formatHeaders(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    private var filteredNetwork: [LCDebugNetworkEntry] {
        let q = networkSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return manager.networkEntries }
        return manager.networkEntries.filter {
            $0.url.localizedCaseInsensitiveContains(q)
                || $0.method.localizedCaseInsensitiveContains(q)
                || $0.displaySource.localizedCaseInsensitiveContains(q)
        }
    }

    private var eventsPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Filter touches, tabs, VCs, windows…", text: $eventSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button(manager.isNotificationMonitorEnabled ? "Notifs ON" : "Notifs") {
                    Task { await manager.toggleNotificationMonitor() }
                }
                .buttonStyle(.glassProminent)
                .tint(manager.isNotificationMonitorEnabled ? .blue : .secondary.opacity(0.35))
                .controlSize(.mini)
                Button("Clear") {
                    Task { await manager.clearUIEvents() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            List(filteredUIEvents) { ev in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ev.kind.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(eventKindColor(ev.kind))
                        Text(ev.title)
                            .font(.caption.bold().monospaced())
                            .lineLimit(1)
                    }
                    Text("\(ev.detail)\(ev.viewController.isEmpty ? "" : " · VC: \(ev.viewController)")\(ev.window.isEmpty ? "" : " · \(ev.window)")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func eventKindColor(_ kind: String) -> Color {
        switch kind {
        case "touch": return .cyan
        case "tab": return .green
        case "nav": return .mint
        case "modal": return .orange
        case "window": return .yellow
        case "notification": return .purple
        default: return .blue
        }
    }

    private var filteredUIEvents: [LCDebugUIEventEntry] {
        let q = eventSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return manager.uiEvents }
        return manager.uiEvents.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.detail.localizedCaseInsensitiveContains(q)
                || $0.kind.localizedCaseInsensitiveContains(q)
                || $0.viewController.localizedCaseInsensitiveContains(q)
        }
    }

    private var hierarchyPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Live Window & ViewController Tree")
                    .font(.caption.bold())
                Spacer()
                Button("Refresh") {
                    Task { await manager.loadHierarchy() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                Button("Copy JSON") {
                    copyWithFeedback(manager.hierarchyText, message: "Copied View Hierarchy")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            ScrollView {
                Text(manager.hierarchyText.isEmpty ? "Tap Refresh to snapshot the view tree." : manager.hierarchyText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var dylibsPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle("App/Tweaks Only", isOn: $hideSystemDylibs)
                    .font(.caption)
                    .toggleStyle(.button)
                TextField("ObjC Class Search…", text: $classSearch)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        Task { await manager.searchObjCClasses(query: classSearch) }
                    }
                Button("Search") {
                    Task { await manager.searchObjCClasses(query: classSearch) }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            List {
                if !manager.objcClasses.isEmpty {
                    Section("ObjC Classes (\(manager.objcClasses.count))") {
                        ForEach(manager.objcClasses.prefix(80), id: \.self) { clsName in
                            Button(clsName) {
                                Task { await manager.inspectObjCClass(clsName) }
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
                let shownDylibs = hideSystemDylibs ? manager.dylibs.filter { !$0.isSystem } : manager.dylibs
                Section("Loaded Mach-O Images (\(shownDylibs.count))") {
                    ForEach(shownDylibs) { img in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(img.name)
                                    .font(.caption.bold())
                                Spacer()
                                Text(img.base)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(img.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var sandboxPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Text(manager.sandboxSummary?.home ?? "Guest Sandbox")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh") {
                    Task { await manager.loadSandbox() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            if let summary = manager.sandboxSummary {
                List {
                    Section("Keychain Items (\(summary.keychainItems.count))") {
                        ForEach(summary.keychainItems) { item in
                            Text("\(item.service) · \(item.account)")
                                .font(.caption2.monospaced())
                        }
                    }
                    Section("Sandbox Files (\(summary.files.count))") {
                        ForEach(summary.files) { file in
                            HStack {
                                Text(file.path)
                                    .font(.caption2.monospaced())
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("UserDefaults (\(summary.userDefaults.count))") {
                        ForEach(summary.userDefaults.keys.sorted().prefix(60), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.caption2.bold().monospaced())
                                Spacer()
                                Text(summary.userDefaults[key] ?? "")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    private var fridaPanel: some View {
        ScrollView {
            if let info = manager.fridaInfo {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("FridaGadget: \(info.fridaGadgetLoaded ? "Loaded" : "Not Loaded")", systemImage: info.fridaGadgetLoaded ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(info.fridaGadgetLoaded ? .green : .secondary)
                        Spacer()
                        Label("FLEX: \(info.flexLoaded ? "Loaded" : "Not Loaded")", systemImage: info.flexLoaded ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(info.flexLoaded ? .green : .secondary)
                    }
                    .font(.caption.bold())

                    HStack {
                        Text(info.fridaAttachCmd)
                            .font(.caption.monospaced())
                        Spacer()
                        Button("Copy Frida") {
                            copyWithFeedback(info.fridaAttachCmd, message: "Copied Frida Command")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }

                    HStack {
                        Text(info.lldbCmd)
                            .font(.caption.monospaced())
                        Spacer()
                        Button("Copy LLDB") {
                            copyWithFeedback(info.lldbCmd, message: "Copied LLDB Attach Command")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                    }

                    Text(info.fridaGadgetTip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Helpers

    private func triggerTabLoad(_ tab: LCDebugInspectorTab) {
        Task {
            switch tab {
            case .events: await manager.loadEvents()
            case .hierarchy: await manager.loadHierarchy()
            case .dylibs:
                await manager.loadDylibs()
                await manager.searchObjCClasses(query: classSearch)
            case .sandbox: await manager.loadSandbox()
            case .frida: await manager.loadFridaInfo()
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
            newContainer.makeLCContainerInfoPlist(appIdentifier: appModel.bundleIdentifier, keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
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

private struct IdentifiedClassDetail: Identifiable {
    var id: String { detail.className }
    let detail: LCDebugClassDetail
}

private struct ObjCClassInspectorSheet: View {
    let detail: LCDebugClassDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Info") {
                    LabeledContent("Class", value: detail.className)
                    LabeledContent("Superclass", value: detail.superclassName)
                    if !detail.image.isEmpty {
                        Text(detail.image)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Methods (\(detail.methods.count))") {
                    ForEach(detail.methods, id: \.self) { m in
                        Text(m).font(.caption.monospaced())
                    }
                }
                Section("Properties (\(detail.properties.count))") {
                    ForEach(detail.properties, id: \.self) { p in
                        Text(p).font(.caption.monospaced())
                    }
                }
                Section("Ivars (\(detail.ivars.count))") {
                    ForEach(detail.ivars, id: \.self) { iv in
                        Text(iv).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle(detail.className)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

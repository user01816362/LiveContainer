//
//  SwiftUIView.swift
//
//  Created by s s on 2024/8/23.
//

import SwiftUI
import WebKit

@MainActor
private final class WebViewControllerModel: ObservableObject {
    let webView = WKWebView()
    @Published var loadStatus = 0.0
    @Published var pageURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = ""

    private var delegate: WebViewDelegate?
    private var observations: [NSKeyValueObservation] = []

    func configure(
        urlSchemeHandler: @escaping @MainActor (URL) async -> Void,
        universalLinkHandler: @escaping @MainActor (URL, [String]) async -> Void
    ) {
        if observations.isEmpty {
            observations = [
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.loadStatus = self.webView.estimatedProgress
                    }
                },
                webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pageURL = self.webView.url
                    }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.canGoBack = self.webView.canGoBack
                    }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.canGoForward = self.webView.canGoForward
                    }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isLoading = self.webView.isLoading
                    }
                }
            ]
        }

        let navDelegate = WebViewDelegate(
            onTitleChange: { [weak self] title in
                self?.pageTitle = title
            },
            urlSchemeHandler: urlSchemeHandler,
            universalLinkHandler: universalLinkHandler
        )
        self.delegate = navDelegate
        self.webView.navigationDelegate = navDelegate
    }

    func loadURL(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }
}

struct LCWebView: View {
    @StateObject private var webController = WebViewControllerModel()
    @State private var didAppear = false
    
    @Binding var url : URL
    @Binding var isPresent: Bool
    @State private var uiLoadStatus = 0.0
    @State private var showShareSheet = false
    
    @StateObject private var runAppAlert = YesNoHelper()
    @State private var runAppAlertMsg = ""
    
    @StateObject private var installAppAlert = YesNoHelper()
    @State private var installAppAlertMsg = ""
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @EnvironmentObject private var sharedModel : SharedModel

    private let navigationBarHeight: CGFloat = 60
    private let bottomBarHeight: CGFloat = 64
    
    var itmsServicesHandler: ((String) async -> Void)?
    
    init(url: Binding<URL>, isPresent: Binding<Bool>, itmsServicesHandler: ((String) async -> Void)? = nil) {
        self._url = url
        self._isPresent = isPresent
        self.itmsServicesHandler = itmsServicesHandler
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            ZStack {
                // Extend the web view itself under the bars and the home indicator.
                // Scroll insets keep the first and last page content reachable.
                WebView(webView: webController.webView, contentInsets: UIEdgeInsets(
                    top: geometry.safeAreaInsets.top + navigationBarHeight,
                    left: geometry.safeAreaInsets.leading,
                    bottom: geometry.safeAreaInsets.bottom + bottomBarHeight,
                    right: geometry.safeAreaInsets.trailing
                ))
                .ignoresSafeArea(.container)

                VStack(spacing: 0) {
                    navigationBar
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background { Color(.systemBackground) }
        .onAppear {
            if !didAppear {
                onViewAppear()
                didAppear = true
                webController.loadURL(url)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: [currentURL])
        }
        .alert("lc.webView.runApp".loc, isPresented: $runAppAlert.show) {
            Button("lc.appBanner.run".loc, action: {
                runAppAlert.close(result: true)
            })
            Button("lc.common.cancel".loc, role: .cancel, action: {
                runAppAlert.close(result: false)
            })
        } message: {
            Text(runAppAlertMsg)
        }
        .alert("lc.webView.installApp".loc, isPresented: $installAppAlert.show) {
            Button("lc.common.install".loc, action: {
                installAppAlert.close(result: true)
            })
            Button("lc.common.cancel".loc, role: .cancel, action: {
                installAppAlert.close(result: false)
            })
        } message: {
            Text(installAppAlertMsg)
        }
        
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        
    }
    
    private var currentURL: URL {
        webController.pageURL ?? url
    }

    private var navigationBar: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    isPresent = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .modifier(LCWebViewGlassBackground(shape: Circle(), isInteractive: true))
                }

                VStack(spacing: 3) {
                    Text(webController.pageTitle.isEmpty ? (currentURL.host ?? currentURL.absoluteString) : webController.pageTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 4) {
                        if currentURL.scheme?.lowercased() == "https" {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                        }
                        Text(currentURL.host ?? currentURL.absoluteString)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 12)
                .modifier(LCWebViewGlassBackground(shape: Capsule()))
                Button {
                    if webController.isLoading {
                        webController.stopLoading()
                    } else {
                        webController.reload()
                    }
                } label: {
                    if webController.isLoading {
                        Image(systemName: "xmark")
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .modifier(LCWebViewGlassBackground(shape: Circle(), isInteractive: true))
                
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) {
                ProgressView(value: uiLoadStatus)
                    .progressViewStyle(.linear)
                    .opacity(webController.isLoading ? 1 : 0)
                    .scaleEffect(y: 0.5, anchor: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: webController.loadStatus) { _, newValue in
            if newValue > uiLoadStatus {
                withAnimation(.easeInOut(duration: 0.2)) {
                    uiLoadStatus = newValue
                }
            } else {
                uiLoadStatus = newValue
            }
        }
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            HStack {
                Button(action: webController.goBack) {
                    Image(systemName: "chevron.backward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!webController.canGoBack)

                Spacer(minLength: 0)
                Button(action: webController.goForward) {
                    Image(systemName: "chevron.forward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!webController.canGoForward)

                Spacer(minLength: 0)
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                }

                Spacer(minLength: 0)
                Button {
                    UIApplication.shared.open(currentURL)
                } label: {
                    Image(systemName: "safari")
                        .frame(width: 44, height: 44)
                }
                .disabled(!["http", "https"].contains((currentURL.scheme ?? "").lowercased()))
            }
            .font(.system(size: 20))
            .frame(maxWidth: 420)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .modifier(LCWebViewGlassBackground(shape: Capsule(), isInteractive: true))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
        }
    }

    func onViewAppear() {
        webController.configure(
            urlSchemeHandler: { url in
                await onURLSchemeDetected(url: url)
            },
            universalLinkHandler: { url, bundleIDs in
                await onUniversalLinkDetected(url: url, bundleIDs: bundleIDs)
            }
        )
    }

    func launchToApp(app: LCAppModel, url: URL) async {
        let bundleId = app.appInfo.relativeBundlePath!
        if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: app.uiDefaultDataFolder){
            let encodedUrl = Data(url.absoluteString.utf8).base64EncodedString()
            if let urlToOpen = URL(string: "\(runningLC)://livecontainer-launch?bundle-name=\(bundleId)&open-url=\(encodedUrl)"),
               await UIApplication.shared.open(urlToOpen) {
                NSLog("[LC] urlToOpen = \(urlToOpen.absoluteString)")
                isPresent = false
                return
            }

        }
        
        do {
            try await app.runApp(urlStr: url.absoluteString)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    public func onURLSchemeDetected(url: URL) async {
        var appToLaunch : LCAppModel? = nil
        var appListsToConsider = [sharedModel.apps]
        
        if url.scheme?.lowercased() == "itms-services", let handler = itmsServicesHandler {
            installAppAlertMsg = "lc.webView.installAppDesc"
            
            if let doInstall = await installAppAlert.open(), !doInstall {
                return
            }
            isPresent = false
            Task { await handler(url.absoluteString) }
            return
        }
        
        if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            appListsToConsider.append(sharedModel.hiddenApps)
        }
        appLoop:
        for appList in appListsToConsider {
            for app in appList {
                if let schemes = app.appInfo.urlSchemes(), let targetScheme = url.scheme {
                    for scheme in schemes {
                        if let scheme = scheme as? String, scheme.caseInsensitiveCompare(targetScheme) == .orderedSame {
                            appToLaunch = app
                            break appLoop
                        }
                    }
                }
            }
        }
    
        
        guard let appToLaunch = appToLaunch else {
            errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(url.scheme ?? "")
            errorShow = true
            return
        }
        
        if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        runAppAlertMsg = "lc.webView.pageLaunch %@".localizeWithFormat(appToLaunch.appInfo.displayName()!)
        
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            return
        }
        
        await launchToApp(app: appToLaunch, url: url)
        
    }
    
    public func onUniversalLinkDetected(url: URL, bundleIDs: [String]) async {
        var bundleIDToAppDict: [String: LCAppModel] = [:]
        for app in sharedModel.apps {
            bundleIDToAppDict[app.appInfo.bundleIdentifier()!] = app
        }
        if !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") || sharedModel.isHiddenAppUnlocked {
            for app in sharedModel.hiddenApps {
                bundleIDToAppDict[app.appInfo.bundleIdentifier()!] = app
            }
        }
        
        var appToLaunch: LCAppModel? = nil
        for bundleID in bundleIDs {
            if let app = bundleIDToAppDict[bundleID] {
                appToLaunch = app
                break
            }
        }
        guard let appToLaunch = appToLaunch else {
            return
        }
        
        if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        runAppAlertMsg = "lc.webView.pageCanBeOpenIn %@".localizeWithFormat(appToLaunch.appInfo.displayName()!)
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            return
        }
        await launchToApp(app: appToLaunch, url: url)
    }
}

private struct LCWebViewGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    var isInteractive = false

    func body(content: Content) -> some View {
        content.glassEffect(.regular.interactive(isInteractive), in: shape)
    }
}

@MainActor
private final class WebViewDelegate: NSObject, WKNavigationDelegate {
    private var onTitleChange: @MainActor (String) -> Void
    private var urlSchemeHandler: @MainActor (URL) async -> Void
    private var universalLinkHandler: @MainActor (URL, [String]) async -> Void // url, [String] of all apps that can open this web page
    var domainBundleIdDict: [String: [String]] = [:]
    
    init(
        onTitleChange: @escaping @MainActor (String) -> Void,
        urlSchemeHandler: @escaping @MainActor (URL) async -> Void,
        universalLinkHandler: @escaping @MainActor (URL, [String]) async -> Void
    ) {
        self.onTitleChange = onTitleChange
        self.urlSchemeHandler = urlSchemeHandler
        self.universalLinkHandler = universalLinkHandler
        super.init()
    }
    
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let policy = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return policy
        }
        if scheme == "https" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadDomainAssociations(url: url)
                if let host = url.host, let appIDs = self.domainBundleIdDict[host] {
                    await self.universalLinkHandler(url, appIDs)
                }
            }
            return policy
        }
        if scheme == "http" || scheme == "about" || scheme == "itms-apps" {
            return policy
        }
        Task { @MainActor [weak self] in
            await self?.urlSchemeHandler(url)
        }
        return policy
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onTitleChange(webView.title ?? "")
    }
    
    func loadDomainAssociations(url: URL) async {
        if url.scheme?.lowercased() != "https" || url.host == nil {
            return
        }
        guard let host = url.host else {
            return
        }
        if self.domainBundleIdDict[host] != nil {
            return
        }
        
        // download and read apple-app-site-association
        let appleAppSiteAssociationURLs = [
            URL(string: "https://\(host)/apple-app-site-association"),
            URL(string: "https://\(host)/.well-known/apple-app-site-association")
        ].compactMap { $0 }

        var collectedBundleIds: [String] = []
        await withTaskGroup(of: [String].self) { group in
            for siteAssociationURL in appleAppSiteAssociationURLs {
                group.addTask {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: siteAssociationURL)
                        let siteAssociationObj = try JSONDecoder().decode(SiteAssociation.self, from: data)
                        guard let detailItems = siteAssociationObj.applinks?.details else {
                            return []
                        }
                        return detailItems.flatMap { $0.getBundleIds() }
                    } catch {
                        return []
                    }
                }
            }
            for await ids in group {
                for id in ids where !collectedBundleIds.contains(id) {
                    collectedBundleIds.append(id)
                }
            }
        }
        if !collectedBundleIds.isEmpty {
            self.domainBundleIdDict[host] = collectedBundleIds
        }
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let contentInsets: UIEdgeInsets

    func makeUIView(context: Context) -> WKWebView {
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osStr = "\(v.majorVersion)_\(v.minorVersion)\(v.patchVersion > 0 ? "_\(v.patchVersion)" : "")"
        let safariStr = "\(v.majorVersion).\(v.minorVersion)"
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(osStr) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariStr) Mobile/15E148 Safari/604.1"
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let scrollView = uiView.scrollView
        guard scrollView.contentInset != contentInsets else {
            return
        }
        let isAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top
        scrollView.contentInset = contentInsets
        scrollView.scrollIndicatorInsets = contentInsets
        if isAtTop {
            scrollView.contentOffset.y = -contentInsets.top
        }
    }
}


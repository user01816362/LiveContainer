//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class SearchContext: ObservableObject {
    @Published var query: String = "" {
        didSet {
            scheduleDebounce()
        }
    }
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var debounceTask: Task<Void, Never>?

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let currentQuery = query
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.isTyping = true
            self.debouncedQuery = currentQuery
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.isTyping = false
        }
    }

    deinit {
        debounceTask?.cancel()
    }
}

struct AppReplaceOption : Hashable, Sendable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var choosingIPAForEdit = false
    @State var pendingPreInstallSession: LCPackageStagingSession?
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0

    @AppStorage("LCEditBeforeInstall", store: LCUtils.appGroupUserDefault) private var editBeforeInstall = false

    @State var installOptions: [AppReplaceOption] = []
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject private var downloadManager: LCDownloadManager
    @ObservedObject private var sourcesVM = AltStoreSourcesViewModel.shared
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    @State private var didRunAutoCleanOnStartup = false
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    @StateObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var body: some View {
        applySheetsAndLifecycle(
            applyAlerts(
                NavigationStack {
                    appListScrollView
                }
            )
        )
    }

    @ViewBuilder
    private var updatesReadyBanner: some View {
        if !sourcesVM.availableUpdates.isEmpty && sharedModel.multiLCStatus != 2 {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("lc.appBanner.updatesReady %lld".localizeWithFormat(sourcesVM.availableUpdates.count))
                            .font(.subheadline.weight(.semibold))
                        Text(sourcesVM.availableUpdates.map(\.installedApp.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("lc.appBanner.updateAll".loc) {
                        sourcesVM.enqueueUpdateAll()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var visibleAppsSection: some View {
        LazyVStack {
            ForEach(filteredApps, id: \.self) { app in
                LCAppBanner(appModel: app, delegate: self, updateCandidate: sourcesVM.updateCandidate(for: app))
            }
            .transition(.scale)
        }
        .padding()
        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)
    }

    @ViewBuilder
    private var strictHiddenAppsView: some View {
        if sharedModel.isHiddenAppUnlocked {
            LazyVStack {
                HStack {
                    Text("lc.appList.hiddenApps".loc)
                        .font(.system(.title2).bold())
                    Spacer()
                }

                ForEach(filteredHiddenApps, id: \.self) { app in
                    LCAppBanner(appModel: app, delegate: self, updateCandidate: sourcesVM.updateCandidate(for: app))
                }
                .transition(.scale)
            }
            .padding()
            .transition(.opacity)
            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)

            if sharedModel.hiddenApps.count == 0 {
                Text("lc.appList.hideAppTip".loc)
                    .foregroundStyle(.gray)
            }
        }
    }

    private var regularHiddenAppsView: some View {
        LazyVStack {
            HStack {
                Text("lc.appList.hiddenApps".loc)
                    .font(.system(.title2).bold())
                Spacer()
            }
            ForEach(filteredHiddenApps, id: \.self) { app in
                if sharedModel.isHiddenAppUnlocked {
                    LCAppBanner(appModel: app, delegate: self, updateCandidate: sourcesVM.updateCandidate(for: app))
                } else {
                    LCAppSkeletonBanner()
                }
            }
            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
            .onTapGesture {
                Task { await authenticateUser() }
            }
        }
        .padding()
        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
    }

    private var visibleAppCount: Int {
        sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
    }

    private var appCounterText: String {
        let count = visibleAppCount
        if count > 0 || searchContext.debouncedQuery != "" {
            return "lc.appList.appCounter %lld".localizeWithFormat(count)
        } else if sharedModel.multiLCStatus == 2 {
            return "lc.appList.convertToSharedToShowInLC2".loc
        } else {
            return "lc.appList.installTip".loc
        }
    }

    private var appCounterFooter: some View {
        Text(appCounterText)
            .padding(.horizontal)
            .foregroundStyle(.gray)
            .animation(searchContext.isTyping ? nil : .easeInOut, value: visibleAppCount)
            .onTapGesture(count: 3) {
                Task { await authenticateUser() }
            }
    }

    private var hiddenAppsSection: some View {
        VStack {
            if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                strictHiddenAppsView
            } else if sharedModel.hiddenApps.count > 0 {
                regularHiddenAppsView
            }
            appCounterFooter
        }
        .animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))
    }

    private var appListScrollView: some View {
        ScrollView {
            updatesReadyBanner
            visibleAppsSection
            hiddenAppsSection

            if sharedModel.multiLCStatus == 2 {
                Text("lc.appList.manageInPrimaryTip".loc)
                    .foregroundStyle(.gray)
                    .padding()
            }
        }
        .navigationBarProgressBar(show: $installprogressVisible, progress: $installProgressPercentage)
        .coordinateSpace(name: "scroll")
        .onAppear {
            if !didAppear {
                onAppear()
            }
        }
        .navigationTitle("lc.appList.myApps".loc)
        .navigationDestination(isPresented: $isNavigationActive) {
            if let navigateTo {
                navigateTo
            }
        }
        .toolbar {
            appListToolbar
        }
    }

    @ToolbarContentBuilder
    private var appListToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if UserDefaults.sideStoreExist() {
                let iconSize = UIFont.preferredFont(forTextStyle: .body).lineHeight
                Button {
                    LCUtils.openSideStore(delegate: self)
                } label: {
                    IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                        .frame(width: iconSize, height: iconSize)
                }
            } else {
                Button("Help", systemImage: "questionmark") {
                    helpPresent = true
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("lc.appList.openLink".loc, systemImage: "link", action: {
                Task { await onOpenWebViewTapped() }
            })
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                    ForEach(AppSortType.allCases, id: \.self) { sortType in
                        Label(sortType.displayName, systemImage: sortType.systemImage)
                            .tag(sortType)
                    }
                }
                .onChange(of: sharedAppSortManager.appSortType) { _, _ in
                    if sharedAppSortManager.appSortType == .custom {
                        customSortViewPresent = true
                    }
                }
                if sharedAppSortManager.appSortType == .custom {
                    Divider()

                    Button {
                        customSortViewPresent = true
                    } label: {
                        Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                    }
                }
            } label: {
                Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .topBarPinnedTrailing) {
            if sharedModel.multiLCStatus != 2 {
                if !installprogressVisible {
                    Menu {
                        Button("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus", action: {
                            choosingIPA = true
                        })
                        Button("lc.appList.installAndEditIpa".loc, systemImage: "slider.horizontal.2.square.on.square", action: {
                            choosingIPAForEdit = true
                        })
                        Button("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus", action: {
                            Task { await startInstallFromUrl() }
                        })
                    } label: {
                        Label("add", systemImage: "plus")
                    }
                } else {
                    ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                }
            }
        }
    }

    private func applyAlerts<Content: View>(_ content: Content) -> some View {
        content
            .alert("lc.common.error".loc, isPresented: $errorShow) {
                Button("lc.common.ok".loc, action: {
                })
                Button("lc.common.copy".loc, action: {
                    copyError()
                })
            } message: {
                Text(errorInfo)
            }
            .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
                Task { await startInstallApp(fileUrls[0], forceEdit: false) }
            }, onDismiss: {
                choosingIPA = false
            })
            .betterFileImporter(isPresented: $choosingIPAForEdit, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
                Task { await startInstallApp(fileUrls[0], forceEdit: true) }
            }, onDismiss: {
                choosingIPAForEdit = false
            })
            .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
                ForEach(installOptions, id: \.self) { installOption in
                    Button(role: installOption.isReplace ? .destructive : nil, action: {
                        installReplaceAlert.close(result: installOption)
                    }, label: {
                        Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                    })
                }
                Button(role: .cancel, action: {
                    installReplaceAlert.close(result: nil)
                }, label: {
                    Text("lc.appList.abortInstallation".loc)
                })
            } message: {
                Text("lc.appList.installReplaceTip".loc)
            }
            .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
                Button(role: .destructive) {
                    runWhenMultitaskAlert.close(result: true)
                } label: {
                    Text("lc.common.continue".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    runWhenMultitaskAlert.close(result: false)
                }
            } message: {
                Text("lc.appBanner.confirmRunWhenMultitasking".loc)
            }
            .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented: $generatedIconStyleSelector.show) {
                Button {
                    generatedIconStyleSelector.close(result: .Light)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.light".loc)
                }
                Button {
                    generatedIconStyleSelector.close(result: .Dark)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.dark".loc)
                }
                Button {
                    generatedIconStyleSelector.close(result: .Original)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.original".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    generatedIconStyleSelector.close(result: nil)
                }
            }
            .textFieldAlert(
                isPresented: $webViewUrlInput.show,
                title: "lc.appList.enterUrlTip".loc,
                text: $webViewUrlInput.initVal,
                placeholder: "scheme://",
                action: { newText in
                    webViewUrlInput.close(result: newText)
                },
                actionCancel: { _ in
                    webViewUrlInput.close(result: nil)
                }
            )
            .textFieldAlert(
                isPresented: $installUrlInput.show,
                title: "lc.appList.installUrlInputTip".loc,
                text: $installUrlInput.initVal,
                placeholder: "https://",
                action: { newText in
                    installUrlInput.close(result: newText)
                },
                actionCancel: { _ in
                    installUrlInput.close(result: nil)
                }
            )
    }

    private func applySheetsAndLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $jitAlert.show, onDismiss: {
                jitAlert.close(result: false)
            }) {
                JITEnablingModal
            }
            .onChange(of: jitAlert.show) { _, newValue in
                sharedModel.isJITModalOpen = newValue
            }
            .fullScreenCover(isPresented: $webViewOpened) {
                LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                    await installFromPlist(urlStr: urlStr)
                })
            }
            .fullScreenCover(isPresented: $safariViewOpened) {
                SafariView(url: $safariViewURL)
            }
            .sheet(isPresented: $helpPresent) {
                LCHelpView(isPresent: $helpPresent)
            }
            .sheet(isPresented: $customSortViewPresent) {
                LCCustomSortView()
            }
            .sheet(item: $pendingPreInstallSession) { session in
                LCPackageEditorView(
                    session: session,
                    onCancel: {
                        pendingPreInstallSession = nil
                    },
                    onPreInstallReady: { readySession in
                        pendingPreInstallSession = nil
                        Task { await finalizeEditedPreInstallSession(readySession) }
                    }
                )
            }
            .onAppear {
                if !isViewAppeared {
                    if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                        Task { await openWebView(urlString: webpageUrlStr) }
                        UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                    }

                    guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                    sharedModel.deepLink = nil
                    handleURL(url: link)
                    isViewAppeared = true
                }
            }
            .onChange(of: sharedModel.deepLink) { _, link in
                guard sharedModel.selectedTab == .apps, let link else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
            }
            .onDrop(of: [.url], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: Notification.Name("LC.OpenDroppedWebURL"), object: url)
                    }
                }
                return true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LC.OpenDroppedWebURL")).receive(on: RunLoop.main)) { note in
                guard let url = note.object as? URL else { return }
                Task { @MainActor in
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), !urlToOpen.isEmpty else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification).receive(on: RunLoop.main)) { obj in
                if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                    Task { await installFromUrl(urlStr: installUrl.absoluteString) }
                }
            }
            .searchable(text: $searchContext.query)
    }
    
    var JITEnablingModal : some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        sharedModel.appModelDelegate = self
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        Task {
            await autoCleanEnabledAppsOnStartup()
        }
        didAppear = true
    }
    
    func autoCleanEnabledAppsOnStartup() async {
        if didRunAutoCleanOnStartup {
            return
        }
        didRunAutoCleanOnStartup = true
        
        let appsToConsider = sharedModel.apps + sharedModel.hiddenApps
        for app in appsToConsider {
            if !app.uiAutoCleanCacheOnLaunch {
                continue
            }
            guard let bundlePath = app.appInfo.bundlePath() else {
                continue
            }
            
            let containerTargets = app.uiContainers.map { container in
                LCAppContainerTarget(url: container.containerURL, needsSecurityScope: container.storageBookMark != nil)
            }
            
            do {
                let cleanupResult = try await Task.detached(priority: .utility) {
                    try lcClearAppCacheAndTemp(bundlePath: bundlePath, containerTargets: containerTargets)
                }.value
                
                app.appInfo.clearIconCache()
                app.appInfo.recordAutoClean(withBytesSaved: cleanupResult.removedBytes)
                app.objectWillChange.send()
            } catch {
                NSLog("[LC] auto-clean failed for %@: %@", app.displayName, error.localizedDescription)
            }
        }
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
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
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            try? await Task.sleep(for: .milliseconds(100))
        }
        webViewOpened = true
    }


    
    func startInstallApp(_ fileUrl: URL, forceEdit: Bool = false) async {
        if forceEdit || editBeforeInstall {
            self.installProgressPercentage = 0.0
            self.installprogressVisible = true
            do {
                let stagedSession = try await LCAppInstaller.stageIPA(
                    at: fileUrl,
                    sourceIPAURLToDeleteOnFinish: fileUrl,
                    progressHandler: { fraction, _ in
                        self.installProgressPercentage = Float(fraction)
                    }
                )
                self.installprogressVisible = false
                self.pendingPreInstallSession = stagedSession
            } catch {
                try? FileManager.default.removeItem(at: fileUrl)
                errorInfo = error.localizedDescription
                errorShow = true
                self.installprogressVisible = false
            }
            return
        }

        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }

    func finalizeEditedPreInstallSession(_ session: LCPackageStagingSession) async {
        defer { session.cleanup(deleteSourceIPA: true) }
        self.installProgressPercentage = 0.75
        self.installprogressVisible = true
        defer { self.installprogressVisible = false }

        do {
            let outcome = try await LCAppInstaller.finalizeStagedInstall(
                session: session,
                chooseAppToReplace: { options in
                    self.installOptions = options
                    return await self.installReplaceAlert.open()
                },
                progressHandler: { fraction, _ in
                    self.installProgressPercentage = Float(fraction)
                }
            )
            if let warning = outcome.warningMessage {
                self.errorInfo = warning
                self.errorShow = true
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installIpaFile(_ url: URL) async throws {
        self.installProgressPercentage = 0.0
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }

        let outcome = try await LCAppInstaller.installIPA(
            at: url,
            chooseAppToReplace: { options in
                self.installOptions = options
                return await self.installReplaceAlert.open()
            },
            progressHandler: { fraction, _ in
                self.installProgressPercentage = Float(fraction)
            }
        )

        if let warning = outcome.warningMessage {
            self.errorInfo = warning
            self.errorShow = true
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        if installUrl.isFileURL {
            if self.installprogressVisible {
                return
            }
            self.installprogressVisible = true
            defer {
                self.installprogressVisible = false
            }
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        downloadManager.enqueueAppDownload(
            url: installUrl,
            displayName: installUrl.deletingPathExtension().lastPathComponent
        )
    }
    
    func removeApp(app: LCAppModel) {
        sharedModel.apps.removeAll { now in
            return app == now
        }
        sharedModel.hiddenApps.removeAll { now in
            return app == now
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        let schemes = (app.appInfo.urlSchemes() as? [Any]) ?? []
        if app.appInfo.isHidden {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            if !sharedModel.hiddenApps.contains(app) {
                sharedModel.hiddenApps.append(app)
            }
            if !schemes.isEmpty {
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: schemes)
            }
        } else {
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            if !sharedModel.apps.contains(app) {
                sharedModel.apps.append(app)
            }
            if !schemes.isEmpty {
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: schemes)
            }
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
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
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                self.jitLog += "\(newMsg)\n"
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if sharedModel.apps.contains(where: { app in
                            app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            let safeAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
                            if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(safeAppName)&pid=\(pid)&relaunchApp=false&forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        let safeAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
                        if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(safeAppName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if sharedModel.apps.contains(where: { app in
                            app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        return await generatedIconStyleSelector.open()
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}

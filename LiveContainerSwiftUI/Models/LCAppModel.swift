import Foundation

@MainActor
protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt) async
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

@MainActor
final class LCAppModel: ObservableObject, Identifiable, Hashable {

    @Published var appInfo : LCAppInfo

    @Published var isAppRunning = false
    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?

    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiHelperProcessesSupport: Bool {
        didSet {
            appInfo.helperProcessesSupport = uiHelperProcessesSupport
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }

    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    @Published var uiFixBackgroundTaskIdentifiers : Bool {
        didSet {
            appInfo.fixBackgroundTaskIdentifiers = uiFixBackgroundTaskIdentifiers
        }
    }
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }

    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }

    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
        }
    }

    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }

    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }

    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }

    @Published var uiAutoCleanCacheOnLaunch: Bool {
        didSet {
            appInfo.autoCleanCacheOnLaunch = uiAutoCleanCacheOnLaunch
        }
    }

    @Published var uiDebugModeEnabled: Bool {
        didSet {
            appInfo.debugModeEnabled = uiDebugModeEnabled
        }
    }

    @Published var uiExportTweakSymbolsGlobally: Bool {
        didSet {
            appInfo.exportTweakSymbolsGlobally = uiExportTweakSymbolsGlobally
        }
    }

    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }

    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }

    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }

    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }

    public var shouldLaunchInMultitaskMode : Bool {
        get {
            return uiIsMultitaskModeSpecificed == .yes ||
            (uiIsMultitaskModeSpecificed == .default && UserDefaults.standard.bool(forKey: "LCLaunchInMultitaskMode"))
        }
    }

    @Published var supportedLanguages : [String]?

    var delegate : LCAppModelDelegate?

    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }

        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiHelperProcessesSupport = appInfo.helperProcessesSupport
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiFixBackgroundTaskIdentifiers = appInfo.fixBackgroundTaskIdentifiers
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiRemark = appInfo.remark ?? ""
        self.uiAutoCleanCacheOnLaunch = appInfo.autoCleanCacheOnLaunch
        self.uiDebugModeEnabled = appInfo.debugModeEnabled
        self.uiExportTweakSymbolsGlobally = appInfo.exportTweakSymbolsGlobally
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }

    nonisolated static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        if isAppRunning {
            return
        }

        if uiContainers.isEmpty {
            let newName = NSUUID().uuidString
            let newContainer = LCContainer.makeNewContainer(folderName: newName, name: newName, isShared: uiIsShared)
            uiContainers.append(newContainer)
            if uiSelectedContainer == nil {
                uiSelectedContainer = newContainer;
            }
            appInfo.containers = uiContainers;
            newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
        }
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        let currentDataFolder = containerFolderName ?? uiSelectedContainer?.folderName

        let classicMode = appInfo.defaultClassicMode
        let multitask = classicMode == 0 ? (multitask ?? shouldLaunchInMultitaskMode) : false

        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }

        }

        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }

        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        if
            let fn = uiSelectedContainer?.folderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension

            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            if let targetURL = openURLComp.url, await UIApplication.shared.open(targetURL) {
                return
            }
        }

        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        if MultitaskManager.isMultitasking() && !multitask {
            if self.uiIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(uiSelectedContainer?.folderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "livecontainer-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = uiSelectedContainer?.folderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }

                    launchURLComp.queryItems = queryItems

                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }

            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
        }

        isAppRunning = true
        defer {
            isAppRunning = false
        }
        try await signApp(force: false)

        if let bundleIdOverride {
            UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
        } else {
            UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
        }
        if let urlStr {
            UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")

        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        if jitNeeded {
            if multitask {
                let displayName = appInfo.displayName() ?? ""
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    LCUtils.launchMultitaskGuestApp(displayName) { [weak self] pidNumber, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let pidNumber else {
                            continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            return
                        }
                        Task { @MainActor [weak self] in
                            if let self {
                                let name = self.appInfo.displayName() ?? ""
                                if let scriptData = self.jitLaunchScriptJs, !scriptData.isEmpty {
                                    await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: name)
                                } else {
                                    await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: name)
                                }
                            }
                            continuation.resume()
                        }
                    }
                }
            } else {
                // Non-multitask JIT flow remains unchanged
                if let scriptData = jitLaunchScriptJs, !scriptData.isEmpty {
                    await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode)
                } else {
                    await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode)
                }
            }
        } else if multitask {
            try await LCUtils.launchMultitaskGuestApp(appInfo.displayName())
        } else {
            if FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
                try fileContents?.write(to: fileURL)
            }
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }

        // Record the launch time
        appInfo.lastLaunched = Date()
    }

    func forceResign() async throws {
        if isAppRunning {
            return
        }
        isAppRunning = true
        defer {
            isAppRunning = false
        }
        try await signApp(force: true)
    }

    func signApp(force: Bool = false) async throws {
        defer {
            self.observer?.invalidate()
            self.observer = nil
            self.isSigningInProgress = false
        }

        let (signSuccess, signError): (Bool, String?) = await withCheckedContinuation { continuation in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                continuation.resume(returning: (success, error))
            }, progressHandler: { [weak self] signProgress in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.isSigningInProgress = true
                    self.observer = signProgress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] p, _ in
                        let fraction = p.fractionCompleted
                        Task { @MainActor [weak self] in
                            self?.signProgress = fraction
                        }
                    }
                }
            }, forceSign: force)
        }
        if let signError, !signSuccess {
            throw signError.loc
        }

        // sign its tweak
        guard let tweakFolder = appInfo.tweakFolder else {
            return
        }

        let tweakFolderUrl : URL
        if(appInfo.isShared) {
            tweakFolderUrl = LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)
        } else {
            tweakFolderUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
        }
        try await LCUtils.signTweaks(tweakFolderUrl: tweakFolderUrl, force: force) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSigningInProgress = true
            }
        }

        // sign global tweak
        try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSigningInProgress = true
            }
        }
    }

    func setLocked(newLockState: Bool) async {
        // if locked state in appinfo already match with the new state, we just the change
        if appInfo.isLocked == newLockState {
            return
        }

        if newLockState {
            appInfo.isLocked = true
        } else {
            // authenticate before cancelling locked state
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    uiIsLocked = true
                    return
                }
            } catch {
                uiIsLocked = true
                return
            }

            // auth pass, we need to cancel app's lock and hidden state
            appInfo.isLocked = false
            if appInfo.isHidden {
                await toggleHidden()
            }
        }
    }

    func toggleHidden() async {
        delegate?.closeNavigationView()
        if appInfo.isHidden {
            appInfo.isHidden = false
            uiIsHidden = false
        } else {
            appInfo.isHidden = true
            uiIsHidden = true
        }
        delegate?.changeAppVisibility(app: self)
    }

    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }

    }

    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        if let urlScheme {
            UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
        }
        var found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
        if !found {
            found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
        }
        if urlScheme != nil, !found {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
        }
        return found
    }
    
    static func copy(fromApp: LCAppModel, toAppInfo: LCAppInfo) {
        // copy previous configuration to new app
        toAppInfo.autoSaveDisabled = true
        toAppInfo.isLocked = fromApp.appInfo.isLocked
        toAppInfo.isHidden = fromApp.appInfo.isHidden
        toAppInfo.isShared = fromApp.appInfo.isShared
        
        toAppInfo.containerInfo = fromApp.appInfo.containerInfo
        toAppInfo.tweakFolder = fromApp.appInfo.tweakFolder
        toAppInfo.dataUUID = fromApp.appInfo.dataUUID
        
        toAppInfo.spoofSDKVersion = fromApp.appInfo.spoofSDKVersion
        toAppInfo.doSymlinkInbox = fromApp.appInfo.doSymlinkInbox

        toAppInfo.selectedLanguage = fromApp.appInfo.selectedLanguage

        toAppInfo.orientationLock = fromApp.appInfo.orientationLock
        toAppInfo.dontInjectTweakLoader = fromApp.appInfo.dontInjectTweakLoader
        toAppInfo.hideLiveContainer = fromApp.appInfo.hideLiveContainer
        toAppInfo.dontLoadTweakLoader = fromApp.appInfo.dontLoadTweakLoader
        toAppInfo.dontSign = fromApp.appInfo.dontSign
        toAppInfo.doUseLCBundleId = fromApp.appInfo.doUseLCBundleId
        toAppInfo.fixFilePickerNew = fromApp.appInfo.fixFilePickerNew
        toAppInfo.fixLocalNotification = fromApp.appInfo.fixLocalNotification
        toAppInfo.fixBackgroundTaskIdentifiers = fromApp.appInfo.fixBackgroundTaskIdentifiers
        
        toAppInfo.isJITNeeded = fromApp.appInfo.isJITNeeded
        toAppInfo.jitLaunchScriptJs = fromApp.appInfo.jitLaunchScriptJs
        toAppInfo.helperProcessesSupport = fromApp.appInfo.helperProcessesSupport
        
        toAppInfo.multitaskSpecified = fromApp.appInfo.multitaskSpecified
        toAppInfo.classicMode = fromApp.appInfo.classicMode
        toAppInfo.selected32BitEmulator = fromApp.appInfo.selected32BitEmulator
        toAppInfo.remark = fromApp.appInfo.remark
        toAppInfo.autoCleanCacheOnLaunch = fromApp.appInfo.autoCleanCacheOnLaunch
        toAppInfo.lastAutoCleanDate = fromApp.appInfo.lastAutoCleanDate
        toAppInfo.autoCleanTotalBytesSaved = fromApp.appInfo.autoCleanTotalBytesSaved
        toAppInfo.debugModeEnabled = fromApp.appInfo.debugModeEnabled
        toAppInfo.exportTweakSymbolsGlobally = fromApp.appInfo.exportTweakSymbolsGlobally
        toAppInfo.sourceURL = fromApp.appInfo.sourceURL
        toAppInfo.ignoredUpdateVersion = fromApp.appInfo.ignoredUpdateVersion
        
        toAppInfo.lastLaunched = fromApp.appInfo.lastLaunched
        
        toAppInfo.autoSaveDisabled = false
        toAppInfo.save()
    }
}

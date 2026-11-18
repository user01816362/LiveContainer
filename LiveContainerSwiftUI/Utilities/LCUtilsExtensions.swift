//
//  LCUtilsExtensions.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import LocalAuthentication

extension LCUtils {
    public static var appGroupUserDefault: UserDefaults {
        UserDefaults(suiteName: LCSharedUtils.appGroupID()) ?? UserDefaults.standard
    }
    
    public static func signTweaks(tweakFolderUrl: URL, force: Bool = false, progressHandler: (@Sendable (Progress) -> Void)? = nil) async throws {
        guard LCSharedUtils.certificatePassword() != nil else {
            return
        }
        let fm = FileManager.default
        // a disabled folder is renamed to .disabled; skip it, it gets signed again once re-enabled
        if !fm.fileExists(atPath: tweakFolderUrl.path) {
            let disabledUrl = tweakFolderUrl.deletingLastPathComponent().appendingPathComponent(tweakFolderUrl.lastPathComponent + ".disabled")
            if fm.fileExists(atPath: disabledUrl.path) {
                return
            }
        }
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: tweakFolderUrl.path, isDirectory: &isFolder), isFolder.boolValue else {
            return
        }

        guard let enumerator = fm.enumerator(
            at: tweakFolderUrl,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var filesToSign: [URL] = []
        var seenPaths = Set<String>()

        while let entry = enumerator.nextObject() as? URL {
            let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let isDir = resourceValues?.isDirectory ?? false
            let name = entry.lastPathComponent
            let baseName = name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name

            if isDir {
                if name.hasSuffix(".disabled") && !baseName.hasSuffix(".framework") {
                    enumerator.skipDescendants()
                    continue
                }
                if baseName.hasSuffix(".framework") {
                    enumerator.skipDescendants()
                    if let frameworkBundle = Bundle(url: entry),
                       let executableURL = frameworkBundle.executableURL {
                        let resolvedPath = executableURL.standardizedFileURL.path
                        if seenPaths.insert(resolvedPath).inserted && (force || !checkCodeSignature((resolvedPath as NSString).utf8String)) {
                            filesToSign.append(executableURL)
                        }
                    }
                }
                continue
            }

            guard (resourceValues?.isRegularFile ?? false) && baseName.hasSuffix(".dylib") else {
                continue
            }
            let resolvedPath = entry.standardizedFileURL.path
            if seenPaths.insert(resolvedPath).inserted && (force || !checkCodeSignature((resolvedPath as NSString).utf8String)) {
                filesToSign.append(entry)
            }
        }

        if filesToSign.isEmpty {
            return
        }

        for fileURL in filesToSign {
            LCPatchMachOFixupARM64eSlice((fileURL.path as NSString).utf8String)
        }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let progress = signFilesWithZSign(with: filesToSign) { success, error in
                if success {
                    c.resume()
                    return
                }
                if let error {
                    c.resume(throwing: error)
                } else {
                    c.resume()
                }
            }
            if let progress {
                progressHandler?(progress)
            }
        }
    }

    @MainActor
    public static func authenticateUser() async throws -> Bool {
        if DataManager.shared.model.isHiddenAppUnlocked {
            return true
        }

        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            if let evaluationError = authError as? LAError, evaluationError.code == .passcodeNotSet {
                DataManager.shared.model.isHiddenAppUnlocked = true
                return true
            }
            if let authError {
                throw authError
            }
            return false
        }

        let reason = "lc.utils.requireAuthentication".loc
        let success: Bool = try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, evaluationError in
                if ok {
                    continuation.resume(returning: true)
                } else if let evaluationError = evaluationError as? LAError,
                          evaluationError.code == .userCancel || evaluationError.code == .appCancel {
                    continuation.resume(returning: false)
                } else if let evaluationError {
                    continuation.resume(throwing: evaluationError)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        if success {
            DataManager.shared.model.isHiddenAppUnlocked = true
        }
        return success
    }
    
    public static func getStoreName() -> String {
        switch LCUtils.store() {
        case .AltStore:
            return "AltStore"
        case .SideStore:
            return "SideStore"
        case .ADP:
            return "ADP"
        default:
            return "Unknown Store"
        }
    }
    
    public static func removeAppKeychain(dataUUID label: String) {
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity].forEach {
          let status = SecItemDelete([
            kSecClass as String: $0,
            "alis": label,
          ] as CFDictionary)
          if status != errSecSuccess && status != errSecItemNotFound {
              //Error while removing class $0
              NSLog("[LC] Failed to find keychain items: \(status)")
          }
        }
    }
    
    public static func forEachInstalledLC(isFree: Bool, block: (String, inout Bool) -> Void) {
        for scheme in (LCSharedUtils.lcUrlSchemes() ?? []) {
            if scheme == UserDefaults.lcAppUrlScheme() {
                continue
            }
            
            // Check if the app is installed
            guard LCUtils.isAppSchemeInstalled(scheme) else {
                continue
            }
            
            // Check shared utility logic
            if isFree && LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }
            
            var shouldBreak = false
            block(scheme, &shouldBreak)
            
            if shouldBreak {
                break
            }
        }
    }

    @MainActor
    public static func askForJIT(withScript script: String? = nil, appName: String? = nil, classicMode: UInt = 0, onServerMessage: (@MainActor (String) -> Void)? = nil) async -> Bool {
        // if LiveContainer is installed by TrollStore
        let tsPath = "\(Bundle.main.bundlePath)/../_TrollStore"
        if (access((tsPath as NSString).utf8String, 0) == 0) {
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
            return true
        }
        
        guard let groupUserDefaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()),
              let jitEnabler = JITEnablerType(rawValue: groupUserDefaults.integer(forKey: "LCJITEnablerType")) else {
            return false
        }
        
        if(jitEnabler == .SideJITServer){
            guard
                  let sideJITServerAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress"),
                  let deviceUDID = groupUserDefaults.string(forKey: "LCDeviceUDID"),
                  !sideJITServerAddress.isEmpty && !deviceUDID.isEmpty else {
                return false
            }
            
            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")
            
            do {
                let launchJITUrlStr = "\(sideJITServerAddress)/\(deviceUDID)/\(Bundle.main.bundleIdentifier ?? "")"
                guard let launchJITUrl = URL(string: launchJITUrlStr) else { return false }
                let session = URLSession.shared
                
                onServerMessage?("Contacting SideJITServer at \(sideJITServerAddress)...")
                let request = URLRequest(url: launchJITUrl)
                let (data, _) = try await session.data(for: request)
                onServerMessage?(String(decoding: data, as: UTF8.self))
                
            } catch {
                onServerMessage?("Failed to contact SideJITServer: \(error)")
            }
            
            return false
        } else if (jitEnabler == .JITStreamerEBLegacy) {
            var JITStresmerEBAddress = groupUserDefaults.string(forKey: "LCSideJITServerAddress") ?? ""
            if JITStresmerEBAddress.isEmpty {
                JITStresmerEBAddress = "http://[fd00::]:9172"
            }
            
            onServerMessage?("Please make sure the VPN is connected if the server is not in your local network.")
            
            do {
                
                onServerMessage?("Contacting JitStreamer-EB server at \(JITStresmerEBAddress)...")
                
                let session = URLSession.shared
                let decoder = JSONDecoder()
                
                let mountStatusUrlStr = "\(JITStresmerEBAddress)/mount"
                guard let mountStatusUrl = URL(string: mountStatusUrlStr) else { return false }
                let mountRequest = URLRequest(url: mountStatusUrl)
                
                // check mount status
                onServerMessage?("Checking mount status...")
                let (mountData, _) = try await session.data(for: mountRequest)
                let mountResponseObj = try decoder.decode(JITStreamerEBMountResponse.self, from: mountData)
                guard mountResponseObj.ok else {
                    onServerMessage?(mountResponseObj.error ?? "Mounting failed with unknown error.")
                    return false
                }
                if mountResponseObj.mounting {
                    onServerMessage?("Your device is currently mounting the developer disk image. Leave your device on and connected. Once this finishes, you can run JitStreamer again.")
                    onServerMessage?("Check \(JITStresmerEBAddress)/mount_status for mounting status.")
                    if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/mount_status") {
                        await UIApplication.shared.open(mountStatusUrl)
                    }
                    return false
                }
                
                // open safari to use /launch_app api
                if let mountStatusUrl = URL(string: "\(JITStresmerEBAddress)/launch_app/\(Bundle.main.bundleIdentifier!)") {
                    onServerMessage?("JIT acquisition will continue in the default browser.")
                    await UIApplication.shared.open(mountStatusUrl)
                }
                return false
                
                
            } catch {
                onServerMessage?("Failed to contact JitStreamer-EB server: \(error)")
            }
        } else if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
            guard let appName else { onServerMessage?("Unable to get App Name, Please try again."); return false }
            let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
            let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? appName
            var launchURLStr = "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)"
            
            if let script = script, !script.isEmpty {
                let encodedScript = script.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? script
                launchURLStr += "&script=\(encodedScript)"
            }
            
            if jitEnabler == .StosDebugLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop:
                for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stosdebug" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StosDebug is not installed in LiveContainer.")
                    return false
                }
                
                if !appToLaunch.uiIsShared {
                    onServerMessage?("StosDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stosdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)
                
                if(freeScheme == nil) {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }
                
                let launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")
                
                await UIApplication.shared.open(launchURL)
            } else {
                onServerMessage?("JIT acquisition will continue in StosDebug.")
                
                await UIApplication.shared.open(URL(string: launchURLStr)!)
            }
            
        } else if jitEnabler == .StikJIT || jitEnabler == .StikJITLC {
            let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))
            var launchURLStr = "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)"

            if let script = script, !script.isEmpty {
                let encodedScript = script.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? script
                launchURLStr += "&script-data=\(encodedScript)"
            }
            let launchURL : URL
            if jitEnabler == .StikJITLC {
                let encodedStr = Data(launchURLStr.utf8).base64EncodedString()


                var appToLaunch: LCAppModel? = nil
                // find an app that can respond to stikjit://
                appLoop:
                for app in DataManager.shared.model.apps {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == "stikjit" {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
                guard let appToLaunch else {
                    onServerMessage?("StikDebug is not installed in LiveContainer.")
                    return false
                }
                
                if !appToLaunch.uiIsShared {
                    onServerMessage?("StikDebug is installed in LiveContainer, but is not a shared app. Convert it to a shared app to continue.")
                    return false
                }
                // check if stikdebug is already running
                var freeScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)
                
                if(freeScheme == nil) {
                    // if not, try to find a free lc
                    forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                        freeScheme = scheme
                        shouldBreak = true
                    }
                }
                guard let freeScheme else {
                    onServerMessage?("No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.")
                    return false
                }
                
                launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedStr)")!
                LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                LCUtils.appGroupUserDefault.set(appToLaunch.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                onServerMessage?("JIT acquisition will continue in another LiveContainer.")
                
            } else {
                launchURL = URL(string: launchURLStr)!
                onServerMessage?("JIT acquisition will continue in StikDebug.")
            }
            await UIApplication.shared.open(launchURL)
        } else if jitEnabler == .SideStore {
            onServerMessage?("JIT acquisition will continue in SideStore.")
            let launchURL = URL(string: "sidestore://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)")!
            await UIApplication.shared.open(launchURL)
        }
        return false
    }

    static func moveFilesAtomicallyAfterPreflight(_ moves: [(URL, URL)]) throws {
        let fileManager = FileManager.default

        var seenSources = Set<URL>()
        var seenDestinations = Set<URL>()

        let normalizedMoves = moves.map { source, destination in
            (
                source.standardizedFileURL,
                destination.standardizedFileURL
            )
        }

        // MARK: - Preflight

        for (source, destination) in normalizedMoves {
            guard !source.path.isEmpty else {
                throw BatchMoveError.emptySource(source)
            }

            guard source != destination else {
                throw BatchMoveError.sourceEqualsDestination(source)
            }

            guard seenSources.insert(source).inserted else {
                throw BatchMoveError.duplicateSource(source)
            }
            
            guard fileManager.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
                throw BatchMoveError.sourceParentIsNotWritable(source.deletingLastPathComponent())
            }

            guard seenDestinations.insert(destination).inserted else {
                throw BatchMoveError.duplicateDestination(destination)
            }

            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw BatchMoveError.sourceDoesNotExist(source)
            }

            do {
                _ = try source.checkResourceIsReachable()
            } catch {
                throw BatchMoveError.sourceIsNotReachable(source, underlying: error)
            }

            guard !fileManager.fileExists(atPath: destination.path) else {
                throw BatchMoveError.destinationAlreadyExists(destination)
            }

            let parent = destination.deletingLastPathComponent()

            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
                throw BatchMoveError.destinationParentDoesNotExist(parent)
            }

            guard parentIsDirectory.boolValue else {
                throw BatchMoveError.destinationParentIsNotDirectory(parent)
            }

            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw BatchMoveError.destinationParentIsNotWritable(parent)
            }

            if isDirectory.boolValue {
                let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
                let destinationPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"

                if destinationPath.hasPrefix(sourcePath) {
                    throw BatchMoveError.moveWouldPlaceDirectoryInsideItself(
                        source: source,
                        destination: destination
                    )
                }
            }
        }

        // MARK: - Execute only after all preflight checks pass

        for (source, destination) in normalizedMoves {
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                throw BatchMoveError.moveFailed(
                    source: source,
                    destination: destination,
                    underlying: error
                )
            }
        }
    }
    
    @MainActor
    static func openSideStore(delegate: LCAppModelDelegate? = nil, urlStr: String? = nil) {
        let sideStoreApp = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared, delegate: delegate)
        
        Task { @MainActor in
            do {
                try await sideStoreApp.runApp(bundleIdOverride: "builtinSideStore", urlStr: urlStr)
            } catch {
                NSLog("[LC] Failed to run SideStore: \(error)")
            }
        }
    }
}

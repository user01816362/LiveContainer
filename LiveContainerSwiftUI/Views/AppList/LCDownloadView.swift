//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Persistent background download queue, shared IPA/Tweak installers,
//  and non-blocking Liquid Glass download UI.
//

import SwiftUI
import UIKit

public enum LCDownloadKind: Codable, Hashable, Sendable {
    case ipa(
        sourceURL: String?,
        version: String?,
        buildVersion: String?,
        targetAppBundleId: String?,
        ignoreUpdateKeyAfterInstall: String? = nil
    )
    case tweak(destinationFolderPath: String)

    private enum CodingKeys: String, CodingKey {
        case ipa
        case tweak
    }

    private enum IPACodingKeys: String, CodingKey {
        case sourceURL
        case version
        case buildVersion
        case targetAppBundleId
        case ignoreUpdateKeyAfterInstall
    }

    private enum TweakCodingKeys: String, CodingKey {
        case destinationFolderPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.ipa) {
            let nested = try container.nestedContainer(keyedBy: IPACodingKeys.self, forKey: .ipa)
            self = .ipa(
                sourceURL: try nested.decodeIfPresent(String.self, forKey: .sourceURL),
                version: try nested.decodeIfPresent(String.self, forKey: .version),
                buildVersion: try nested.decodeIfPresent(String.self, forKey: .buildVersion),
                targetAppBundleId: try nested.decodeIfPresent(String.self, forKey: .targetAppBundleId),
                ignoreUpdateKeyAfterInstall: try nested.decodeIfPresent(String.self, forKey: .ignoreUpdateKeyAfterInstall)
            )
        } else if container.contains(.tweak) {
            let nested = try container.nestedContainer(keyedBy: TweakCodingKeys.self, forKey: .tweak)
            self = .tweak(
                destinationFolderPath: try nested.decode(String.self, forKey: .destinationFolderPath)
            )
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown LCDownloadKind case")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ipa(sourceURL, version, buildVersion, targetAppBundleId, ignoreUpdateKeyAfterInstall):
            var nested = container.nestedContainer(keyedBy: IPACodingKeys.self, forKey: .ipa)
            try nested.encodeIfPresent(sourceURL, forKey: .sourceURL)
            try nested.encodeIfPresent(version, forKey: .version)
            try nested.encodeIfPresent(buildVersion, forKey: .buildVersion)
            try nested.encodeIfPresent(targetAppBundleId, forKey: .targetAppBundleId)
            try nested.encodeIfPresent(ignoreUpdateKeyAfterInstall, forKey: .ignoreUpdateKeyAfterInstall)
        case let .tweak(destinationFolderPath):
            var nested = container.nestedContainer(keyedBy: TweakCodingKeys.self, forKey: .tweak)
            try nested.encode(destinationFolderPath, forKey: .destinationFolderPath)
        }
    }
}

public struct LCDownloadTaskItem: Identifiable, Codable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case queued
        case downloading
        case paused
        case installing(String)
        case completed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .downloading, .installing:
                return true
            case .paused, .completed, .failed:
                return false
            }
        }

        var isFinished: Bool {
            switch self {
            case .completed, .failed:
                return true
            case .queued, .downloading, .paused, .installing:
                return false
            }
        }
    }

    public let id: UUID
    public let url: URL
    public var displayName: String
    public var iconURL: URL?
    public var kind: LCDownloadKind
    public var state: State
    public var progress: Double
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var taskIdentifier: Int?
    public let createdAt: Date

    var targetBundleId: String? {
        if case let .ipa(_, _, _, targetId, _) = kind {
            return targetId
        }
        return nil
    }

    var targetVersion: String? {
        if case let .ipa(_, version, _, _, _) = kind {
            return version
        }
        return nil
    }

    var statusText: String {
        switch state {
        case .queued:
            return "Queued"
        case .downloading:
            if totalBytes > 0 {
                return "\(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
            } else if receivedBytes > 0 {
                return ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
            }
            return "lc.download.downloading".loc
        case .paused:
            return "Paused"
        case .installing(let phase):
            return phase
        case .completed:
            return "Installed"
        case .failed(let message):
            return message
        }
    }
}

enum LCTweakPackageInstaller {
    static func copyOrMovePayload(from sourceURL: URL, into targetFolder: URL, move: Bool) throws {
        let fm = FileManager.default
        let destinationURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        if move {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fm.copyItem(at: sourceURL, to: destinationURL)
        }
        if destinationURL.pathExtension.lowercased() == "dylib" {
            LCParseMachO((destinationURL.path as NSString).utf8String, false) { path, header, _, _ in
                LCPatchAddRPath(path, header)
            }
        }
    }

    static func extractArchiveAndInstallPayloads(from archiveURL: URL, ext: String, workDir: URL, into baseURL: URL, copiedCount: inout Int) async throws {
        let fm = FileManager.default
        let outerExtractDir = workDir.appendingPathComponent("outer", isDirectory: true)
        try fm.createDirectory(at: outerExtractDir, withIntermediateDirectories: true)

        let outerCode = await Task.detached(priority: .userInitiated) {
            extract(archiveURL.path, outerExtractDir.path, nil)
        }.value
        guard outerCode == 0 else {
            throw "Failed to extract \(archiveURL.lastPathComponent) (code \(outerCode))."
        }

        var searchRoot = outerExtractDir
        if ext == "deb" {
            let outerItems = (try? fm.contentsOfDirectory(at: outerExtractDir, includingPropertiesForKeys: nil)) ?? []
            if let dataTar = outerItems.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) {
                let innerDir = workDir.appendingPathComponent("inner", isDirectory: true)
                try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
                let innerCode = await Task.detached(priority: .userInitiated) {
                    extract(dataTar.path, innerDir.path, nil)
                }.value
                guard innerCode == 0 else {
                    throw "Failed to unpack data archive inside \(archiveURL.lastPathComponent) (code \(innerCode))."
                }
                searchRoot = innerDir
            }
        }

        guard let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var payloadURLs: [URL] = []
        while let itemURL = enumerator.nextObject() as? URL {
            let itemExt = itemURL.pathExtension.lowercased()
            if itemExt == "framework" {
                enumerator.skipDescendants()
                payloadURLs.append(itemURL)
            } else if itemExt == "dylib" {
                payloadURLs.append(itemURL)
            }
        }

        guard !payloadURLs.isEmpty else {
            throw "No .dylib or .framework found inside \(archiveURL.lastPathComponent)."
        }

        for payloadURL in payloadURLs {
            try copyOrMovePayload(from: payloadURL, into: baseURL, move: false)
            copiedCount += 1
        }
    }

    @MainActor
    static func installDownloadedFile(at localFileURL: URL, originalFileName: String, destinationFolder: URL) async throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("LCTweakDL-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let ext = URL(fileURLWithPath: originalFileName).pathExtension.lowercased()
        let namedFileURL = stagingDir.appendingPathComponent(originalFileName)
        try fm.copyItem(at: localFileURL, to: namedFileURL)

        var count = 0
        if ext == "zip" || ext == "deb" {
            let workDir = stagingDir.appendingPathComponent("work", isDirectory: true)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await extractArchiveAndInstallPayloads(from: namedFileURL, ext: ext, workDir: workDir, into: destinationFolder, copiedCount: &count)
        } else if ext == "dylib" || ext == "framework" {
            try copyOrMovePayload(from: namedFileURL, into: destinationFolder, move: true)
            count = 1
        } else {
            throw "Unsupported tweak file type: \(originalFileName)"
        }

        if count > 0 {
            try? await LCUtils.signTweaks(tweakFolderUrl: destinationFolder, force: false) { _ in }
            NotificationCenter.default.post(name: Notification.Name("LC.TweakManagementDidChange"), object: nil)
        }
    }
}

public struct LCAppInstallOutcome: Sendable {
    let installedApp: LCAppModel?
    let warningMessage: String?
}

@MainActor
private final class InstallProgressRelay {
    let handler: (@MainActor (Double, String) -> Void)?
    init(_ handler: (@MainActor (Double, String) -> Void)?) {
        self.handler = handler
    }
}

@MainActor
final class LCAppInstaller {
    private static var installLockQueue: [CheckedContinuation<Void, Never>] = []
    private static var isInstallingSerial = false

    private static func acquireSerialInstallSlot() async {
        if !isInstallingSerial {
            isInstallingSerial = true
            return
        }
        await withCheckedContinuation { continuation in
            installLockQueue.append(continuation)
        }
    }

    private static func releaseSerialInstallSlot() {
        if !installLockQueue.isEmpty {
            let next = installLockQueue.removeFirst()
            next.resume()
        } else {
            isInstallingSerial = false
        }
    }

    static func installIPA(
        at ipaFileURL: URL,
        sourceURL: String? = nil,
        sourceVersion: String? = nil,
        sourceBuildVersion: String? = nil,
        preferredTargetRelativePath: String? = nil,
        ignoreUpdateKeyAfterInstall: String? = nil,
        chooseAppToReplace: (@MainActor ([AppReplaceOption]) async -> AppReplaceOption?)? = nil,
        progressHandler: (@MainActor (Double, String) -> Void)? = nil
    ) async throws -> LCAppInstallOutcome {
        await acquireSerialInstallSlot()
        defer { releaseSerialInstallSlot() }

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "LCAppInstall")
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("LCInstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 75)

        let relay = InstallProgressRelay(progressHandler)
        let observer = installProgress.observe(\.fractionCompleted) { p, _ in
            let fraction = p.fractionCompleted
            Task { @MainActor in
                let label = fraction < 0.75 ? "Unpacking…" : "Signing…"
                relay.handler?(fraction, label)
            }
        }
        defer { observer.invalidate() }

        progressHandler?(0.02, "Unpacking…")
        let ipaPath = ipaFileURL.path
        let destPath = stagingDir.path
        let extractCode = await Task.detached(priority: .userInitiated) {
            extract(ipaPath, destPath, decompressProgress)
        }.value
        guard extractCode == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadPath = stagingDir.appendingPathComponent("Payload", isDirectory: true)
        guard fm.fileExists(atPath: payloadPath.path) else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        guard let appBundleName = payloadContents.first(where: { $0.hasSuffix(".app") }) else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let stagedBundleURL = payloadPath.appendingPathComponent(appBundleName, isDirectory: true)
        guard let stagedAppInfo = LCAppInfo(bundlePath: stagedBundleURL.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        let bundleId = stagedAppInfo.bundleIdentifier() ?? "Unknown"
        let sharedModel = DataManager.shared.model

        let allInstalled = sharedModel.apps + sharedModel.hiddenApps
        var appRelativePath = "\(bundleId.sanitizeNonACSII()).app"
        var appToReplace: LCAppModel? = nil
        var isReplace = false

        if let preferredTargetRelativePath,
           let matchedApp = (allInstalled.first { $0.appInfo.relativeBundlePath == preferredTargetRelativePath } ?? allInstalled.first { $0.appInfo.bundleIdentifier() == bundleId }) {
            if matchedApp.uiIsHidden && !sharedModel.isHiddenAppUnlocked {
                guard try await LCUtils.authenticateUser() else {
                    return LCAppInstallOutcome(installedApp: nil, warningMessage: nil)
                }
            }
            appToReplace = matchedApp
            appRelativePath = matchedApp.appInfo.relativeBundlePath ?? appRelativePath
            isReplace = true
        } else {
            var sameBundleIdApps = sharedModel.apps.filter { $0.appInfo.bundleIdentifier() == bundleId }
            if sameBundleIdApps.isEmpty {
                sameBundleIdApps = sharedModel.hiddenApps.filter { $0.appInfo.bundleIdentifier() == bundleId }
                if !sameBundleIdApps.isEmpty && !sharedModel.isHiddenAppUnlocked {
                    guard try await LCUtils.authenticateUser() else {
                        return LCAppInstallOutcome(installedApp: nil, warningMessage: nil)
                    }
                }
            }

            if fm.fileExists(atPath: LCPath.bundlePath.appendingPathComponent(appRelativePath).path) || !sameBundleIdApps.isEmpty {
                let uniqueNewName = "\(bundleId.sanitizeNonACSII())_\(Int(CFAbsoluteTimeGetCurrent())).app"
                if let chooseAppToReplace {
                    var options = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: uniqueNewName, appToReplace: nil)]
                    for existing in sameBundleIdApps {
                        options.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: existing.appInfo.relativeBundlePath ?? uniqueNewName, appToReplace: existing))
                    }
                    guard let chosen = await chooseAppToReplace(options) else {
                        return LCAppInstallOutcome(installedApp: nil, warningMessage: nil)
                    }
                    appToReplace = chosen.appToReplace
                    appRelativePath = chosen.nameOfFolderToInstall
                    isReplace = chosen.isReplace
                } else if let existing = sameBundleIdApps.first {
                    appToReplace = existing
                    appRelativePath = existing.appInfo.relativeBundlePath ?? uniqueNewName
                    isReplace = true
                } else {
                    appRelativePath = uniqueNewName
                }
            }
        }

        // Abort safely before modifying files if any container of the app to replace is actively running.
        if isReplace, let appToReplace {
            if sharedModel.activeDebugApp == appToReplace {
                throw "Cannot replace \(appToReplace.displayName) while Debug Studio is open. Close Debug Studio and retry."
            }
            for container in appToReplace.appInfo.containers {
                if MultitaskManager.isUsing(container: container.folderName) {
                    throw "Cannot replace \(appToReplace.displayName) while it is running in Multitask. Close the app and retry."
                }
                if LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) != nil {
                    throw "Cannot replace \(appToReplace.displayName) while it is running in another LiveContainer."
                }
            }
        }

        // Preserve user configuration BEFORE patching/signing so dontSign, dontInjectTweakLoader, etc. are honored.
        if let appToReplace {
            LCAppModel.copy(fromApp: appToReplace, toAppInfo: stagedAppInfo)
        } else {
            stagedAppInfo.spoofSDKVersion = true
            if LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                stagedAppInfo.dontSign = true
            }
        }

        if let sourceURL, !sourceURL.isEmpty {
            stagedAppInfo.sourceURL = sourceURL
        }
        if sourceURL != nil || sourceVersion != nil {
            stagedAppInfo.installedSourceVersion = sourceVersion ?? stagedAppInfo.shortVersion() ?? stagedAppInfo.version()
            stagedAppInfo.installedSourceBuildVersion = sourceBuildVersion ?? stagedAppInfo.buildVersion()
            stagedAppInfo.ignoredUpdateVersion = ignoreUpdateKeyAfterInstall
        }
        stagedAppInfo.installationDate = Date.now
        stagedAppInfo.save()

        progressHandler?(0.78, "Signing…")
        let (signSuccess, signError) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            stagedAppInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                continuation.resume(returning: (success, error))
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress, withPendingUnitCount: 25)
            }, forceSign: false)
        }

        var warningMessage: String? = nil
        if let signError {
            if signSuccess {
                warningMessage = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                warningMessage = signError.loc
            }
        }

        progressHandler?(0.96, "Finalizing…")
        let isSharedTarget = appToReplace?.uiIsShared ?? false
        let baseFolder = isSharedTarget ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        try fm.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        let destinationURL = baseFolder.appendingPathComponent(appRelativePath, isDirectory: true)

        if isReplace, fm.fileExists(atPath: destinationURL.path) {
            let existingUserDataURL = destinationURL.appendingPathComponent("LCUserData", isDirectory: true)
            if fm.fileExists(atPath: existingUserDataURL.path) {
                let stagedUserDataURL = stagedBundleURL.appendingPathComponent("LCUserData", isDirectory: true)
                if !fm.fileExists(atPath: stagedUserDataURL.path) {
                    try fm.copyItem(at: existingUserDataURL, to: stagedUserDataURL)
                } else {
                    let existingItems = (try? fm.contentsOfDirectory(at: existingUserDataURL, includingPropertiesForKeys: nil)) ?? []
                    for item in existingItems {
                        let target = stagedUserDataURL.appendingPathComponent(item.lastPathComponent)
                        if !fm.fileExists(atPath: target.path) {
                            try? fm.copyItem(at: item, to: target)
                        }
                    }
                }
            }
            _ = try fm.replaceItemAt(destinationURL, withItemAt: stagedBundleURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: stagedBundleURL, to: destinationURL)
        }

        guard let finalNewApp = LCAppInfo(bundlePath: destinationURL.path) else {
            throw "lc.appList.appInfoInitError".loc
        }
        finalNewApp.relativeBundlePath = appRelativePath
        finalNewApp.isShared = isSharedTarget
        finalNewApp.clearIconCache()

        if !isReplace && !finalNewApp.is32bit,
           let bundleId = finalNewApp.bundleIdentifier(), !bundleId.isEmpty {
            let folderName = UUID().uuidString
            let initialContainer = LCContainer.makeNewContainer(
                folderName: folderName,
                name: folderName,
                isShared: isSharedTarget
            )
            initialContainer.makeLCContainerInfoPlist(
                appIdentifier: bundleId,
                keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
            )
            finalNewApp.containers = [initialContainer]
            finalNewApp.dataUUID = folderName
            finalNewApp.save()
        }

        let delegateToAssign = appToReplace?.delegate ?? sharedModel.appModelDelegate
        let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: delegateToAssign)

        if let appToReplace {
            if appToReplace.uiIsHidden {
                sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                sharedModel.hiddenApps.append(newAppModel)
            } else {
                sharedModel.apps.removeAll { $0 == appToReplace }
                sharedModel.apps.append(newAppModel)
            }
            sharedModel.arm32EmuApps.removeAll { $0 == appToReplace }
            if finalNewApp.is32bitEmulator {
                sharedModel.arm32EmuApps.append(newAppModel)
            }
        } else {
            sharedModel.apps.append(newAppModel)
            if finalNewApp.is32bitEmulator {
                sharedModel.arm32EmuApps.append(newAppModel)
            }
        }

        if sharedModel.multiLCStatus != 2 {
            var schemes = Set<String>()
            for app in sharedModel.apps {
                if let appSchemes = app.appInfo.urlSchemes() as? [String] {
                    schemes.formUnion(appSchemes)
                }
            }
            UserDefaults.lcShared().set(Array(schemes), forKey: "LCGuestURLSchemes")
        }

        AltStoreSourcesViewModel.shared.recomputeAvailableUpdates()
        progressHandler?(1.0, "Installed")

        return LCAppInstallOutcome(installedApp: newAppModel, warningMessage: warningMessage)
    }
}

public final class LCDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = LCDownloadManager()
    private static let sessionIdentifier = "com.kdt.livecontainer.downloads"

    @MainActor @Published public private(set) var items: [LCDownloadTaskItem] = []
    @MainActor @Published public var isQueueSheetPresented = false
    @MainActor @Published public var isPillDismissed = false
    @MainActor @Published public var alertMessage: String? = nil

    private let lock = NSLock()
    private var backgroundSession: URLSession!
    @MainActor private var bgCompletionHandler: (() -> Void)?
    private var taskIdToItemId: [Int: UUID] = [:]
    private var resumeDataByItemId: [UUID: Data] = [:]
    private var lastProgressPublish: [UUID: CFAbsoluteTime] = [:]

    private static var storeDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("LCDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var metadataFileURL: URL {
        storeDirectory.appendingPathComponent("tasks.json")
    }

    private override init() {
        super.init()

        var preloadedItems: [LCDownloadTaskItem] = []
        if let data = try? Data(contentsOf: Self.metadataFileURL),
           let decoded = try? JSONDecoder().decode([LCDownloadTaskItem].self, from: data) {
            preloadedItems = decoded
            lock.withLock {
                for item in decoded {
                    if let tid = item.taskIdentifier {
                        taskIdToItemId[tid] = item.id
                    }
                }
            }
        }

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        if let appGroupID = LCSharedUtils.appGroupID(), !appGroupID.isEmpty, appGroupID != "Unknown" {
            config.sharedContainerIdentifier = appGroupID
        }
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "com.kdt.livecontainer.downloads.delegate"
        self.backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)

        let initialItems = preloadedItems
        Task { @MainActor in
            self.loadPersistedQueueAndReconnect(preloadedItems: initialItems)
        }
    }

    @MainActor
    public func handleEventsForBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        bgCompletionHandler = completionHandler
    }

    @MainActor
    public var activeCount: Int {
        items.filter { $0.state.isActive }.count
    }

    @MainActor
    public var hasUnfinishedOrRecentItems: Bool {
        !items.isEmpty
    }

    @MainActor
    public func activeTask(forTargetId targetId: String) -> LCDownloadTaskItem? {
        items.first { item in
            guard item.state.isActive else { return false }
            return item.targetBundleId == targetId
        }
    }

    @MainActor
    public func activeTask(forBundleId bundleId: String) -> LCDownloadTaskItem? {
        items.first { item in
            guard item.state.isActive else { return false }
            return item.targetBundleId == bundleId
        }
    }

    @MainActor
    public func activeTask(forURL url: URL) -> LCDownloadTaskItem? {
        items.first { $0.url == url && ($0.state.isActive || $0.state == .paused) }
    }

    @MainActor
    @discardableResult
    public func enqueueAppDownload(
        url: URL,
        displayName: String,
        iconURL: URL? = nil,
        sourceURL: String? = nil,
        version: String? = nil,
        buildVersion: String? = nil,
        targetAppBundleId: String? = nil,
        targetRelativePath: String? = nil,
        ignoreUpdateKeyAfterInstall: String? = nil
    ) -> LCDownloadTaskItem {
        if let existing = items.first(where: { $0.url == url && $0.state.isActive }) {
            isPillDismissed = false
            return existing
        }

        let targetId = targetRelativePath ?? targetAppBundleId
        // Prevent two different versions of the exact same target app from racing to overwrite each other.
        if let targetId, !targetId.isEmpty {
            let conflicting = items.filter {
                $0.targetBundleId == targetId && $0.url != url && $0.state.isActive
            }
            for item in conflicting {
                if case .installing = item.state {
                    // Installation is already writing to disk; keep the in-flight install alive.
                    isPillDismissed = false
                    return item
                }
                cancel(item)
            }
        }

        let item = LCDownloadTaskItem(
            id: UUID(),
            url: url,
            displayName: displayName.isEmpty ? url.lastPathComponent : displayName,
            iconURL: iconURL,
            kind: .ipa(
                sourceURL: sourceURL,
                version: version,
                buildVersion: buildVersion,
                targetAppBundleId: targetId,
                ignoreUpdateKeyAfterInstall: ignoreUpdateKeyAfterInstall
            ),
            state: .downloading,
            progress: 0,
            receivedBytes: 0,
            totalBytes: 0,
            taskIdentifier: nil,
            createdAt: Date()
        )
        return startTask(for: item)
    }

    @MainActor
    @discardableResult
    public func enqueueTweakDownload(url: URL, displayName: String? = nil, destinationFolder: URL) -> LCDownloadTaskItem {
        if let existing = items.first(where: { $0.url == url && $0.state.isActive }) {
            isPillDismissed = false
            return existing
        }
        let item = LCDownloadTaskItem(
            id: UUID(),
            url: url,
            displayName: (displayName?.isEmpty == false ? displayName! : url.lastPathComponent),
            iconURL: nil,
            kind: .tweak(destinationFolderPath: destinationFolder.path),
            state: .downloading,
            progress: 0,
            receivedBytes: 0,
            totalBytes: 0,
            taskIdentifier: nil,
            createdAt: Date()
        )
        return startTask(for: item)
    }

    @MainActor
    private func startTask(for item: LCDownloadTaskItem) -> LCDownloadTaskItem {
        var newItem = item
        let task: URLSessionDownloadTask
        if let resumeData = lock.withLock({ resumeDataByItemId.removeValue(forKey: item.id) }) {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
        } else {
            task = backgroundSession.downloadTask(with: item.url)
        }
        newItem.taskIdentifier = task.taskIdentifier
        newItem.state = .downloading

        lock.withLock {
            taskIdToItemId[task.taskIdentifier] = newItem.id
        }

        if let index = items.firstIndex(where: { $0.id == newItem.id }) {
            items[index] = newItem
        } else {
            items.insert(newItem, at: 0)
        }
        isPillDismissed = false
        persistQueue()
        task.resume()
        return newItem
    }

    @MainActor
    public func pause(_ item: LCDownloadTaskItem) {
        guard let taskId = item.taskIdentifier else { return }
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self, let dlTask = tasks.first(where: { $0.taskIdentifier == taskId }) as? URLSessionDownloadTask else {
                return
            }
            dlTask.cancel { resumeData in
                Task { @MainActor in
                    if let resumeData {
                        self.lock.withLock {
                            self.resumeDataByItemId[item.id] = resumeData
                        }
                    }
                    if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[index].state = .paused
                        self.items[index].taskIdentifier = nil
                        self.persistQueue()
                    }
                }
            }
        }
    }

    @MainActor
    public func resume(_ item: LCDownloadTaskItem) {
        var copy = item
        copy.state = .downloading
        _ = startTask(for: copy)
    }

    @MainActor
    public func retry(_ item: LCDownloadTaskItem) {
        var copy = item
        copy.progress = 0
        copy.receivedBytes = 0
        copy.state = .downloading
        _ = startTask(for: copy)
    }

    @MainActor
    public func cancel(_ item: LCDownloadTaskItem) {
        if let taskId = item.taskIdentifier {
            backgroundSession.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskId })?.cancel()
            }
            lock.withLock {
                _ = taskIdToItemId.removeValue(forKey: taskId)
            }
        }
        lock.withLock {
            _ = resumeDataByItemId.removeValue(forKey: item.id)
        }
        items.removeAll { $0.id == item.id }
        persistQueue()
    }

    @MainActor
    public func clearCompleted() {
        items.removeAll { $0.state.isFinished }
        persistQueue()
    }

    @MainActor
    private func loadPersistedQueueAndReconnect(preloadedItems: [LCDownloadTaskItem]) {
        self.items = preloadedItems

        backgroundSession.getAllTasks { [weak self] activeTasks in
            guard let self else { return }
            let taskStatesById = Dictionary(uniqueKeysWithValues: activeTasks.map { ($0.taskIdentifier, $0.state) })
            Task { @MainActor in
                for index in self.items.indices {
                    if let tid = self.items[index].taskIdentifier, let runningState = taskStatesById[tid] {
                        self.lock.withLock {
                            self.taskIdToItemId[tid] = self.items[index].id
                        }
                        if runningState == .running {
                            self.items[index].state = .downloading
                        } else if runningState == .suspended {
                            self.items[index].state = .paused
                        }
                    } else if case .downloading = self.items[index].state {
                        self.items[index].state = .failed("Download interrupted before completion.")
                    } else if case .installing = self.items[index].state {
                        self.items[index].state = .failed("Installation interrupted before completion.")
                    }
                }
                self.persistQueue()
            }
        }
    }

    @MainActor
    private func persistQueue() {
        let itemsToSave = Array(items.prefix(40))
        if let data = try? JSONEncoder().encode(itemsToSave) {
            try? data.write(to: Self.metadataFileURL, options: .atomic)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let itemId: UUID? = lock.withLock {
            guard let id = taskIdToItemId[downloadTask.taskIdentifier] else { return nil }
            let prev = lastProgressPublish[id] ?? 0
            if now - prev < 0.1 && totalBytesWritten != totalBytesExpectedToWrite {
                return nil
            }
            lastProgressPublish[id] = now
            return id
        }
        guard let itemId else { return }
        let ratio = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in
            if let index = self.items.firstIndex(where: { $0.id == itemId }) {
                self.items[index].receivedBytes = totalBytesWritten
                self.items[index].totalBytes = totalBytesExpectedToWrite
                self.items[index].progress = min(max(ratio * 0.7, 0), 0.7)
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let itemId = lock.withLock { taskIdToItemId[taskId] }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let errMsg = "HTTP \(httpResponse.statusCode)"
            Task { @MainActor in
                self.markDownloadFailed(itemId: itemId, taskId: taskId, message: errMsg)
            }
            return
        }

        // Move synchronously before returning because URLSession deletes `location` immediately on return.
        let fileId = itemId?.uuidString ?? UUID().uuidString
        let savedURL = Self.storeDirectory.appendingPathComponent("\(fileId).download")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: savedURL.path) {
                try fm.removeItem(at: savedURL)
            }
            try fm.moveItem(at: location, to: savedURL)
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                self.markDownloadFailed(itemId: itemId, taskId: taskId, message: msg)
            }
            return
        }

        let suggested = downloadTask.response?.suggestedFilename
        let origExt = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? ""
        let suggestedExt = suggested.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let validExts: Set<String> = ["dylib", "framework", "zip", "deb", "ipa", "tipa"]
        let resolvedName: String
        if let suggested, validExts.contains(suggestedExt) {
            resolvedName = suggested
        } else if !origExt.isEmpty, let lastComp = downloadTask.originalRequest?.url?.lastPathComponent, !lastComp.isEmpty {
            resolvedName = lastComp
        } else {
            resolvedName = suggested ?? "download.ipa"
        }
        Task { @MainActor in
            await self.handleDownloadedFile(itemId: itemId, taskId: taskId, localFileURL: savedURL, suggestedFileName: resolvedName)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let taskId = task.taskIdentifier
        let itemId = lock.withLock { taskIdToItemId.removeValue(forKey: taskId) }

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let itemId {
            lock.withLock {
                resumeDataByItemId[itemId] = resumeData
            }
        }
        let msg = error.localizedDescription
        Task { @MainActor in
            self.markDownloadFailed(itemId: itemId, taskId: taskId, message: msg)
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.bgCompletionHandler
            self.bgCompletionHandler = nil
            handler?()
        }
    }

    @MainActor
    private func markDownloadFailed(itemId: UUID?, taskId: Int, message: String) {
        lock.withLock {
            _ = taskIdToItemId.removeValue(forKey: taskId)
        }
        let idx = itemId.flatMap { id in items.firstIndex { $0.id == id } }
            ?? items.firstIndex { $0.taskIdentifier == taskId }
        guard let idx else { return }
        if case .paused = items[idx].state { return }
        items[idx].state = .failed(message)
        items[idx].taskIdentifier = nil
        persistQueue()
    }

    @MainActor
    private func handleDownloadedFile(itemId: UUID?, taskId: Int, localFileURL: URL, suggestedFileName: String) async {
        defer { try? FileManager.default.removeItem(at: localFileURL) }
        lock.withLock {
            _ = taskIdToItemId.removeValue(forKey: taskId)
        }
        guard let idx = (itemId.flatMap { id in items.firstIndex { $0.id == id } } ?? items.firstIndex { $0.taskIdentifier == taskId }) else {
            return
        }
        let item = items[idx]
        items[idx].taskIdentifier = nil
        items[idx].state = .installing("Unpacking…")
        items[idx].progress = 0.72
        persistQueue()

        do {
            switch item.kind {
            case let .ipa(sourceURL, version, buildVersion, targetAppId, ignoreUpdateKeyAfterInstall):
                let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
                let targetRelPath = allApps.first {
                    $0.appInfo.relativeBundlePath == targetAppId || $0.appInfo.bundleIdentifier() == targetAppId
                }?.appInfo.relativeBundlePath ?? targetAppId

                let outcome = try await LCAppInstaller.installIPA(
                    at: localFileURL,
                    sourceURL: sourceURL,
                    sourceVersion: version,
                    sourceBuildVersion: buildVersion,
                    preferredTargetRelativePath: targetRelPath,
                    ignoreUpdateKeyAfterInstall: ignoreUpdateKeyAfterInstall,
                    progressHandler: { [weak self] fraction, label in
                        guard let self, let liveIdx = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                        self.items[liveIdx].progress = 0.70 + (fraction * 0.30)
                        self.items[liveIdx].state = .installing(label)
                    }
                )
                if let liveIdx = items.firstIndex(where: { $0.id == item.id }) {
                    items[liveIdx].progress = 1.0
                    items[liveIdx].state = .completed
                    persistQueue()
                }
                if let warning = outcome.warningMessage {
                    alertMessage = warning
                }
            case let .tweak(destinationFolderPath):
                if let liveIdx = items.firstIndex(where: { $0.id == item.id }) {
                    items[liveIdx].state = .installing("Installing tweak…")
                    items[liveIdx].progress = 0.85
                }
                try await LCTweakPackageInstaller.installDownloadedFile(
                    at: localFileURL,
                    originalFileName: suggestedFileName,
                    destinationFolder: URL(fileURLWithPath: destinationFolderPath, isDirectory: true)
                )
                if let liveIdx = items.firstIndex(where: { $0.id == item.id }) {
                    items[liveIdx].progress = 1.0
                    items[liveIdx].state = .completed
                    persistQueue()
                }
            }
        } catch {
            if let liveIdx = items.firstIndex(where: { $0.id == item.id }) {
                items[liveIdx].state = .failed(error.localizedDescription)
                persistQueue()
            }
        }
    }
}

public struct LCDownloadPillBar: View {
    @EnvironmentObject private var downloadManager: LCDownloadManager

    private var summaryItem: LCDownloadTaskItem? {
        downloadManager.items.first(where: { $0.state.isActive }) ?? downloadManager.items.first
    }

    public var body: some View {
        if !downloadManager.isPillDismissed, let item = summaryItem {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(.secondary.opacity(0.25), lineWidth: 3)
                        if case .failed = item.state {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if case .completed = item.state {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Circle()
                                .trim(from: 0, to: max(item.progress, 0.05))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "arrow.down")
                                .font(.caption2.bold())
                        }
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if downloadManager.items.count > 1 {
                                Text("+\(downloadManager.items.count - 1)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.2), in: .capsule)
                            }
                        }
                        Text(item.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if item.state.isActive {
                        Button {
                            downloadManager.cancel(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            downloadManager.clearCompleted()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .padding(6)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Capsule())
                .onTapGesture {
                    downloadManager.isQueueSheetPresented = true
                }
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

public struct LCDownloadQueueSheet: View {
    @EnvironmentObject private var downloadManager: LCDownloadManager
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List {
                if downloadManager.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("App and tweak downloads run in the background while you continue browsing.")
                    )
                } else {
                    ForEach(downloadManager.items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(item.statusText)
                                    .font(.caption)
                                    .foregroundStyle(isFailed(item) ? .red : .secondary)
                                    .lineLimit(2)
                                if item.state.isActive || item.state == .paused {
                                    ProgressView(value: min(max(item.progress, 0), 1))
                                }
                            }
                            Spacer()
                            actionButtons(for: item)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if downloadManager.items.contains(where: { $0.state.isFinished }) {
                        Button("Clear Finished") {
                            downloadManager.clearCompleted()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isFailed(_ item: LCDownloadTaskItem) -> Bool {
        if case .failed = item.state { return true }
        return false
    }

    @ViewBuilder
    private func actionButtons(for item: LCDownloadTaskItem) -> some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 6) {
                Button {
                    downloadManager.pause(item)
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.glass)
                Button(role: .destructive) {
                    downloadManager.cancel(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
            }
        case .paused:
            HStack(spacing: 6) {
                Button {
                    downloadManager.resume(item)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.glassProminent)
                Button(role: .destructive) {
                    downloadManager.cancel(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
            }
        case .failed:
            Button("Retry") {
                downloadManager.retry(item)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .queued, .installing:
            ProgressView()
                .controlSize(.small)
        }
    }
}

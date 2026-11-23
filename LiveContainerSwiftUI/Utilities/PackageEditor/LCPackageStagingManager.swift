//
//  LCPackageStagingManager.swift
//  LiveContainerSwiftUI
//

import Foundation
import os
import UIKit

/// Manages isolated temporary staging directories (`tmp/LCStaging/`) and inspects
/// staged `.app` bundles off the main actor without ever mutating installed apps.
final class LCPackageStagingSession: Identifiable, @unchecked Sendable {
    let id = UUID()
    let mode: LCPackageEditorMode
    let stagingRootURL: URL
    let stagedAppURL: URL
    let importedDataURL: URL?
    let appTweakFolder: String?

    private let lock = OSAllocatedUnfairLock(initialState: CleanupState())

    private struct CleanupState {
        var didCleanStaging = false
        var sourceIPAURLToDelete: URL?
        var shouldDeleteSourceIPAOnCleanup = true
    }

    init(
        mode: LCPackageEditorMode,
        stagingRootURL: URL,
        stagedAppURL: URL,
        importedDataURL: URL? = nil,
        sourceIPAURLToDelete: URL? = nil,
        appTweakFolder: String? = nil
    ) {
        self.mode = mode
        self.stagingRootURL = stagingRootURL
        self.stagedAppURL = stagedAppURL
        self.importedDataURL = importedDataURL
        self.appTweakFolder = appTweakFolder
        self.lock.withLock { state in
            state.sourceIPAURLToDelete = sourceIPAURLToDelete
        }
    }

    func markInstallSucceeded() {
        cleanup(deleteSourceIPA: true)
    }

    func cleanup(deleteSourceIPA: Bool = true) {
        let urlsToRemove: (URL?, URL?) = lock.withLock { state in
            let staging: URL? = state.didCleanStaging ? nil : stagingRootURL
            state.didCleanStaging = true
            let source: URL? = (deleteSourceIPA && state.shouldDeleteSourceIPAOnCleanup) ? state.sourceIPAURLToDelete : nil
            if source != nil {
                state.sourceIPAURLToDelete = nil
            }
            return (staging, source)
        }

        let fm = FileManager.default
        if let stagingURL = urlsToRemove.0 {
            LCPackageStagingManager.unregisterActiveSession(stagingURL.lastPathComponent)
            if fm.fileExists(atPath: stagingURL.path) {
                try? fm.removeItem(at: stagingURL)
            }
        }
        if let sourceURL = urlsToRemove.1, fm.fileExists(atPath: sourceURL.path) {
            try? fm.removeItem(at: sourceURL)
        }
    }

    deinit {
        cleanup(deleteSourceIPA: true)
    }
}

enum LCPackageStagingManager {
    private nonisolated static let stagingFolderName = "LCStaging"
    private nonisolated static let activeSessionNames = OSAllocatedUnfairLock(initialState: Set<String>())

    fileprivate nonisolated static func unregisterActiveSession(_ folderName: String) {
        activeSessionNames.withLock { _ = $0.remove(folderName) }
    }

    nonisolated static func stagingBaseDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(stagingFolderName, isDirectory: true)
    }

    nonisolated static func cleanupStaleStagingDirectories(fileManager: FileManager = .default) {
        let baseURL = stagingBaseDirectoryURL(fileManager: fileManager)
        guard let children = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        let protectedNames = activeSessionNames.withLock { $0 }
        for childURL in children where !protectedNames.contains(childURL.lastPathComponent) {
            try? fileManager.removeItem(at: childURL)
        }
    }

    nonisolated static func makeSessionDirectory(fileManager: FileManager = .default) throws -> URL {
        let folderName = "Session-\(UUID().uuidString)"
        let sessionDir = stagingBaseDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(folderName, isDirectory: true)
        activeSessionNames.withLock { _ = $0.insert(folderName) }
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir
    }

    nonisolated static func sanitizedStem(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App" : cleaned
    }

    /// Copies an installed LiveContainer `.app` into an isolated temporary session directory
    /// and unpatches LiveContainer's `TweakLoader` / `MH_DYLIB` modifications on the copy.
    static func stageInstalledApp(
        bundlePath: String,
        displayName: String?,
        tweakFolder: String?
    ) async throws -> LCPackageStagingSession {
        try await lcRunOffMain {
            let fm = FileManager.default
            let sourceURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            guard fm.fileExists(atPath: sourceURL.path) else {
                throw "Unable to locate installed app bundle."
            }

            let sessionDir = try makeSessionDirectory(fileManager: fm)
            do {
                let rawExecName = readExecutableName(at: sourceURL) ?? displayName ?? "App"
                let cleanStem = sanitizedStem(rawExecName)
                let stagedAppURL = sessionDir.appendingPathComponent("\(cleanStem).app", isDirectory: true)
                try fm.copyItem(at: sourceURL, to: stagedAppURL)
                try lcSanitizeStagedAppBundle(at: stagedAppURL, unpatchExecutables: true, fileManager: fm)

                return LCPackageStagingSession(
                    mode: .standaloneExport,
                    stagingRootURL: sessionDir,
                    stagedAppURL: stagedAppURL,
                    appTweakFolder: tweakFolder
                )
            } catch {
                try? fm.removeItem(at: sessionDir)
                throw error
            }
        }
    }

    /// Inspects a staged `.app` bundle off the main actor and builds a complete snapshot of its
    /// Info.plist metadata, executable slices, frameworks, linked dylibs, plugins, and Watch apps.
    static func inspectStagedBundle(
        at stagedAppURL: URL,
        mode: LCPackageEditorMode
    ) async throws -> LCPackageBundleSnapshot {
        try await lcRunOffMain {
            let fm = FileManager.default
            let infoPlistURL = stagedAppURL.appendingPathComponent("Info.plist")
            guard let infoData = try? Data(contentsOf: infoPlistURL),
                  let infoDict = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
                throw "Unable to read Info.plist inside staged app bundle."
            }

            let execName = (infoDict["CFBundleExecutable"] as? String)
                ?? stagedAppURL.deletingPathExtension().lastPathComponent
            let bundleId = (infoDict["CFBundleIdentifier"] as? String) ?? ""
            let bundleName = (infoDict["CFBundleName"] as? String) ?? execName
            let displayName = (infoDict["CFBundleDisplayName"] as? String) ?? bundleName
            let shortVersion = (infoDict["CFBundleShortVersionString"] as? String) ?? "1.0"
            let buildVersion = (infoDict["CFBundleVersion"] as? String) ?? "1"
            let minOS = (infoDict["MinimumOSVersion"] as? String) ?? ""
            let hasSupportedDevices = infoDict["UISupportedDevices"] != nil
            let hasFileSharing = ((infoDict["UIFileSharingEnabled"] as? NSNumber)?.boolValue ?? false) &&
                ((infoDict["LSSupportsOpeningDocumentsInPlace"] as? NSNumber)?.boolValue ?? false)
            let hasURLSchemes = !(infoDict["CFBundleURLTypes"] as? [[String: Any]] ?? []).isEmpty

            let metadata = LCPackageMetadataDraft(
                originalDisplayName: displayName,
                originalBundleName: bundleName,
                originalBundleIdentifier: bundleId,
                originalShortVersion: shortVersion,
                originalBuildVersion: buildVersion,
                originalMinimumOSVersion: minOS,
                displayName: displayName,
                bundleName: bundleName,
                bundleIdentifier: bundleId,
                shortVersion: shortVersion,
                buildVersion: buildVersion,
                minimumOSVersion: minOS,
                updateExtensionBundleIds: true,
                updateLocalizedNames: true,
                removeSupportedDevices: mode == .standaloneExport && hasSupportedDevices,
                enableFileSharing: hasFileSharing,
                removeURLSchemes: false,
                hasSupportedDevicesKey: hasSupportedDevices,
                hasFileSharingEnabled: hasFileSharing,
                hasURLSchemes: hasURLSchemes
            )

            let execURL = LCBoundedFileReader.resolveMachOExecutableURL(for: stagedAppURL)
            var overview: LCMachOOverviewResult? = nil
            var architectures: [String] = []
            if let execURL, let ctx = try? LCMachOParser.parseSliceContext(at: execURL) {
                overview = ctx.overview
                architectures = ctx.overview.slices.map(\.architectureName)
            }

            let iconData: Data? = {
                guard let tempAppInfo = LCAppInfo(bundlePath: stagedAppURL.path),
                      let icon = tempAppInfo.iconIsDarkIcon(false) else {
                    return nil
                }
                return icon.pngData()
            }()

            let totalBundleSize = directoryAllocatedSize(at: stagedAppURL, fileManager: fm)

            // Collect embedded Frameworks & Dylibs and cross-reference Mach-O dependencies.
            let nonIDDeps = (overview?.dylibs ?? []).filter { $0.kind != .id }
            var depsByInstallName: [String: LCMachODylibDependency] = [:]
            for dep in nonIDDeps where depsByInstallName[dep.path] == nil {
                depsByInstallName[dep.path] = dep
            }

            // Track which Frameworks link other Frameworks so removing a shared framework shows a clear warning.
            let frameworksURL = stagedAppURL.appendingPathComponent("Frameworks", isDirectory: true)
            let frameworkItemsRaw = (try? fm.contentsOfDirectory(
                at: frameworksURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var reverseFrameworkDependents: [String: [String]] = [:]
            for itemURL in frameworkItemsRaw where itemURL.pathExtension.lowercased() == "framework" {
                if let fwExec = LCBoundedFileReader.resolveMachOExecutableURL(for: itemURL),
                   let fwCtx = try? LCMachOParser.parseSliceContext(at: fwExec) {
                    let parentName = itemURL.lastPathComponent
                    for dep in fwCtx.overview.dylibs where dep.kind != .id {
                        if let matchedKey = matchedFrameworkOrDylibKey(for: dep.path), matchedKey != parentName {
                            reverseFrameworkDependents[matchedKey, default: []].append(parentName)
                        }
                    }
                }
            }

            var components: [LCPackageComponentItem] = []
            var matchedDepPaths = Set<String>()
            var alreadyHasSubstrate = false

            for itemURL in frameworkItemsRaw.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let ext = itemURL.pathExtension.lowercased()
                let itemName = itemURL.lastPathComponent
                let relPath = "Frameworks/\(itemName)"
                if itemName == "CydiaSubstrate.framework" || itemName == "ElleKit.framework" {
                    alreadyHasSubstrate = true
                }

                if ext == "framework" {
                    let fwExec = LCBoundedFileReader.resolveMachOExecutableURL(for: itemURL)
                    let execFileName = fwExec?.lastPathComponent ?? itemURL.deletingPathExtension().lastPathComponent
                    let aliases = candidateLoadPaths(frameworkFolder: itemName, execName: execFileName)
                    let linkedDep = aliases.lazy.compactMap { depsByInstallName[$0] }.first
                    for alias in aliases where depsByInstallName[alias] != nil {
                        matchedDepPaths.insert(alias)
                    }
                    let size = directoryAllocatedSize(at: itemURL, fileManager: fm)
                    let depsList = Array(Set(reverseFrameworkDependents[itemName] ?? [])).sorted()
                    components.append(LCPackageComponentItem(
                        id: "framework:\(relPath)",
                        kind: .framework,
                        name: itemName,
                        subtitle: linkedDep?.path ?? relPath,
                        loadCommandPath: linkedDep?.path,
                        loadCommandAliases: aliases,
                        bundleRelativePath: relPath,
                        binaryURL: fwExec ?? itemURL,
                        fileSize: size,
                        isWeakLinked: linkedDep?.kind == .weak,
                        isEnabled: true,
                        dependentNames: depsList
                    ))
                } else if ext == "dylib" {
                    let aliases = [
                        "@rpath/\(itemName)",
                        "@executable_path/Frameworks/\(itemName)",
                        "@loader_path/Frameworks/\(itemName)",
                        "@executable_path/\(itemName)"
                    ]
                    let linkedDep = aliases.lazy.compactMap { depsByInstallName[$0] }.first
                    for alias in aliases where depsByInstallName[alias] != nil {
                        matchedDepPaths.insert(alias)
                    }
                    let size = fileAllocatedSize(at: itemURL)
                    let depsList = Array(Set(reverseFrameworkDependents[itemName] ?? [])).sorted()
                    components.append(LCPackageComponentItem(
                        id: "frameworkdylib:\(relPath)",
                        kind: .framework,
                        name: itemName,
                        subtitle: linkedDep?.path ?? relPath,
                        loadCommandPath: linkedDep?.path,
                        loadCommandAliases: aliases,
                        bundleRelativePath: relPath,
                        binaryURL: itemURL,
                        fileSize: size,
                        isWeakLinked: linkedDep?.kind == .weak,
                        isEnabled: true,
                        dependentNames: depsList
                    ))
                }
            }

            // Root-level dylibs copied directly into `.app/`
            let rootItems = (try? fm.contentsOfDirectory(
                at: stagedAppURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for itemURL in rootItems where itemURL.pathExtension.lowercased() == "dylib" {
                let itemName = itemURL.lastPathComponent
                let aliases = ["@executable_path/\(itemName)", "@rpath/\(itemName)"]
                let linkedDep = aliases.lazy.compactMap { depsByInstallName[$0] }.first
                for alias in aliases where depsByInstallName[alias] != nil {
                    matchedDepPaths.insert(alias)
                }
                components.append(LCPackageComponentItem(
                    id: "rootdylib:\(itemName)",
                    kind: .linkedDylib,
                    name: itemName,
                    subtitle: linkedDep?.path ?? itemName,
                    loadCommandPath: linkedDep?.path,
                    loadCommandAliases: aliases,
                    bundleRelativePath: itemName,
                    binaryURL: itemURL,
                    fileSize: fileAllocatedSize(at: itemURL),
                    isWeakLinked: linkedDep?.kind == .weak,
                    isEnabled: true,
                    dependentNames: []
                ))
            }

            // Non-system linked dylib commands in main executable that did not map to an item above
            var hiddenSystemDylibCount = 0
            for dep in nonIDDeps where !matchedDepPaths.contains(dep.path) {
                if isSystemDylibPath(dep.path) {
                    hiddenSystemDylibCount += 1
                    continue
                }
                if dep.path.contains("TweakLoader.dylib") {
                    continue
                }
                let display = (dep.path as NSString).lastPathComponent
                components.append(LCPackageComponentItem(
                    id: "dylib:\(dep.path)",
                    kind: .linkedDylib,
                    name: display.isEmpty ? dep.path : display,
                    subtitle: dep.path,
                    loadCommandPath: dep.path,
                    loadCommandAliases: [dep.path],
                    bundleRelativePath: nil,
                    binaryURL: nil,
                    fileSize: 0,
                    isWeakLinked: dep.kind == .weak,
                    isEnabled: true,
                    dependentNames: []
                ))
            }

            // App Extensions (PlugIns/*.appex)
            let plugInsURL = stagedAppURL.appendingPathComponent("PlugIns", isDirectory: true)
            let plugInItems = (try? fm.contentsOfDirectory(
                at: plugInsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for appexURL in plugInItems where appexURL.pathExtension.lowercased() == "appex" {
                let relPath = "PlugIns/\(appexURL.lastPathComponent)"
                let extExec = LCBoundedFileReader.resolveMachOExecutableURL(for: appexURL)
                components.append(LCPackageComponentItem(
                    id: "appex:\(relPath)",
                    kind: .appExtension,
                    name: appexURL.lastPathComponent,
                    subtitle: relPath,
                    loadCommandPath: nil,
                    loadCommandAliases: [],
                    bundleRelativePath: relPath,
                    binaryURL: extExec ?? appexURL,
                    fileSize: directoryAllocatedSize(at: appexURL, fileManager: fm),
                    isWeakLinked: false,
                    isEnabled: true,
                    dependentNames: []
                ))
            }

            // Watch Apps (Watch/*.app)
            let watchURL = stagedAppURL.appendingPathComponent("Watch", isDirectory: true)
            let watchItems = (try? fm.contentsOfDirectory(
                at: watchURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for watchAppURL in watchItems where watchAppURL.pathExtension.lowercased() == "app" {
                let relPath = "Watch/\(watchAppURL.lastPathComponent)"
                let watchExec = LCBoundedFileReader.resolveMachOExecutableURL(for: watchAppURL)
                components.append(LCPackageComponentItem(
                    id: "watch:\(relPath)",
                    kind: .watchApp,
                    name: watchAppURL.lastPathComponent,
                    subtitle: relPath,
                    loadCommandPath: nil,
                    loadCommandAliases: [],
                    bundleRelativePath: relPath,
                    binaryURL: watchExec ?? watchAppURL,
                    fileSize: directoryAllocatedSize(at: watchAppURL, fileManager: fm),
                    isWeakLinked: false,
                    isEnabled: true,
                    dependentNames: []
                ))
            }

            return LCPackageBundleSnapshot(
                stagedAppURL: stagedAppURL,
                executableURL: execURL,
                executableName: execName,
                architectures: architectures,
                bundleSize: totalBundleSize,
                appIconData: iconData,
                metadata: metadata,
                components: components,
                hiddenSystemDylibCount: hiddenSystemDylibCount,
                alreadyHasSubstrate: alreadyHasSubstrate
            )
        }
    }

    // MARK: - Private Helpers

    private nonisolated static func readExecutableName(at appBundleURL: URL) -> String? {
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = dict["CFBundleExecutable"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private nonisolated static func isSystemDylibPath(_ path: String) -> Bool {
        path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/")
    }

    private nonisolated static func candidateLoadPaths(frameworkFolder: String, execName: String) -> [String] {
        [
            "@rpath/\(frameworkFolder)/\(execName)",
            "@executable_path/Frameworks/\(frameworkFolder)/\(execName)",
            "@loader_path/Frameworks/\(frameworkFolder)/\(execName)",
            "@executable_path/../../Frameworks/\(frameworkFolder)/\(execName)"
        ]
    }

    private nonisolated static func matchedFrameworkOrDylibKey(for loadPath: String) -> String? {
        let components = loadPath.split(separator: "/")
        if let fwIdx = components.firstIndex(where: { $0.hasSuffix(".framework") }) {
            return String(components[fwIdx])
        }
        if let last = components.last, last.hasSuffix(".dylib") {
            return String(last)
        }
        return nil
    }

    private nonisolated static func fileAllocatedSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private nonisolated static func directoryAllocatedSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return fileAllocatedSize(at: url)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

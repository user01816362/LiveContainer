//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        LCSharedUtils.migrateCertificateToHostKeychainIfNeeded()
        let fm = FileManager()
        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs {
                if !appDir.hasSuffix(".app") {
                    continue
                }
                guard let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)") else {
                    continue
                }
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                let model = LCAppModel(appInfo: newApp)
                if newApp.isHidden {
                    tempHiddenApps.append(model)
                } else {
                    tempApps.append(model)
                    tempURLSchemes?.formUnion((newApp.urlSchemes() as? [String]) ?? [])
                }
                if newApp.is32bitEmulator {
                    tempArm32EmuApps.append(model)
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared {
                    if !appDir.hasSuffix(".app") {
                        continue
                    }
                    guard let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)") else {
                        continue
                    }
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    let model = LCAppModel(appInfo: newApp)
                    if newApp.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(model)
                        tempURLSchemes?.formUnion((newApp.urlSchemes() as? [String]) ?? [])
                    }
                    if newApp.is32bitEmulator {
                        tempArm32EmuApps.append(model)
                    }
                }
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }

        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.arm32EmuApps = tempArm32EmuApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        LCLaunchCatalogSync.sync(apps: tempApps, hiddenApps: tempHiddenApps)
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }

        let dataPath = LCPath.dataPath
        let tweakPath = LCPath.tweakPath
        Task.detached(priority: .utility) {
            let bgFM = FileManager()
            cleanupStaleExportArtifacts(fileManager: bgFM)
            let (dataFolderNames, tweakFolderNames) = Self.scanDataAndTweakFolders(
                fileManager: bgFM,
                dataPath: dataPath,
                tweakPath: tweakPath
            )
            await MainActor.run {
                DataManager.shared.model.appDataFolderNames = dataFolderNames
                DataManager.shared.model.tweakFolderNames = tweakFolderNames
            }
        }
    }

    private nonisolated static func scanDataAndTweakFolders(
        fileManager fm: FileManager,
        dataPath: URL,
        tweakPath: URL
    ) -> ([String], [String]) {
        var tempAppDataFolderNames: [String] = []
        var tempTweakFolderNames: [String] = []
        do {
            try fm.createDirectory(at: dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }

            try fm.createDirectory(at: tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                let lowerName = folderName.lowercased()
                if lowerName.hasSuffix(".framework") || lowerName.hasSuffix(".bundle") {
                    continue
                }
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }
        return (tempAppDataFolderNames, tempTweakFolderNames)
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
                .environmentObject(LCDownloadManager.shared)
                .environmentObject(AltStoreSourcesViewModel.shared)
        }
        
        WindowGroup(id: "appView", for: String.self) { $id in
            if let id {
                MultitaskAppWindow(id: id)
            }
        }
    }
    
}

private nonisolated func cleanupStaleExportArtifacts(fileManager: FileManager) {
    let exportDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent("LCExports", isDirectory: true)
    if fileManager.fileExists(atPath: exportDirectoryURL.path) {
        try? fileManager.removeItem(at: exportDirectoryURL)
    }
    LCPackageStagingManager.cleanupStaleStagingDirectories(fileManager: fileManager)
    LCTweakArchiveUnpacker.cleanupStaleStagingDirectories(fileManager: fileManager)
    LCDownloadManager.cleanupOrphanedDownloads(fileManager: fileManager)

    // Legacy staging folders used during export and install creation.
    let legacyPrefixes = [
        "LCAppExport-", "LCDataExport-", "LCBinaryExport-", "LCInstall-",
        "LCTweakImport-", "LCTweakDL-", "LCTweakProbe-", "LCTweakWork-"
    ]
    let tempRoot = fileManager.temporaryDirectory
    guard let tempItems = try? fileManager.contentsOfDirectory(
        at: tempRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for itemURL in tempItems {
        let name = itemURL.lastPathComponent
        if legacyPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? fileManager.removeItem(at: itemURL)
        }
    }
}

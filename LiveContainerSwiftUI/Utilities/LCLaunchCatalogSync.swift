//
//  LCLaunchCatalogSync.swift
//  LiveContainer
//

import Foundation

/// Publishes read-only app launch metadata and cached icons to the shared App Group so
/// LaunchAppExtension and ShareExtension can resolve apps and launch containers without a
/// security-scoped bookmark into private host Documents.
@MainActor
enum LCLaunchCatalogSync {
    static let catalogKey = "LCLaunchAppCatalog"
    static let iconsFolderName = "LaunchCatalogIcons"
    private static let legacyPrivateDocBookmarkKey = "LCLaunchExtensionPrivateDocBookmark"
    private static let iconFilenames = ["LCAppIconLight.png", "LCAppIconDark.png"]

    static func syncFromSharedModel() {
        let model = DataManager.shared.model
        sync(apps: model.apps, hiddenApps: model.hiddenApps, multiLCStatus: model.multiLCStatus)
    }

    static func sync(apps: [LCAppModel], hiddenApps: [LCAppModel], multiLCStatus: Int = DataManager.shared.model.multiLCStatus) {
        guard multiLCStatus != 2 else {
            return
        }
        let sharedDefaults = LCUtils.appGroupUserDefault
        // Purge any legacy private Documents bookmark so LiveProcess guests cannot resolve it.
        if sharedDefaults.object(forKey: legacyPrivateDocBookmarkKey) != nil {
            sharedDefaults.removeObject(forKey: legacyPrivateDocBookmarkKey)
        }

        let strictHiding = sharedDefaults.bool(forKey: "LCStrictHiding")
        let visiblePool = strictHiding ? apps : (apps + hiddenApps)

        var catalog: [String: [String: Any]] = [:]
        var activeIconFolders: Set<String> = []
        let iconsRoot = LCSharedUtils.appGroupPath()?
            .appendingPathComponent("LiveContainer", isDirectory: true)
            .appendingPathComponent(iconsFolderName, isDirectory: true)

        for app in visiblePool {
            let info = app.appInfo
            guard let relativePath = info.relativeBundlePath,
                  isSafeSingleComponent(relativePath) else {
                continue
            }

            let containerEntries: [[String: String]]
            if !app.uiContainers.isEmpty {
                containerEntries = app.uiContainers.compactMap { container in
                    guard isSafeSingleComponent(container.folderName) else {
                        return nil
                    }
                    return [
                        "folderName": container.folderName,
                        "name": container.name
                    ]
                }
            } else if let dataUUID = info.dataUUID, isSafeSingleComponent(dataUUID) {
                containerEntries = [["folderName": dataUUID, "name": dataUUID]]
            } else {
                containerEntries = []
            }

            var entry: [String: Any] = [
                "displayName": info.displayName() ?? relativePath,
                "bundleIdentifier": info.bundleIdentifier() ?? "Unknown",
                "isShared": app.uiIsShared,
                "isHidden": info.isHidden,
                "isLocked": info.isLocked,
                "isJITNeeded": info.isJITNeeded,
                "classicMode": info.classicMode,
                "defaultClassicMode": info.defaultClassicMode,
                "containers": containerEntries
            ]
            if let dataUUID = info.dataUUID, isSafeSingleComponent(dataUUID) {
                entry["LCDataUUID"] = dataUUID
            }
            if let lastLaunched = info.lastLaunched {
                entry["lastLaunched"] = lastLaunched
            }
            if let installationDate = info.installationDate {
                entry["installationDate"] = installationDate
            }
            catalog[relativePath] = entry

            if let iconsRoot, !app.uiIsShared, let bundlePath = info.bundlePath(), !bundlePath.isEmpty {
                activeIconFolders.insert(relativePath)
                let srcDir = URL(fileURLWithPath: bundlePath, isDirectory: true)
                let dstDir = iconsRoot.appendingPathComponent(relativePath, isDirectory: true)
                mirrorIcons(from: srcDir, to: dstDir, info: info)
            }
        }

        if let iconsRoot {
            let builtInSideStoreSrc = LCPath.docPath
                .appendingPathComponent("SideStore/Library/Caches", isDirectory: true)
                .appendingPathComponent("BuiltInSideStoreIconCache", isDirectory: true)
            if FileManager.default.fileExists(atPath: builtInSideStoreSrc.path) {
                activeIconFolders.insert("builtinSideStore")
                let dstDir = iconsRoot.appendingPathComponent("builtinSideStore", isDirectory: true)
                mirrorIcons(from: builtInSideStoreSrc, to: dstDir, info: nil)
            }
            pruneStaleIconFolders(in: iconsRoot, keeping: activeIconFolders)
        }

        sharedDefaults.set(catalog, forKey: catalogKey)
    }

    private static func isSafeSingleComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func mirrorIcons(from srcDir: URL, to dstDir: URL, info: LCAppInfo?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dstDir.path) {
            try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        }
        for (index, filename) in iconFilenames.enumerated() {
            let src = srcDir.appendingPathComponent(filename)
            let dst = dstDir.appendingPathComponent(filename)
            if !fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path), let info {
                _ = info.iconIsDarkIcon(index == 1)
            }
            guard fm.fileExists(atPath: src.path) else {
                continue
            }
            let srcDate = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date
            let dstDate = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date
            if let dstDate, let srcDate, dstDate >= srcDate {
                continue
            }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    private static func pruneStaleIconFolders(in iconsRoot: URL, keeping activeFolders: Set<String>) {
        let fm = FileManager.default
        guard let existing = try? fm.contentsOfDirectory(at: iconsRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for url in existing where !activeFolders.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }
}

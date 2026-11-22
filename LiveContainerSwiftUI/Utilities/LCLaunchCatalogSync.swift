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
    private nonisolated static let iconFilenames = ["LCAppIconLight.png", "LCAppIconDark.png"]
    private static var pendingSyncTask: Task<Void, Never>?
    private static var pendingIconTask: Task<Void, Never>?

    private struct IconMirrorItem: Sendable {
        let folderName: String
        let sourceDir: URL
    }

    static func syncFromSharedModel() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let model = DataManager.shared.model
            sync(apps: model.apps, hiddenApps: model.hiddenApps, multiLCStatus: model.multiLCStatus)
        }
    }

    static func sync(apps: [LCAppModel], hiddenApps: [LCAppModel], multiLCStatus: Int = DataManager.shared.model.multiLCStatus) {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
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
        var iconItems: [IconMirrorItem] = []

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

            if !app.uiIsShared, let bundlePath = info.bundlePath(), !bundlePath.isEmpty {
                iconItems.append(IconMirrorItem(
                    folderName: relativePath,
                    sourceDir: URL(fileURLWithPath: bundlePath, isDirectory: true)
                ))
            }
        }

        sharedDefaults.set(catalog, forKey: catalogKey)

        guard let iconsRoot = LCSharedUtils.appGroupPath()?
            .appendingPathComponent("LiveContainer", isDirectory: true)
            .appendingPathComponent(iconsFolderName, isDirectory: true) else {
            return
        }
        let builtInSideStoreSrc = LCPath.docPath
            .appendingPathComponent("SideStore/Library/Caches", isDirectory: true)
            .appendingPathComponent("BuiltInSideStoreIconCache", isDirectory: true)

        pendingIconTask?.cancel()
        pendingIconTask = Task.detached(priority: .utility) {
            Self.mirrorAllIcons(
                items: iconItems,
                builtInSideStoreSrc: builtInSideStoreSrc,
                iconsRoot: iconsRoot
            )
        }
    }

    private static func isSafeSingleComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private nonisolated static func mirrorAllIcons(
        items: [IconMirrorItem],
        builtInSideStoreSrc: URL,
        iconsRoot: URL
    ) {
        let fm = FileManager.default
        var activeIconFolders: Set<String> = []

        for item in items {
            guard !Task.isCancelled else { return }
            activeIconFolders.insert(item.folderName)
            let dstDir = iconsRoot.appendingPathComponent(item.folderName, isDirectory: true)
            mirrorIcons(from: item.sourceDir, to: dstDir, fileManager: fm)
        }

        if fm.fileExists(atPath: builtInSideStoreSrc.path) {
            activeIconFolders.insert("builtinSideStore")
            let dstDir = iconsRoot.appendingPathComponent("builtinSideStore", isDirectory: true)
            mirrorIcons(from: builtInSideStoreSrc, to: dstDir, fileManager: fm)
        }

        guard !Task.isCancelled else { return }
        pruneStaleIconFolders(in: iconsRoot, keeping: activeIconFolders, fileManager: fm)
    }

    private nonisolated static func mirrorIcons(from srcDir: URL, to dstDir: URL, fileManager fm: FileManager) {
        if !fm.fileExists(atPath: dstDir.path) {
            try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        }
        for filename in iconFilenames {
            let src = srcDir.appendingPathComponent(filename)
            let dst = dstDir.appendingPathComponent(filename)
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

    private nonisolated static func pruneStaleIconFolders(
        in iconsRoot: URL,
        keeping activeFolders: Set<String>,
        fileManager fm: FileManager
    ) {
        guard let existing = try? fm.contentsOfDirectory(at: iconsRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for url in existing where !activeFolders.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }
}

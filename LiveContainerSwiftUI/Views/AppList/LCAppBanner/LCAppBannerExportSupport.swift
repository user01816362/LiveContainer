//
//  LCAppBannerExportSupport.swift
//  LiveContainerSwiftUI
//

import Foundation

enum AppBinaryExportKind: String, Sendable {
    case dylib = "Dylib"
    case framework = "Framework"
}

struct AppBinaryExportItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let relativePath: String
    let kind: AppBinaryExportKind
}

private let lcExportArtifactDirectoryName = "LCExports"

func lcExportArtifactDirectoryURL(fileManager: FileManager = .default) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(lcExportArtifactDirectoryName, isDirectory: true)
}

func lcEnsureExportArtifactDirectory(fileManager: FileManager = .default) throws -> URL {
    let directoryURL = lcExportArtifactDirectoryURL(fileManager: fileManager)
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        try fileManager.removeItem(at: directoryURL)
    }
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

func lcExportArtifactFileURL(fileName: String, fileManager: FileManager = .default) throws -> URL {
    let directoryURL = try lcEnsureExportArtifactDirectory(fileManager: fileManager)
    return directoryURL.appendingPathComponent(fileName)
}

/// Restores `Info.plist` if `doUseLCBundleId` overwrote `CFBundleIdentifier` and
/// strips LiveContainer-internal metadata files (`LCAppInfo.plist`, icon caches,
/// `zsign_cache.json`, `LiveContainer.tmp`, `LCAppExtension.plist`, `LCUserData`)
/// from a staged `.app` bundle. Optionally unpatches `MH_DYLIB` executables back
/// to `MH_EXECUTE` for portable IPA exports.
func lcSanitizeStagedAppBundle(
    at bundleURL: URL,
    unpatchExecutables: Bool,
    fileManager: FileManager = .default
) throws {
    let lcAppInfoURL = bundleURL.appendingPathComponent("LCAppInfo.plist")
    let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")

    if fileManager.fileExists(atPath: lcAppInfoURL.path),
       let lcData = try? Data(contentsOf: lcAppInfoURL),
       let lcDict = try? PropertyListSerialization.propertyList(from: lcData, format: nil) as? [String: Any],
       (lcDict["doUseLCBundleId"] as? Bool) == true,
       let originalBundleId = lcDict["LCOrignalBundleIdentifier"] as? String,
       !originalBundleId.isEmpty,
       fileManager.fileExists(atPath: infoPlistURL.path),
       let infoData = try? Data(contentsOf: infoPlistURL) {
        var format: PropertyListSerialization.PropertyListFormat = .binary
        if var infoDict = try? PropertyListSerialization.propertyList(from: infoData, format: &format) as? [String: Any] {
            infoDict["CFBundleIdentifier"] = originalBundleId
            let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .xml) ? .xml : .binary
            let updatedData = try PropertyListSerialization.data(fromPropertyList: infoDict, format: writeFormat, options: 0)
            try updatedData.write(to: infoPlistURL, options: .atomic)
        }
    }

    for artifact in ["LCAppInfo.plist", "LCAppIconLight.png", "LCAppIconDark.png", "zsign_cache.json", "LiveContainer.tmp", "LCUserData"] {
        let artifactURL = bundleURL.appendingPathComponent(artifact)
        if fileManager.fileExists(atPath: artifactURL.path) {
            try? fileManager.removeItem(at: artifactURL)
        }
    }

    if unpatchExecutables {
        try lcUnpatchBundleExecutableIfPresent(at: bundleURL, fileManager: fileManager)
    }

    let plugInsURL = bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
    if let plugIns = try? fileManager.contentsOfDirectory(
        at: plugInsURL,
        includingPropertiesForKeys: nil,
        options: []
    ) {
        for appexURL in plugIns where appexURL.pathExtension.lowercased() == "appex" {
            let extPlistURL = appexURL.appendingPathComponent("LCAppExtension.plist")
            if fileManager.fileExists(atPath: extPlistURL.path) {
                try? fileManager.removeItem(at: extPlistURL)
            }
            if unpatchExecutables {
                try lcUnpatchBundleExecutableIfPresent(at: appexURL, fileManager: fileManager)
            }
        }
    }
}

private func lcUnpatchBundleExecutableIfPresent(at bundleURL: URL, fileManager: FileManager) throws {
    let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoPlistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let execName = plist["CFBundleExecutable"] as? String,
          !execName.isEmpty else {
        return
    }
    let execURL = bundleURL.appendingPathComponent(execName)
    guard fileManager.fileExists(atPath: execURL.path) else {
        return
    }
    if let err = execURL.path.withCString({ LCUnpatchMachOExecutableAtPath($0) }) {
        throw err
    }
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)
}

func lcListExportableBinaries(bundlePath: String) throws -> [AppBinaryExportItem] {
    let rootURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
    let fm = FileManager.default

    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var items: [AppBinaryExportItem] = []
    var seenPaths = Set<String>()
    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

    for case let itemURL as URL in enumerator {
        let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory ?? false

        if isDirectory && itemURL.pathExtension.lowercased() == "framework" {
            let relativePath = itemURL.path.hasPrefix(rootPrefix) ? String(itemURL.path.dropFirst(rootPrefix.count)) : itemURL.lastPathComponent
            if seenPaths.insert(relativePath).inserted {
                items.append(AppBinaryExportItem(id: "framework:\(relativePath)", url: itemURL, relativePath: relativePath, kind: .framework))
            }
            enumerator.skipDescendants()
            continue
        }

        if !isDirectory && itemURL.pathExtension.lowercased() == "dylib" {
            let relativePath = itemURL.path.hasPrefix(rootPrefix) ? String(itemURL.path.dropFirst(rootPrefix.count)) : itemURL.lastPathComponent
            if seenPaths.insert(relativePath).inserted {
                items.append(AppBinaryExportItem(id: "dylib:\(relativePath)", url: itemURL, relativePath: relativePath, kind: .dylib))
            }
        }
    }

    return items.sorted { lhs, rhs in
        if lhs.kind == rhs.kind {
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

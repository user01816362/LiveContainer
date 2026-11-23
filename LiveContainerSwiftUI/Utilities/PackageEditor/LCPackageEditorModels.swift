//
//  LCPackageEditorModels.swift
//  LiveContainerSwiftUI
//

import Foundation

/// Distinguishes between editing an IPA right before installing into LiveContainer
/// and exporting a standalone unsigned/tweaked IPA for sideloading outside LiveContainer.
enum LCPackageEditorMode: String, Sendable {
    case preInstall
    case standaloneExport

    var badgeTitle: String {
        switch self {
        case .preInstall:
            return "lc.packageEditor.mode.preInstall".loc
        case .standaloneExport:
            return "lc.packageEditor.mode.standaloneExport".loc
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .preInstall:
            return "lc.packageEditor.action.install".loc
        case .standaloneExport:
            return "lc.packageEditor.action.export".loc
        }
    }
}

enum LCPackageComponentKind: String, CaseIterable, Sendable {
    case linkedDylib
    case framework
    case appExtension
    case watchApp

    var sectionTitle: String {
        switch self {
        case .linkedDylib:
            return "Linked Dylibs"
        case .framework:
            return "Frameworks"
        case .appExtension:
            return "App Extensions (PlugIns)"
        case .watchApp:
            return "Watch Apps"
        }
    }
}

/// Unified representation of an existing dylib, framework, plugin, or Watch app.
/// When a component carries both `bundleRelativePath` and `loadCommandPath`, disabling
/// it removes both the files on disk and the matching Mach-O load commands cleanly.
struct LCPackageComponentItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: LCPackageComponentKind
    let name: String
    let subtitle: String
    let loadCommandPath: String?
    let loadCommandAliases: [String]
    let bundleRelativePath: String?
    let binaryURL: URL?
    let fileSize: Int64
    let isWeakLinked: Bool
    var isEnabled: Bool
    let dependentNames: [String]

    var formattedSize: String {
        guard fileSize > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum LCTweakPackageKind: String, Sendable {
    case dylib
    case framework
    case deb
    case zip

    var badgeText: String {
        rawValue.uppercased()
    }
}

struct LCPackageQueuedTweak: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let displayName: String
    let sourceLabel: String
    let kind: LCTweakPackageKind
    let needsElleKit: Bool
    let hasValidArm64Slice: Bool
    let unresolvedDependencies: [String]
    let payloadCount: Int
    let fileSize: Int64
    var weakLink: Bool
    var injectIntoExtensions: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct LCPackageMetadataDraft: Equatable, Sendable {
    let originalDisplayName: String
    let originalBundleName: String
    let originalBundleIdentifier: String
    let originalShortVersion: String
    let originalBuildVersion: String
    let originalMinimumOSVersion: String

    var displayName: String
    var bundleName: String
    var bundleIdentifier: String
    var shortVersion: String
    var buildVersion: String
    var minimumOSVersion: String

    var updateExtensionBundleIds: Bool
    var updateLocalizedNames: Bool
    var removeSupportedDevices: Bool
    var enableFileSharing: Bool
    var removeURLSchemes: Bool

    var hasSupportedDevicesKey: Bool
    var hasFileSharingEnabled: Bool
    var hasURLSchemes: Bool

    var modifiedFieldCount: Int {
        var count = 0
        if displayName != originalDisplayName { count += 1 }
        if bundleName != originalBundleName { count += 1 }
        if bundleIdentifier != originalBundleIdentifier { count += 1 }
        if shortVersion != originalShortVersion { count += 1 }
        if buildVersion != originalBuildVersion { count += 1 }
        if minimumOSVersion != originalMinimumOSVersion { count += 1 }
        if removeSupportedDevices && hasSupportedDevicesKey { count += 1 }
        if enableFileSharing != hasFileSharingEnabled { count += 1 }
        if removeURLSchemes && hasURLSchemes { count += 1 }
        return count
    }
}

struct LCPackageBundleSnapshot: Sendable {
    let stagedAppURL: URL
    let executableURL: URL?
    let executableName: String
    let architectures: [String]
    let bundleSize: Int64
    let appIconData: Data?
    let metadata: LCPackageMetadataDraft
    let components: [LCPackageComponentItem]
    let hiddenSystemDylibCount: Int
    let alreadyHasSubstrate: Bool

    var formattedBundleSize: String {
        ByteCountFormatter.string(fromByteCount: bundleSize, countStyle: .file)
    }
}

struct LCPackageEditPlan: Sendable {
    let mode: LCPackageEditorMode
    let metadata: LCPackageMetadataDraft
    let removedComponentIDs: Set<String>
    let allComponents: [LCPackageComponentItem]
    let queuedTweaks: [LCPackageQueuedTweak]
}

struct LCPackageProgress: Sendable {
    let fraction: Double
    let stage: String
}

struct LCLiveContainerTweakSection: Identifiable, Sendable {
    var id: String { folderPath }
    let folderPath: String
    let title: String
    let isAppFolder: Bool
    let urls: [URL]
}

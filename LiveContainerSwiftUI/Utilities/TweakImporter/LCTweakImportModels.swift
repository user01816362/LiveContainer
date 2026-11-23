//
//  LCTweakImportModels.swift
//  LiveContainerSwiftUI
//
//  Immutable Sendable domain models and staged session handle for LiveContainer's
//  tweak format detection, recursive archive unpacking, Mach-O validation, and
//  off-main installation pipeline.
//

import Foundation
import os

/// Detected container or payload format determined by magic bytes and filename/HTTP metadata.
enum LCTweakSourceFormat: String, Sendable, CaseIterable {
    case dylib
    case framework
    case deb
    case zip
    case ipa
    case tar
    case zstdUnsupported
    case htmlErrorPage
    case unknown

    var displayLabel: String {
        switch self {
        case .dylib: return "Dynamic Library (.dylib)"
        case .framework: return "Framework Bundle (.framework)"
        case .deb: return "Debian Package (.deb)"
        case .zip: return "ZIP Archive (.zip)"
        case .ipa: return "iOS App Archive (.ipa)"
        case .tar: return "TAR Archive"
        case .zstdUnsupported: return "Zstandard Compressed (.zst)"
        case .htmlErrorPage: return "HTML Web Page"
        case .unknown: return "Unknown Format"
        }
    }

    var preferredExtension: String? {
        switch self {
        case .dylib: return "dylib"
        case .framework: return "framework"
        case .deb: return "deb"
        case .zip: return "zip"
        case .ipa: return "ipa"
        case .tar: return "tar"
        case .zstdUnsupported: return "zst"
        case .htmlErrorPage: return "html"
        case .unknown: return nil
        }
    }

    var isArchiveContainer: Bool {
        switch self {
        case .deb, .zip, .ipa, .tar:
            return true
        case .dylib, .framework, .zstdUnsupported, .htmlErrorPage, .unknown:
            return false
        }
    }
}

/// Physical file/bundle type of a discovered payload item.
enum LCTweakPayloadKind: String, Sendable {
    case dylib
    case framework
    case resourceBundle

    var systemImage: String {
        switch self {
        case .dylib: return "building.columns.fill"
        case .framework: return "shippingbox.fill"
        case .resourceBundle: return "folder.fill.badge.gearshape"
        }
    }
}

/// Semantic role classification used to distinguish real tweaks from resources,
/// preference bundles, or app runtime frameworks when harvesting archives/IPAs.
enum LCTweakPayloadRole: String, Sendable, CaseIterable {
    case tweak
    case resource
    case preferenceBundle
    case appFramework

    var sectionTitle: String {
        switch self {
        case .tweak: return "Tweaks & Libraries"
        case .resource: return "Resource Bundles"
        case .preferenceBundle: return "Preference Bundles"
        case .appFramework: return "App & Runtime Frameworks"
        }
    }
}

/// Collision resolution strategy when a payload filename already exists in the destination folder.
enum LCTweakConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case overwrite
    case keepBoth
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite: return "Overwrite"
        case .keepBoth: return "Keep Both"
        case .skip: return "Skip Existing"
        }
    }
}

/// Live progress update emitted during staging, unpacking, patching, and signing.
struct LCTweakImportProgress: Sendable {
    let fraction: Double
    let status: String
}

/// Architecture, platform, and dependency compatibility report for a single Mach-O binary.
struct LCTweakCompatibilityReport: Sendable {
    let isMachOValid: Bool
    let hasArm64iOSSlice: Bool
    let architectures: [String]
    let platforms: [String]
    let isSimulatorOrMacOnly: Bool
    let needsSubstrate: Bool
    let substrateDependencies: [String]
    let unresolvedDependencies: [String]
    let knownJailbreakDependencies: [String]
    let loadPaths: [String]
    let warnings: [String]

    static let nonMachO = LCTweakCompatibilityReport(
        isMachOValid: false,
        hasArm64iOSSlice: false,
        architectures: [],
        platforms: [],
        isSimulatorOrMacOnly: false,
        needsSubstrate: false,
        substrateDependencies: [],
        unresolvedDependencies: [],
        knownJailbreakDependencies: [],
        loadPaths: [],
        warnings: ["Not a valid Mach-O binary."]
    )
}

/// Single discovered `.dylib`, `.framework`, or `.bundle` ready for optional user review and installation.
struct LCTweakDiscoveredPayload: Identifiable, Sendable {
    let id: UUID
    let stagedURL: URL
    let fileName: String
    let relativeSourcePath: String
    let sourceArchiveChain: [String]
    let kind: LCTweakPayloadKind
    let role: LCTweakPayloadRole
    let fileSize: Int64
    let compatibility: LCTweakCompatibilityReport?
    let isSelectedByDefault: Bool
    let isProtectedCollision: Bool
    let existingCollisionName: String?
    let filterBundleIdentifiers: [String]

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: max(fileSize, 0), countStyle: .file)
    }

    var hasCompatibilityIssue: Bool {
        guard let compatibility else { return false }
        return !compatibility.isMachOValid
            || !compatibility.hasArm64iOSSlice
            || compatibility.isSimulatorOrMacOnly
            || !compatibility.warnings.isEmpty
    }
}

/// Staged inspection session owning its temporary directory cleanly until cleanup.
final class LCTweakInspectionSession: Identifiable, @unchecked Sendable {
    let id = UUID()
    let stagingRootURL: URL
    let sourceNames: [String]
    let sourceFormats: [LCTweakSourceFormat]
    let payloads: [LCTweakDiscoveredPayload]
    let warnings: [String]
    let containsIPAHarvest: Bool
    let requiresReview: Bool

    private let cleanupLock = OSAllocatedUnfairLock(initialState: false)

    init(
        stagingRootURL: URL,
        sourceNames: [String],
        sourceFormats: [LCTweakSourceFormat],
        payloads: [LCTweakDiscoveredPayload],
        warnings: [String],
        containsIPAHarvest: Bool,
        requiresReview: Bool
    ) {
        self.stagingRootURL = stagingRootURL
        self.sourceNames = sourceNames
        self.sourceFormats = sourceFormats
        self.payloads = payloads
        self.warnings = warnings
        self.containsIPAHarvest = containsIPAHarvest
        self.requiresReview = requiresReview
    }

    deinit {
        cleanup()
    }

    var defaultSelectedIDs: Set<UUID> {
        Set(payloads.filter(\.isSelectedByDefault).map(\.id))
    }

    var hasCollisions: Bool {
        payloads.contains { $0.existingCollisionName != nil }
    }

    func cleanup() {
        let shouldClean = cleanupLock.withLock { alreadyCleaned -> Bool in
            if alreadyCleaned {
                return false
            }
            alreadyCleaned = true
            return true
        }
        guard shouldClean else { return }
        try? FileManager.default.removeItem(at: stagingRootURL)
    }
}

/// Summary returned after installing selected tweak payloads into the destination folder.
struct LCTweakImportResult: Sendable {
    let installedNames: [String]
    let skippedNames: [String]
    let warnings: [String]
    let signingWarning: String?
}

//
//  LCTweakDependencyResolver.swift
//  LiveContainerSwiftUI
//

import Foundation

struct LCUnpackedTweakPayloads: Sendable {
    let dylibs: [URL]
    let frameworks: [URL]
    let resourceBundles: [URL]
}

/// Discovers LiveContainer tweaks, unpacks `.deb`/`.zip`/`.framework`/`.dylib` tweaks safely off-main,
/// detects Substrate/ElleKit/Substitute dependencies, and computes coherent `@rpath` remap tables.
enum LCTweakDependencyResolver {
    nonisolated static let canonicalSubstrateLoadPath = LCTweakMachOInspector.canonicalSubstrateLoadPath

    nonisolated static func isSubstrateAlias(_ path: String) -> Bool {
        LCTweakMachOInspector.isSubstrateAlias(path)
    }

    nonisolated static func discoverLiveContainerTweaks(appTweakFolder: String?) -> [LCLiveContainerTweakSection] {
        let fm = FileManager.default
        var sections: [LCLiveContainerTweakSection] = []
        var visitedDirs = Set<String>()

        func scanFolder(_ folderURL: URL, title: String) {
            let stdPath = folderURL.standardizedFileURL.path
            guard visitedDirs.insert(stdPath).inserted, fm.fileExists(atPath: stdPath) else {
                return
            }

            let tweakInfoURL = folderURL.appendingPathComponent("TweakInfo.plist")
            let disabledNames: Set<String> = {
                guard let dict = NSDictionary(contentsOf: tweakInfoURL) as? [String: Any],
                      let list = dict["disabledItems"] as? [String] else {
                    return []
                }
                return Set(list)
            }()

            let items = (try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let tweaks = items.filter { url in
                let name = url.lastPathComponent
                if name == "TweakLoader.dylib" || name == "TweakInfo.plist" || name.hasSuffix(".disabled") {
                    return false
                }
                if disabledNames.contains(name) {
                    return false
                }
                let ext = url.pathExtension.lowercased()
                return ext == "dylib" || ext == "framework" || ext == "deb" || ext == "zip"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if !tweaks.isEmpty {
                sections.append(LCLiveContainerTweakSection(title: title, urls: tweaks))
            }
        }

        if let appTweakFolder, !appTweakFolder.isEmpty {
            scanFolder(LCPath.tweakPath.appendingPathComponent(appTweakFolder, isDirectory: true), title: "App Tweaks (\(appTweakFolder))")
            scanFolder(LCPath.lcGroupTweakPath.appendingPathComponent(appTweakFolder, isDirectory: true), title: "Shared App Tweaks (\(appTweakFolder))")
        }

        scanFolder(LCPath.tweakPath, title: "Global Tweaks")
        scanFolder(LCPath.lcGroupTweakPath, title: "Shared Global Tweaks")
        return sections
    }

    static func inspectTweakFile(at sourceURL: URL, sourceLabel: String) async throws -> LCPackageQueuedTweak {
        try await lcRunOffMain {
            let needsScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fm = FileManager.default
            let ext = sourceURL.pathExtension.lowercased()
            let kind: LCTweakPackageKind
            switch ext {
            case "dylib": kind = .dylib
            case "framework": kind = .framework
            case "deb": kind = .deb
            case "zip": kind = .zip
            default:
                throw "Unsupported tweak format: .\(ext)"
            }

            let probeDir = fm.temporaryDirectory.appendingPathComponent("LCTweakProbe-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: probeDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: probeDir) }

            let payloads = try unpackTweakSynchronously(from: sourceURL, kind: kind, into: probeDir, fileManager: fm)
            let machOURLs: [URL] = payloads.dylibs + payloads.frameworks.compactMap { LCBoundedFileReader.resolveMachOExecutableURL(for: $0) }
            guard !machOURLs.isEmpty else {
                throw "No .dylib or .framework executable found inside \(sourceURL.lastPathComponent)."
            }

            // Build set of sibling payload identifiers present in the same tweak package.
            var bundledSiblingKeys = Set<String>()
            for dylibURL in payloads.dylibs {
                bundledSiblingKeys.insert(dylibURL.lastPathComponent)
            }
            for fwURL in payloads.frameworks {
                bundledSiblingKeys.insert(fwURL.lastPathComponent)
            }

            var needsElleKit = false
            var allHaveArm64 = true
            var unresolved = Set<String>()

            for binURL in machOURLs {
                let report = LCTweakMachOInspector.inspectBinary(at: binURL, siblingKeys: bundledSiblingKeys)
                if !report.isMachOValid || !report.hasArm64iOSSlice {
                    allHaveArm64 = false
                }
                if report.needsSubstrate {
                    needsElleKit = true
                }
                unresolved.formUnion(report.unresolvedDependencies)
            }

            return LCPackageQueuedTweak(
                id: UUID(),
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                sourceLabel: sourceLabel,
                kind: kind,
                needsElleKit: needsElleKit,
                hasValidArm64Slice: allHaveArm64,
                unresolvedDependencies: unresolved.sorted(),
                payloadCount: payloads.dylibs.count + payloads.frameworks.count,
                fileSize: itemSize(at: sourceURL, fileManager: fm),
                weakLink: false,
                injectIntoExtensions: false
            )
        }
    }

    /// Extracts `.deb` / `.zip` / `.tar.*` / `.ipa` or copies `.dylib` / `.framework` payloads into `workDir`.
    /// Delegates to `LCTweakArchiveUnpacker` so nested archives, `__MACOSX`, `.deb` symlinks, and `.zst` errors are handled uniformly.
    nonisolated static func unpackTweakSynchronously(
        from sourceURL: URL,
        kind: LCTweakPackageKind,
        into workDir: URL,
        fileManager fm: FileManager = .default
    ) throws -> LCUnpackedTweakPayloads {
        let extracted = try LCTweakArchiveUnpacker.unpackSimplePayloads(from: sourceURL, into: workDir, fileManager: fm)
        return LCUnpackedTweakPayloads(
            dylibs: extracted.dylibs,
            frameworks: extracted.frameworks,
            resourceBundles: extracted.resourceBundles
        )
    }

    private nonisolated static func itemSize(at url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory != true {
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let fv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if fv?.isRegularFile == true {
                total += Int64(fv?.fileSize ?? 0)
            }
        }
        return total
    }
}

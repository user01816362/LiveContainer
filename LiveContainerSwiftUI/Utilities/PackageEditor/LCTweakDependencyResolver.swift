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

        func scanTree(rootURL: URL, baseTitle: String, isAppTree: Bool) {
            let stdRoot = rootURL.standardizedFileURL.path
            guard fm.fileExists(atPath: stdRoot) else { return }

            var queue: [(url: URL, relativeSubpath: String)] = [(rootURL, "")]
            var queueIdx = 0

            while queueIdx < queue.count {
                let entry = queue[queueIdx]
                queueIdx += 1

                let folderURL = entry.url
                let stdPath = folderURL.standardizedFileURL.path
                guard visitedDirs.insert(stdPath).inserted else { continue }

                let items = (try? fm.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                var tweaks: [URL] = []
                var subfolders: [(url: URL, relativeSubpath: String)] = []

                for item in items {
                    let name = item.lastPathComponent
                    if name == "TweakLoader.dylib" || name == "TweakInfo.plist" || name == "__MACOSX" {
                        continue
                    }

                    let normalizedName = LCTweakFormatDetector.strippedDisabledSuffix(name)
                    let ext = URL(fileURLWithPath: normalizedName).pathExtension.lowercased()
                    let isSupportedTweak = (ext == "dylib" || ext == "framework" || ext == "deb" || ext == "zip")

                    if isSupportedTweak {
                        tweaks.append(item)
                        continue
                    }

                    let rv = try? item.resourceValues(forKeys: [.isDirectoryKey])
                    if rv?.isDirectory == true {
                        // Do not descend into bundle directories (.bundle, .app, .appex, etc.)
                        let lowerExt = ext
                        if lowerExt == "bundle" || lowerExt == "app" || lowerExt == "appex" || lowerExt == "lproj" {
                            continue
                        }
                        let subRel = entry.relativeSubpath.isEmpty ? name : "\(entry.relativeSubpath)/\(name)"
                        subfolders.append((item, subRel))
                    }
                }

                if !tweaks.isEmpty {
                    let sortedTweaks = tweaks.sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }
                    let title = entry.relativeSubpath.isEmpty
                        ? baseTitle
                        : "\(baseTitle) / \(entry.relativeSubpath)"
                    let matchesAppFolder = isAppTree || (appTweakFolder != nil && !appTweakFolder!.isEmpty && entry.relativeSubpath.localizedCaseInsensitiveCompare(appTweakFolder!) == .orderedSame)
                    sections.append(LCLiveContainerTweakSection(
                        folderPath: stdPath,
                        title: title,
                        isAppFolder: matchesAppFolder,
                        urls: sortedTweaks
                    ))
                }

                for sub in subfolders.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) {
                    queue.append(sub)
                }
            }
        }

        if let appTweakFolder, !appTweakFolder.isEmpty {
            scanTree(rootURL: LCPath.tweakPath.appendingPathComponent(appTweakFolder, isDirectory: true), baseTitle: "App Tweaks (\(appTweakFolder))", isAppTree: true)
            scanTree(rootURL: LCPath.lcGroupTweakPath.appendingPathComponent(appTweakFolder, isDirectory: true), baseTitle: "Shared App Tweaks (\(appTweakFolder))", isAppTree: true)
        }

        scanTree(rootURL: LCPath.tweakPath, baseTitle: "Global Tweaks", isAppTree: false)
        scanTree(rootURL: LCPath.lcGroupTweakPath, baseTitle: "Shared Global Tweaks", isAppTree: false)
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
            let displayName = LCTweakFormatDetector.strippedDisabledSuffix(sourceURL.lastPathComponent)
            let ext = URL(fileURLWithPath: displayName).pathExtension.lowercased()
            let detectedFormat = LCTweakFormatDetector.detectFormat(at: sourceURL, fileManager: fm)
            let kind: LCTweakPackageKind
            switch detectedFormat {
            case .dylib: kind = .dylib
            case .framework: kind = .framework
            case .deb: kind = .deb
            case .zip, .ipa, .tar: kind = .zip
            case .zstdUnsupported:
                throw "'\(displayName)' uses Zstandard (.zst) compression, which is not supported on iOS."
            case .htmlErrorPage:
                throw "'\(displayName)' is an HTML page, not a valid tweak binary or archive."
            case .unknown:
                switch ext {
                case "dylib": kind = .dylib
                case "framework": kind = .framework
                case "deb": kind = .deb
                case "zip", "ipa", "tipa", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2", "lzma": kind = .zip
                default:
                    throw "Unsupported tweak format: \(displayName)"
                }
            }

            let probeDir = fm.temporaryDirectory.appendingPathComponent("LCTweakProbe-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: probeDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: probeDir) }

            let payloads = try unpackTweakSynchronously(from: sourceURL, kind: kind, into: probeDir, fileManager: fm)
            let machOURLs: [URL] = payloads.dylibs + payloads.frameworks.compactMap { LCBoundedFileReader.resolveMachOExecutableURL(for: $0) }
            guard !machOURLs.isEmpty else {
                throw "No .dylib or .framework executable found inside \(displayName)."
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
                displayName: displayName,
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

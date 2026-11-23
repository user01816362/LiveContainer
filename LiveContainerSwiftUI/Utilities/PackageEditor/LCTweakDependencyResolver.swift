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
    nonisolated static let canonicalSubstrateLoadPath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"

    private nonisolated static let substrateAliases: Set<String> = [
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
        "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "@rpath/libsubstrate.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libellekit.dylib",
        "@rpath/libellekit.dylib",
        "/usr/lib/libsubstitute.dylib",
        "/var/jb/usr/lib/libsubstitute.dylib",
        "@rpath/libsubstitute.dylib"
    ]

    nonisolated static func isSubstrateAlias(_ path: String) -> Bool {
        if substrateAliases.contains(path) {
            return true
        }
        let lower = path.lowercased()
        return lower.hasSuffix("/cydiasubstrate.framework/cydiasubstrate") ||
            lower.hasSuffix("/libsubstrate.dylib") ||
            lower.hasSuffix("/libellekit.dylib") ||
            lower.hasSuffix("/libsubstitute.dylib")
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
                guard let ctx = try? LCMachOParser.parseSliceContext(at: binURL) else {
                    allHaveArm64 = false
                    continue
                }
                let hasArm64 = ctx.overview.slices.contains { slice in
                    slice.is64Bit && slice.architectureName.lowercased().hasPrefix("arm64")
                }
                if !hasArm64 {
                    allHaveArm64 = false
                }
                for dep in ctx.overview.dylibs where dep.kind != .id {
                    if isSubstrateAlias(dep.path) {
                        needsElleKit = true
                        continue
                    }
                    if isSystemDependencyPath(dep.path) {
                        continue
                    }
                    if matchesSiblingPayload(dep.path, siblingKeys: bundledSiblingKeys) {
                        continue
                    }
                    if dep.path.hasPrefix("@") {
                        // Ignore standard internal `@rpath`/`@executable_path` unless clearly an external jb library
                        continue
                    }
                    unresolved.insert(dep.path)
                }
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

    /// Extracts `.deb` / `.zip` or copies `.dylib` / `.framework` payloads into `workDir`.
    /// Never modifies or moves the user's original source files.
    nonisolated static func unpackTweakSynchronously(
        from sourceURL: URL,
        kind: LCTweakPackageKind,
        into workDir: URL,
        fileManager fm: FileManager = .default
    ) throws -> LCUnpackedTweakPayloads {
        let localSourceCopy = workDir.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL != localSourceCopy.standardizedFileURL {
            if fm.fileExists(atPath: localSourceCopy.path) {
                try fm.removeItem(at: localSourceCopy)
            }
            try fm.copyItem(at: sourceURL, to: localSourceCopy)
        }

        if kind == .dylib {
            return LCUnpackedTweakPayloads(dylibs: [localSourceCopy], frameworks: [], resourceBundles: [])
        }
        if kind == .framework {
            return LCUnpackedTweakPayloads(dylibs: [], frameworks: [localSourceCopy], resourceBundles: [])
        }

        let outerDir = workDir.appendingPathComponent("outer", isDirectory: true)
        try fm.createDirectory(at: outerDir, withIntermediateDirectories: true)
        let outerStatus = extract(localSourceCopy.path, outerDir.path, nil)
        guard outerStatus == 0 else {
            throw "Failed to extract \(sourceURL.lastPathComponent) (libarchive code \(outerStatus))."
        }

        var searchRoot = outerDir
        if kind == .deb {
            let outerItems = (try? fm.contentsOfDirectory(at: outerDir, includingPropertiesForKeys: nil)) ?? []
            if let dataTar = outerItems.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) {
                let innerDir = workDir.appendingPathComponent("inner", isDirectory: true)
                try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
                let innerStatus = extract(dataTar.path, innerDir.path, nil)
                guard innerStatus == 0 else {
                    throw "Failed to extract \(dataTar.lastPathComponent) inside \(sourceURL.lastPathComponent)."
                }
                searchRoot = innerDir
            }
        }

        var dylibs: [URL] = []
        var frameworks: [URL] = []
        var bundles: [URL] = []

        if let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }
                let isDir = values?.isDirectory ?? false
                let ext = itemURL.pathExtension.lowercased()
                if isDir && ext == "framework" {
                    frameworks.append(itemURL)
                    enumerator.skipDescendants()
                } else if isDir && ext == "bundle" {
                    bundles.append(itemURL)
                    enumerator.skipDescendants()
                } else if !isDir && ext == "dylib" {
                    dylibs.append(itemURL)
                }
            }
        }

        return LCUnpackedTweakPayloads(dylibs: dylibs, frameworks: frameworks, resourceBundles: bundles)
    }

    private nonisolated static func isSystemDependencyPath(_ path: String) -> Bool {
        if path.hasPrefix("/System/Library/") {
            return true
        }
        if path.hasPrefix("/usr/lib/") {
            // Standard Apple libraries live directly under /usr/lib/, whereas jailbreak tweaks put
            // substrate/ellekit/substitute (handled above) or custom libs there.
            let name = (path as NSString).lastPathComponent.lowercased()
            return !name.contains("substrate") && !name.contains("ellekit") && !name.contains("substitute") && !name.contains("rocket") && !name.contains("cephei")
        }
        return false
    }

    private nonisolated static func matchesSiblingPayload(_ path: String, siblingKeys: Set<String>) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        for key in siblingKeys {
            if parts.contains(key) {
                return true
            }
        }
        return false
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

//
//  LCTweakArchiveUnpacker.swift
//  LiveContainerSwiftUI
//
//  Unified off-main archive unpacker for `.deb`, `.zip`, `.ipa`/`.tipa`, `.tar.*`,
//  `.framework`, and `.dylib` tweak sources. Handles nested archives (depth <= 4),
//  `__MACOSX` exclusion, `.deb` symlink tolerance, `.ipa` tweak harvesting, companion
//  resource `.bundle`s, and Substrate `.plist` filter extraction.
//

import Foundation

struct LCExtractedSimplePayloads: Sendable {
    let dylibs: [URL]
    let frameworks: [URL]
    let resourceBundles: [URL]
}

enum LCTweakArchiveUnpacker {
    private nonisolated static let maxArchiveDepth = 4
    private nonisolated static let stagingFolderName = "LCTweakStaging"

    nonisolated static let protectedTweakNames: Set<String> = [
        "tweakloader.dylib",
        "tweakinfo.plist"
    ]

    private nonisolated static let debSafeOptions: LCArchiveExtractOptions = [
        .skipUnsafeLinks,
        .stripLeadingSlashes,
        .normalizePermissions
    ]

    nonisolated static var stagingRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(stagingFolderName, isDirectory: true)
    }

    /// Removes orphaned `tmp/LCTweakStaging` directories left behind by terminated imports.
    nonisolated static func cleanupStaleStagingDirectories(fileManager: FileManager = .default) {
        let root = stagingRootURL
        if fileManager.fileExists(atPath: root.path) {
            try? fileManager.removeItem(at: root)
        }
    }

    /// Inspects and stages one or more local files/bundles into an isolated temporary session.
    /// Never modifies or moves the caller's source files.
    nonisolated static func inspectAndStageSources(
        _ urls: [URL],
        destinationFolder: URL?,
        displayNameOverrides: [URL: String] = [:],
        fileManager fm: FileManager = .default,
        progressHandler: (@Sendable (LCTweakImportProgress) -> Void)? = nil
    ) throws -> LCTweakInspectionSession {
        try fm.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        let sessionRoot = stagingRootURL.appendingPathComponent("Session-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sessionRoot, withIntermediateDirectories: true)

        var cleanupOnThrow = true
        defer {
            if cleanupOnThrow {
                try? fm.removeItem(at: sessionRoot)
            }
        }

        var collector = PayloadCollector()
        var sourceNames: [String] = []
        var sourceFormats: [LCTweakSourceFormat] = []

        for (index, sourceURL) in urls.enumerated() {
            try Task.checkCancellation()

            let needsScope = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsScope {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let sourceName = displayNameOverrides[sourceURL] ?? sourceURL.lastPathComponent
            sourceNames.append(sourceName)

            let progressBase = Double(index) / Double(max(urls.count, 1))
            let progressSpan = 0.65 / Double(max(urls.count, 1))
            progressHandler?(LCTweakImportProgress(
                fraction: 0.05 + progressBase * 0.65,
                status: "Inspecting \(sourceName)…"
            ))

            let sourceStageDir = sessionRoot.appendingPathComponent("src_\(index)", isDirectory: true)
            try fm.createDirectory(at: sourceStageDir, withIntermediateDirectories: true)

            let format = LCTweakFormatDetector.detectFormat(at: sourceURL, fileManager: fm)
            sourceFormats.append(format)

            switch format {
            case .htmlErrorPage:
                throw "Download returned an HTML page instead of a tweak binary/archive (\(sourceName))."
            case .zstdUnsupported:
                throw "'\(sourceName)' uses Zstandard (.zst) compression, which is not supported by iOS system libarchive."
            case .unknown:
                let ext = sourceURL.pathExtension.lowercased()
                throw "Unsupported tweak format for '\(sourceName)'\(ext.isEmpty ? "" : " (.\(ext))")."
            case .dylib, .framework:
                let copiedURL = sourceStageDir.appendingPathComponent(sourceName, isDirectory: format == .framework)
                if fm.fileExists(atPath: copiedURL.path) {
                    try fm.removeItem(at: copiedURL)
                }
                try fm.copyItem(at: sourceURL, to: copiedURL)
                let kind: LCTweakPayloadKind = (format == .framework) ? .framework : .dylib
                collector.candidates.append(RawCandidate(
                    stagedURL: copiedURL,
                    fileName: sourceName,
                    relativeSourcePath: sourceName,
                    sourceArchiveChain: [],
                    kind: kind,
                    role: .tweak,
                    isSelectedByDefault: true,
                    filterBundles: []
                ))
            case .deb, .zip, .ipa, .tar:
                let stagedInputURL = sourceStageDir.appendingPathComponent(sourceName)
                if fm.fileExists(atPath: stagedInputURL.path) {
                    try fm.removeItem(at: stagedInputURL)
                }
                try fm.copyItem(at: sourceURL, to: stagedInputURL)

                let workRoot = sourceStageDir.appendingPathComponent("extract", isDirectory: true)
                try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
                try extractRecursiveArchive(
                    archiveURL: stagedInputURL,
                    archiveDisplayName: sourceName,
                    format: format,
                    workDir: workRoot,
                    archiveChain: [sourceName],
                    depth: 0,
                    fileManager: fm,
                    collector: &collector,
                    progressBase: 0.05 + progressBase * 0.65,
                    progressSpan: progressSpan,
                    progressHandler: progressHandler
                )
            }
        }

        guard !collector.candidates.isEmpty else {
            let reasonSuffix = collector.warnings.first.map { " (\($0))" } ?? ""
            throw "No .dylib or .framework payload found inside \(sourceNames.joined(separator: ", "))\(reasonSuffix)"
        }

        progressHandler?(LCTweakImportProgress(fraction: 0.72, status: "Analyzing Mach-O slices & dependencies…"))

        var siblingKeys = Set<String>()
        for candidate in collector.candidates {
            if candidate.kind == .dylib || candidate.kind == .framework {
                siblingKeys.insert(candidate.fileName)
            }
        }

        var existingNamesLower = Set<String>()
        if let destinationFolder,
           let destItems = try? fm.contentsOfDirectory(at: destinationFolder, includingPropertiesForKeys: nil) {
            for item in destItems {
                existingNamesLower.insert(item.lastPathComponent.lowercased())
            }
        }

        var resolvedPayloads: [LCTweakDiscoveredPayload] = []
        var seenFileNamesLower = Set<String>()
        var hasInternalDuplicateName = false

        for candidate in collector.candidates {
            try Task.checkCancellation()

            let report: LCTweakCompatibilityReport?
            switch candidate.kind {
            case .dylib, .framework:
                report = LCTweakMachOInspector.inspectBinary(at: candidate.stagedURL, siblingKeys: siblingKeys)
            case .resourceBundle:
                report = nil
            }

            let lowerName = candidate.fileName.lowercased()
            if !seenFileNamesLower.insert(lowerName).inserted {
                hasInternalDuplicateName = true
            }

            let isProtected = protectedTweakNames.contains(lowerName)
            let hasCollision = existingNamesLower.contains(lowerName)
            let defaultSelected: Bool = {
                if isProtected { return false }
                if !candidate.isSelectedByDefault { return false }
                if let report, !report.isMachOValid { return false }
                return true
            }()

            resolvedPayloads.append(LCTweakDiscoveredPayload(
                id: UUID(),
                stagedURL: candidate.stagedURL,
                fileName: candidate.fileName,
                relativeSourcePath: candidate.relativeSourcePath,
                sourceArchiveChain: candidate.sourceArchiveChain,
                kind: candidate.kind,
                role: candidate.role,
                fileSize: itemSize(at: candidate.stagedURL, fileManager: fm),
                compatibility: report,
                isSelectedByDefault: defaultSelected,
                isProtectedCollision: isProtected,
                existingCollisionName: hasCollision ? candidate.fileName : nil,
                filterBundleIdentifiers: candidate.filterBundles
            ))
        }

        let hasAnyIssues = !collector.warnings.isEmpty
            || resolvedPayloads.contains(where: { $0.hasCompatibilityIssue || $0.existingCollisionName != nil || $0.isProtectedCollision })
        let hasMixedRoles = resolvedPayloads.contains(where: { !$0.isSelectedByDefault && $0.role != .resource })
        let requiresReview = collector.containsIPAHarvest
            || hasAnyIssues
            || hasInternalDuplicateName
            || (resolvedPayloads.count > 1 && hasMixedRoles)

        let session = LCTweakInspectionSession(
            stagingRootURL: sessionRoot,
            sourceNames: sourceNames,
            sourceFormats: sourceFormats,
            payloads: resolvedPayloads,
            warnings: collector.warnings,
            containsIPAHarvest: collector.containsIPAHarvest,
            requiresReview: requiresReview
        )
        cleanupOnThrow = false
        return session
    }

    /// Lightweight unpacker for `LCTweakDependencyResolver` / `PackageEditor`,
    /// sharing the same hardened `.deb` / nested archive / `__MACOSX` / `.zst` handling.
    nonisolated static func unpackSimplePayloads(
        from sourceURL: URL,
        into workDir: URL,
        fileManager fm: FileManager = .default
    ) throws -> LCExtractedSimplePayloads {
        let format = LCTweakFormatDetector.detectFormat(at: sourceURL, fileManager: fm)
        let normalizedName = LCTweakFormatDetector.strippedDisabledSuffix(sourceURL.lastPathComponent)
        let stagedInput = workDir.appendingPathComponent(normalizedName, isDirectory: format == .framework)
        if sourceURL.standardizedFileURL != stagedInput.standardizedFileURL {
            if fm.fileExists(atPath: stagedInput.path) {
                try fm.removeItem(at: stagedInput)
            }
            try fm.copyItem(at: sourceURL, to: stagedInput)
        }

        switch format {
        case .dylib:
            return LCExtractedSimplePayloads(dylibs: [stagedInput], frameworks: [], resourceBundles: [])
        case .framework:
            return LCExtractedSimplePayloads(dylibs: [], frameworks: [stagedInput], resourceBundles: [])
        case .zstdUnsupported:
            throw "'\(sourceURL.lastPathComponent)' uses Zstandard (.zst) compression, which is not supported by iOS system libarchive."
        case .htmlErrorPage:
            throw "'\(sourceURL.lastPathComponent)' is an HTML page, not a valid tweak binary or archive."
        case .deb, .zip, .ipa, .tar:
            var collector = PayloadCollector()
            let extractRoot = workDir.appendingPathComponent("extract", isDirectory: true)
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
            try extractRecursiveArchive(
                archiveURL: stagedInput,
                archiveDisplayName: sourceURL.lastPathComponent,
                format: format,
                workDir: extractRoot,
                archiveChain: [sourceURL.lastPathComponent],
                depth: 0,
                fileManager: fm,
                collector: &collector,
                progressBase: 0,
                progressSpan: 1,
                progressHandler: nil
            )

            let dylibs = collector.candidates
                .filter { $0.kind == .dylib && $0.role == .tweak }
                .map(\.stagedURL)
            let frameworks = collector.candidates
                .filter { $0.kind == .framework && ($0.role == .tweak || $0.role == .appFramework) }
                .map(\.stagedURL)
            let bundles = collector.candidates
                .filter { $0.kind == .resourceBundle }
                .map(\.stagedURL)
            return LCExtractedSimplePayloads(dylibs: dylibs, frameworks: frameworks, resourceBundles: bundles)
        case .unknown:
            throw "Unsupported tweak format: \(sourceURL.lastPathComponent)"
        }
    }

    // MARK: - Recursive Archive Extraction

    private struct RawCandidate {
        let stagedURL: URL
        let fileName: String
        let relativeSourcePath: String
        let sourceArchiveChain: [String]
        let kind: LCTweakPayloadKind
        let role: LCTweakPayloadRole
        let isSelectedByDefault: Bool
        var filterBundles: [String]
    }

    private struct PayloadCollector {
        var candidates: [RawCandidate] = []
        var warnings: [String] = []
        var containsIPAHarvest: Bool = false
    }

    private nonisolated static func extractRecursiveArchive(
        archiveURL: URL,
        archiveDisplayName: String,
        format: LCTweakSourceFormat,
        workDir: URL,
        archiveChain: [String],
        depth: Int,
        fileManager fm: FileManager,
        collector: inout PayloadCollector,
        progressBase: Double,
        progressSpan: Double,
        progressHandler: (@Sendable (LCTweakImportProgress) -> Void)?
    ) throws {
        try Task.checkCancellation()
        guard depth <= maxArchiveDepth else {
            collector.warnings.append("Skipped nested archive '\(archiveDisplayName)' (exceeded max nesting depth \(maxArchiveDepth)).")
            return
        }

        let outerDir = workDir.appendingPathComponent("outer_\(depth)_\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: outerDir, withIntermediateDirectories: true)

        let outerProgress = Progress(totalUnitCount: 100)
        if let err = LCExtractArchiveAtPath(archiveURL.path, outerDir.path, debSafeOptions, outerProgress) {
            throw "Failed to extract '\(archiveDisplayName)': \(err)"
        }

        var searchRoot = outerDir
        var isDebTree = (format == .deb)

        if format == .deb {
            let outerItems = (try? fm.contentsOfDirectory(at: outerDir, includingPropertiesForKeys: nil)) ?? []
            guard let dataTar = outerItems.first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
                throw "'\(archiveDisplayName)' is not a valid Debian tweak package (missing data.tar payload)."
            }
            if LCTweakFormatDetector.isZstdCompressed(at: dataTar) {
                throw "'\(archiveDisplayName)' uses \(dataTar.lastPathComponent) (Zstandard), which iOS system libarchive cannot decompress. Repackage the .deb with gzip/xz or import the .dylib/.framework directly."
            }
            let innerDir = workDir.appendingPathComponent("data_\(depth)_\(UUID().uuidString.prefix(6))", isDirectory: true)
            try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
            let dataProgress = Progress(totalUnitCount: 100)
            if let dataErr = LCExtractArchiveAtPath(dataTar.path, innerDir.path, debSafeOptions, dataProgress) {
                throw "Failed to unpack \(dataTar.lastPathComponent) in '\(archiveDisplayName)': \(dataErr)"
            }
            searchRoot = innerDir
            isDebTree = true
        }

        progressHandler?(LCTweakImportProgress(
            fraction: min(0.68, progressBase + progressSpan * 0.7),
            status: "Scanning \(archiveDisplayName)…"
        ))

        // Detect an `.app` bundle under `Payload/` (supports both `.ipa`/`.tipa` and IPAs zipped as `.zip`).
        if let appBundleURL = findPayloadAppBundle(in: searchRoot, fileManager: fm) {
            collector.containsIPAHarvest = true
            try harvestPayloadsFromAppBundle(
                appBundleURL,
                archiveChain: archiveChain,
                fileManager: fm,
                collector: &collector
            )
            return
        }

        try scanExtractedDirectoryTree(
            rootURL: searchRoot,
            isDebTree: isDebTree,
            workDir: workDir,
            archiveChain: archiveChain,
            depth: depth,
            fileManager: fm,
            collector: &collector
        )
    }

    private nonisolated static func findPayloadAppBundle(in extractedRoot: URL, fileManager fm: FileManager) -> URL? {
        let payloadDir = extractedRoot.appendingPathComponent("Payload", isDirectory: true)
        guard fm.fileExists(atPath: payloadDir.path),
              let children = try? fm.contentsOfDirectory(
                at: payloadDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }
        return children.first { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && child.pathExtension.lowercased() == "app"
        }
    }

    /// Scans an extracted `.app` bundle (from `.ipa` / `.tipa` / zipped `.ipa`) and separates
    /// likely injected tweaks from embedded runtime/app frameworks.
    private nonisolated static func harvestPayloadsFromAppBundle(
        _ appBundleURL: URL,
        archiveChain: [String],
        fileManager fm: FileManager,
        collector: inout PayloadCollector
    ) throws {
        // Parse main executable load commands so injected frameworks/dylibs are highlighted cleanly.
        var injectedLoadTokens = Set<String>()
        if let mainExec = LCBoundedFileReader.resolveMachOExecutableURL(for: appBundleURL),
           let ctx = try? LCMachOParser.parseSliceContext(at: mainExec) {
            for dep in ctx.overview.dylibs where dep.kind != .id {
                let lower = dep.path.lowercased()
                if let fileComp = lower.split(separator: "/").last {
                    injectedLoadTokens.insert(String(fileComp))
                }
            }
        }

        let appPrefix = appBundleURL.path.hasSuffix("/") ? appBundleURL.path : appBundleURL.path + "/"
        guard let enumerator = fm.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        while let itemURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                continue
            }

            let name = itemURL.lastPathComponent
            let lowerName = name.lowercased()
            let isDir = values?.isDirectory ?? false

            if isDir && (name == "__MACOSX" || name == "_CodeSignature" || name == "SC_Info" || lowerName.hasSuffix(".lproj") || name == "PlugIns" || name == "Watch") {
                enumerator.skipDescendants()
                continue
            }

            let relPath = itemURL.path.hasPrefix(appPrefix) ? String(itemURL.path.dropFirst(appPrefix.count)) : name
            let lowerRel = relPath.lowercased()
            let ext = itemURL.pathExtension.lowercased()

            if isDir && ext == "framework" {
                enumerator.skipDescendants()
                if lowerName == "cydiasubstrate.framework" || lowerName == "substrate.framework" {
                    continue
                }
                let report = LCTweakMachOInspector.inspectBinary(at: itemURL)
                let looksInjected = report.needsSubstrate
                    || lowerRel.contains("tweaks/")
                    || lowerRel.contains("dylibs/")
                    || (injectedLoadTokens.contains(itemURL.deletingPathExtension().lastPathComponent.lowercased()) && report.needsSubstrate)

                collector.candidates.append(RawCandidate(
                    stagedURL: itemURL,
                    fileName: name,
                    relativeSourcePath: relPath,
                    sourceArchiveChain: archiveChain,
                    kind: .framework,
                    role: looksInjected ? .tweak : .appFramework,
                    isSelectedByDefault: looksInjected,
                    filterBundles: []
                ))
                continue
            }

            if !isDir && ext == "dylib" {
                if lowerName == "tweakloader.dylib" || lowerName == "libsubstrate.dylib" || lowerName == "libellekit.dylib" || lowerName == "libsubstitute.dylib" {
                    continue
                }
                let isRuntimeDylib = lowerName.hasPrefix("libswift") || lowerName.hasPrefix("libclang_rt")
                let inRootOrTweakDir = !relPath.contains("/") || lowerRel.hasPrefix("dylibs/") || lowerRel.hasPrefix("tweaks/")
                let isInjected = !isRuntimeDylib && (inRootOrTweakDir || injectedLoadTokens.contains(lowerName) || relPath.hasPrefix("Frameworks/"))
                collector.candidates.append(RawCandidate(
                    stagedURL: itemURL,
                    fileName: name,
                    relativeSourcePath: relPath,
                    sourceArchiveChain: archiveChain,
                    kind: .dylib,
                    role: isRuntimeDylib ? .appFramework : (isInjected ? .tweak : .appFramework),
                    isSelectedByDefault: isInjected && !isRuntimeDylib,
                    filterBundles: []
                ))
            }
        }
    }

    private nonisolated static func scanExtractedDirectoryTree(
        rootURL: URL,
        isDebTree: Bool,
        workDir: URL,
        archiveChain: [String],
        depth: Int,
        fileManager fm: FileManager,
        collector: inout PayloadCollector
    ) throws {
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // Map stemmed dylib name (lowercased) -> Filter.Bundles from Substrate filter plists.
        var filterMapByStem: [String: [String]] = [:]
        var stagedNestedArchives: [(url: URL, format: LCTweakSourceFormat)] = []
        var startIndex = collector.candidates.count

        while let itemURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                continue
            }

            let name = itemURL.lastPathComponent
            let lowerName = name.lowercased()
            let isDir = values?.isDirectory ?? false

            if name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._") {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            if isDebTree && name == "DEBIAN" && isDir {
                enumerator.skipDescendants()
                continue
            }

            let relPath = itemURL.path.hasPrefix(rootPrefix) ? String(itemURL.path.dropFirst(rootPrefix.count)) : name
            let lowerRel = relPath.lowercased()
            let ext = itemURL.pathExtension.lowercased()

            if isDir && ext == "framework" {
                enumerator.skipDescendants()
                if lowerName == "cydiasubstrate.framework" || lowerName == "substrate.framework" {
                    continue
                }
                let isPrefBundle = isDebTree && lowerRel.contains("preferencebundles/")
                collector.candidates.append(RawCandidate(
                    stagedURL: itemURL,
                    fileName: name,
                    relativeSourcePath: relPath,
                    sourceArchiveChain: archiveChain,
                    kind: .framework,
                    role: isPrefBundle ? .preferenceBundle : .tweak,
                    isSelectedByDefault: !isPrefBundle,
                    filterBundles: []
                ))
                continue
            }

            if isDir && ext == "bundle" {
                enumerator.skipDescendants()
                let isPrefBundle = isDebTree && lowerRel.contains("preferencebundles/")
                collector.candidates.append(RawCandidate(
                    stagedURL: itemURL,
                    fileName: name,
                    relativeSourcePath: relPath,
                    sourceArchiveChain: archiveChain,
                    kind: .resourceBundle,
                    role: isPrefBundle ? .preferenceBundle : .resource,
                    isSelectedByDefault: !isPrefBundle,
                    filterBundles: []
                ))
                continue
            }

            if !isDir && ext == "plist" && lowerRel.contains("dynamiclibraries/") {
                let stem = itemURL.deletingPathExtension().lastPathComponent.lowercased()
                if let bundles = parseSubstrateFilterBundles(at: itemURL), !bundles.isEmpty {
                    filterMapByStem[stem] = bundles
                }
                continue
            }

            if !isDir && ext == "dylib" {
                if lowerName == "libsubstrate.dylib" || lowerName == "libellekit.dylib" || lowerName == "libsubstitute.dylib" {
                    continue
                }
                let isPrefBundle = isDebTree && lowerRel.contains("preferencebundles/")
                collector.candidates.append(RawCandidate(
                    stagedURL: itemURL,
                    fileName: name,
                    relativeSourcePath: relPath,
                    sourceArchiveChain: archiveChain,
                    kind: .dylib,
                    role: isPrefBundle ? .preferenceBundle : .tweak,
                    isSelectedByDefault: !isPrefBundle && !protectedTweakNames.contains(lowerName),
                    filterBundles: []
                ))
                continue
            }

            if !isDir && LCTweakFormatDetector.isArchiveExtension(ext) {
                let nestedFormat = LCTweakFormatDetector.detectFormat(at: itemURL, fileManager: fm)
                if nestedFormat.isArchiveContainer {
                    stagedNestedArchives.append((itemURL, nestedFormat))
                } else if nestedFormat == .zstdUnsupported {
                    collector.warnings.append("Skipped nested '\(name)' (unsupported .zst compression).")
                }
            }
        }

        // Attach Substrate plist bundle filter hints to matching dylibs in this archive layer.
        if !filterMapByStem.isEmpty && startIndex < collector.candidates.count {
            for idx in startIndex..<collector.candidates.count {
                let stem = collector.candidates[idx].stagedURL.deletingPathExtension().lastPathComponent.lowercased()
                if let bundles = filterMapByStem[stem] {
                    collector.candidates[idx].filterBundles = bundles
                }
            }
        }

        // Recurse into any nested archives discovered inside this archive.
        for nested in stagedNestedArchives {
            try extractRecursiveArchive(
                archiveURL: nested.url,
                archiveDisplayName: nested.url.lastPathComponent,
                format: nested.format,
                workDir: workDir,
                archiveChain: archiveChain + [nested.url.lastPathComponent],
                depth: depth + 1,
                fileManager: fm,
                collector: &collector,
                progressBase: 0,
                progressSpan: 0,
                progressHandler: nil
            )
        }
    }

    private nonisolated static func parseSubstrateFilterBundles(at plistURL: URL) -> [String]? {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let filter = dict["Filter"] as? [String: Any],
              let bundles = filter["Bundles"] as? [String] else {
            return nil
        }
        return bundles
    }

    private nonisolated static func itemSize(at url: URL, fileManager fm: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory != true {
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
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

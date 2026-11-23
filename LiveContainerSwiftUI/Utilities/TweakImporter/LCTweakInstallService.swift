//
//  LCTweakInstallService.swift
//  LiveContainerSwiftUI
//
//  Off-main installation pipeline shared across manual tweak imports, URL downloads,
//  and installed-app binary extraction. Copies payloads safely, patches rpaths and
//  Substrate/sibling Mach-O load commands on both `.dylib` and `.framework` binaries,
//  signs with surfaced error diagnostics, and notifies listeners.
//

import Foundation

enum LCTweakInstallService {
    nonisolated static let tweaksNotificationName = Notification.Name("LC.TweakManagementDidChange")
    private nonisolated static let globalTweaksRPath = "@executable_path/../../Tweaks"
    private nonisolated static let loaderRPath = "@loader_path"

    /// Runs off-main inspection and staging of selected files/archives into a managed session.
    static func inspectSources(
        _ urls: [URL],
        destinationFolder: URL,
        displayNameOverrides: [URL: String] = [:],
        progressHandler: (@Sendable (LCTweakImportProgress) -> Void)? = nil
    ) async throws -> LCTweakInspectionSession {
        try await lcRunOffMain {
            try LCTweakArchiveUnpacker.inspectAndStageSources(
                urls,
                destinationFolder: destinationFolder,
                displayNameOverrides: displayNameOverrides,
                progressHandler: progressHandler
            )
        }
    }

    /// Installs user-selected payloads from `session` into `destinationFolder`, patches
    /// Mach-O rpaths and load paths across both `.dylib` and `.framework` binaries,
    /// codesigns via `LCUtils.signTweaks`, and posts `LC.TweakManagementDidChange`.
    static func installSelectedPayloads(
        from session: LCTweakInspectionSession,
        selectedIDs: Set<UUID>,
        destinationFolder: URL,
        conflictPolicy: LCTweakConflictPolicy = .overwrite,
        progressHandler: (@Sendable (LCTweakImportProgress) -> Void)? = nil
    ) async throws -> LCTweakImportResult {
        let selectedPayloads = session.payloads.filter { selectedIDs.contains($0.id) }
        guard !selectedPayloads.isEmpty else {
            throw "No tweak payloads were selected for installation."
        }

        let installOutcome = try await lcRunOffMain { () -> (installedURLs: [URL], installedNames: [String], skippedNames: [String], warnings: [String]) in
            let fm = FileManager.default
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

            var installedURLs: [URL] = []
            var installedNames: [String] = []
            var skippedNames: [String] = []
            var warnings: [String] = session.warnings

            let total = Double(max(selectedPayloads.count, 1))
            for (index, payload) in selectedPayloads.enumerated() {
                try Task.checkCancellation()
                progressHandler?(LCTweakImportProgress(
                    fraction: 0.10 + (Double(index) / total) * 0.45,
                    status: "Copying \(payload.fileName)…"
                ))

                if LCTweakArchiveUnpacker.protectedTweakNames.contains(payload.fileName.lowercased()) {
                    skippedNames.append(payload.fileName)
                    warnings.append("Skipped protected LiveContainer system file '\(payload.fileName)'.")
                    continue
                }

                let proposedURL = destinationFolder.appendingPathComponent(
                    payload.fileName,
                    isDirectory: payload.kind != .dylib
                )
                guard let resolvedDestURL = resolveDestinationURL(
                    proposedURL: proposedURL,
                    isDirectory: payload.kind != .dylib,
                    policy: conflictPolicy,
                    fileManager: fm
                ) else {
                    skippedNames.append(payload.fileName)
                    continue
                }

                if fm.fileExists(atPath: resolvedDestURL.path) {
                    try fm.removeItem(at: resolvedDestURL)
                }
                try fm.copyItem(at: payload.stagedURL, to: resolvedDestURL)

                if payload.kind == .dylib || payload.kind == .framework {
                    installedURLs.append(resolvedDestURL)
                }
                installedNames.append(resolvedDestURL.lastPathComponent)
            }

            if !installedURLs.isEmpty {
                progressHandler?(LCTweakImportProgress(
                    fraction: 0.62,
                    status: "Patching Mach-O rpaths & dependencies…"
                ))
                let patchWarnings = try patchInstalledMachOs(at: installedURLs)
                warnings.append(contentsOf: patchWarnings)
            }

            return (installedURLs, installedNames, skippedNames, warnings)
        }

        var signingWarning: String?
        if !installOutcome.installedURLs.isEmpty {
            progressHandler?(LCTweakImportProgress(fraction: 0.82, status: "Code signing tweaks…"))
            do {
                try await LCUtils.signTweaks(tweakFolderUrl: destinationFolder, force: false) { _ in }
            } catch {
                signingWarning = "Tweaks were imported, but code signing failed: \(error.localizedDescription)"
            }
        }

        progressHandler?(LCTweakImportProgress(fraction: 1.0, status: "Done"))
        await MainActor.run {
            NotificationCenter.default.post(name: tweaksNotificationName, object: nil)
        }

        return LCTweakImportResult(
            installedNames: installOutcome.installedNames,
            skippedNames: installOutcome.skippedNames,
            warnings: installOutcome.warnings,
            signingWarning: signingWarning
        )
    }

    /// Automatic end-to-end installer used for URL-downloaded tweak archives/binaries.
    static func installDownloadedTweak(
        at localFileURL: URL,
        resolvedFileName: String,
        destinationFolder: URL,
        progressHandler: (@Sendable (LCTweakImportProgress) -> Void)? = nil
    ) async throws -> LCTweakImportResult {
        let session = try await inspectSources(
            [localFileURL],
            destinationFolder: destinationFolder,
            displayNameOverrides: [localFileURL: resolvedFileName],
            progressHandler: { prog in
                progressHandler?(LCTweakImportProgress(fraction: prog.fraction * 0.50, status: prog.status))
            }
        )
        defer { session.cleanup() }

        var chosenIDs = session.defaultSelectedIDs
        if chosenIDs.isEmpty {
            chosenIDs = Set(
                session.payloads
                    .filter { !$0.isProtectedCollision && ($0.kind == .dylib || $0.kind == .framework) && ($0.compatibility?.isMachOValid ?? true) }
                    .map(\.id)
            )
        }
        guard !chosenIDs.isEmpty else {
            throw session.warnings.first ?? "No installable .dylib or .framework found inside \(resolvedFileName)."
        }

        return try await installSelectedPayloads(
            from: session,
            selectedIDs: chosenIDs,
            destinationFolder: destinationFolder,
            conflictPolicy: .overwrite,
            progressHandler: { prog in
                progressHandler?(LCTweakImportProgress(fraction: 0.50 + prog.fraction * 0.50, status: prog.status))
            }
        )
    }

    /// Patches, codesigns, and publishes binaries copied from an installed app into Tweaks.
    static func patchAndSignCopiedTweaks(
        at copiedURLs: [URL],
        in destinationFolder: URL
    ) async throws -> [String] {
        let warnings = try await lcRunOffMain {
            try patchInstalledMachOs(at: copiedURLs)
        }
        try await LCUtils.signTweaks(tweakFolderUrl: destinationFolder, force: false) { _ in }
        await MainActor.run {
            NotificationCenter.default.post(name: tweaksNotificationName, object: nil)
        }
        return warnings
    }

    // MARK: - Mach-O Patching Helpers

    private nonisolated static func resolveDestinationURL(
        proposedURL: URL,
        isDirectory: Bool,
        policy: LCTweakConflictPolicy,
        fileManager fm: FileManager
    ) -> URL? {
        guard fm.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }
        switch policy {
        case .overwrite:
            return proposedURL
        case .skip:
            return nil
        case .keepBoth:
            let ext = proposedURL.pathExtension
            let base = proposedURL.deletingPathExtension().lastPathComponent
            let parent = proposedURL.deletingLastPathComponent()
            var index = 2
            while true {
                let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
                let candidateURL = parent.appendingPathComponent(candidateName, isDirectory: isDirectory)
                if !fm.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
                index += 1
            }
        }
    }

    /// Ensures coherent rpaths, Substrate alias remaps, sibling load path rewrites,
    /// and `@rpath` install IDs across every installed `.dylib` and `.framework` executable.
    private nonisolated static func patchInstalledMachOs(at installedURLs: [URL]) throws -> [String] {
        var warnings: [String] = []

        // Build lookup table for sibling dylibs/frameworks installed alongside each other.
        var siblingRemapsByComponent: [String: String] = [:]
        var targetEntries: [(bundleOrFileURL: URL, execURL: URL, installID: String)] = []

        for url in installedURLs {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            if ext == "framework" {
                guard let execURL = LCBoundedFileReader.resolveMachOExecutableURL(for: url) else {
                    warnings.append("Framework '\(url.lastPathComponent)' has no readable executable.")
                    continue
                }
                let loaderTarget = "@loader_path/\(url.lastPathComponent)/\(execURL.lastPathComponent)"
                siblingRemapsByComponent[url.lastPathComponent] = loaderTarget
                let id = "@rpath/\(url.lastPathComponent)/\(execURL.lastPathComponent)"
                targetEntries.append((url, execURL, id))
            } else if ext == "dylib" {
                let fileName = url.lastPathComponent
                siblingRemapsByComponent[fileName] = "@loader_path/\(fileName)"
                let id = "@rpath/\(fileName)"
                targetEntries.append((url, url, id))
            }
        }

        for entry in targetEntries {
            try Task.checkCancellation()
            let path = entry.execURL.path
            guard LCBoundedFileReader.isMachOFile(at: entry.execURL) else {
                continue
            }

            if let err = LCMachOEnsureRPathAtPath(path, globalTweaksRPath) {
                warnings.append("rpath patch warning on \(entry.execURL.lastPathComponent): \(err)")
            }
            if let err = LCMachOEnsureRPathAtPath(path, loaderRPath) {
                warnings.append("@loader_path warning on \(entry.execURL.lastPathComponent): \(err)")
            }

            if let ctx = try? LCMachOParser.parseSliceContext(at: entry.execURL) {
                for dep in ctx.overview.dylibs {
                    if dep.kind == .id {
                        if dep.path.hasPrefix("/Library/") || dep.path.hasPrefix("/var/jb/") || dep.path.hasPrefix("/usr/") {
                            _ = LCMachOSetDylibIDAtPath(path, entry.installID)
                        }
                        continue
                    }

                    if LCTweakMachOInspector.isSubstrateAlias(dep.path) {
                        if dep.path != LCTweakMachOInspector.canonicalSubstrateLoadPath,
                           let err = LCMachOChangeDylibPathAtPath(path, dep.path, LCTweakMachOInspector.canonicalSubstrateLoadPath) {
                            warnings.append("Substrate remap failed on \(entry.execURL.lastPathComponent): \(err)")
                        }
                        continue
                    }

                    if let siblingNewPath = matchedSiblingTarget(depPath: dep.path, table: siblingRemapsByComponent),
                       siblingNewPath != dep.path {
                        _ = LCMachOChangeDylibPathAtPath(path, dep.path, siblingNewPath)
                    }
                }
            }
        }

        return warnings
    }

    private nonisolated static func matchedSiblingTarget(depPath: String, table: [String: String]) -> String? {
        let components = depPath.split(separator: "/").map(String.init)
        for (key, target) in table {
            if components.contains(key) {
                return target
            }
        }
        return nil
    }
}

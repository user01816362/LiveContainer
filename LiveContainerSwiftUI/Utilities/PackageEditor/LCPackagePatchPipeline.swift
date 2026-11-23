//
//  LCPackagePatchPipeline.swift
//  LiveContainerSwiftUI
//

import Foundation

/// Executes staged `.app` modifications off the main actor: component/framework removal,
/// `.deb`/`.dylib`/`.framework` injection with Substrate/ElleKit/sibling remapping,
/// metadata/plist updates, LiveContainer unpatching, code-signature stripping, and IPA zipping.
enum LCPackagePatchPipeline {
    private nonisolated static let liveContainerTweaksRPath = "@executable_path/../../Tweaks"

    static func applyEdits(
        plan: LCPackageEditPlan,
        to stagedAppURL: URL,
        progress: (@Sendable (LCPackageProgress) -> Void)? = nil
    ) async throws {
        try await lcRunOffMain {
            let fm = FileManager.default
            guard fm.fileExists(atPath: stagedAppURL.path) else {
                throw "The staged app session directory no longer exists on disk."
            }
            guard let mainExecURL = LCBoundedFileReader.resolveMachOExecutableURL(for: stagedAppURL) else {
                throw "Unable to locate the main executable inside \(stagedAppURL.lastPathComponent)."
            }

            if plan.mode == .standaloneExport {
                progress?(LCPackageProgress(fraction: 0.08, stage: "Sanitizing LiveContainer patches…"))
                try lcSanitizeStagedAppBundle(at: stagedAppURL, unpatchExecutables: true, fileManager: fm)
            }

            // Step 1: Remove disabled Frameworks, Dylibs, PlugIns, Watch apps & their Mach-O load commands
            progress?(LCPackageProgress(fraction: 0.22, stage: "Removing disabled components…"))
            try removeDisabledComponents(
                plan: plan,
                stagedAppURL: stagedAppURL,
                mainExecURL: mainExecURL,
                fileManager: fm
            )

            // Step 2: Unpack, embed, remap, and inject queued tweaks
            if !plan.queuedTweaks.isEmpty {
                progress?(LCPackageProgress(fraction: 0.48, stage: "Injecting tweaks & dependencies…"))
                try injectQueuedTweaks(
                    plan: plan,
                    stagedAppURL: stagedAppURL,
                    mainExecURL: mainExecURL,
                    fileManager: fm
                )
            }

            // Step 3: Apply metadata & Info.plist edits cleanly
            progress?(LCPackageProgress(fraction: 0.72, stage: "Updating Info.plist & metadata…"))
            try applyMetadataEdits(
                plan.metadata,
                to: stagedAppURL,
                fileManager: fm
            )

            // Step 4: Standalone unsigned hygiene (strip signatures, provisioning, Watch placeholders)
            if plan.mode == .standaloneExport {
                progress?(LCPackageProgress(fraction: 0.85, stage: "Stripping old signatures…"))
                try stripSignaturesForStandaloneExport(
                    at: stagedAppURL,
                    mainExecURL: mainExecURL,
                    fileManager: fm
                )
                LCPatchAppBundleFixupARM64eSlice(stagedAppURL)
            }

            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecURL.path)
            progress?(LCPackageProgress(fraction: 0.92, stage: "Finalizing bundle…"))
        }
    }

    static func packageStandaloneIPA(
        stagedAppURL: URL,
        outputFileName: String
    ) async throws -> URL {
        try await lcRunOffMain {
            let fm = FileManager.default
            let baseDir = try lcEnsureExportArtifactDirectory(fileManager: fm)
            let scopedDir = baseDir.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: scopedDir, withIntermediateDirectories: true)

            let cleanFileName = LCPackageStagingManager.sanitizedStem(outputFileName.replacingOccurrences(of: ".ipa", with: "")) + ".ipa"
            let exportURL = scopedDir.appendingPathComponent(cleanFileName)
            let appFolderName = stagedAppURL.lastPathComponent

            let mappings: [[String: Any]] = [[
                "sourcePath": stagedAppURL.path,
                "archivePrefix": "Payload/\(appFolderName)",
                "skipSymlinks": false
            ]]
            if let archiveError = LCCreateZipArchive(exportURL.path, mappings) {
                try? fm.removeItem(at: scopedDir)
                throw archiveError
            }
            return exportURL
        }
    }

    // MARK: - Component Removal

    private nonisolated static func removeDisabledComponents(
        plan: LCPackageEditPlan,
        stagedAppURL: URL,
        mainExecURL: URL,
        fileManager fm: FileManager
    ) throws {
        guard !plan.removedComponentIDs.isEmpty else { return }

        var loadCommandsToStrip: [String] = []
        for component in plan.allComponents where plan.removedComponentIDs.contains(component.id) {
            if let relPath = component.bundleRelativePath, !relPath.isEmpty {
                let targetURL = stagedAppURL.appendingPathComponent(relPath)
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
            }
            if let primary = component.loadCommandPath {
                loadCommandsToStrip.append(primary)
            }
            loadCommandsToStrip.append(contentsOf: component.loadCommandAliases)
        }

        let uniquePaths = Array(Set(loadCommandsToStrip))
        if !uniquePaths.isEmpty {
            if let err = LCMachORemoveDylibsAtPath(mainExecURL.path, uniquePaths) {
                throw err
            }
        }
    }

    // MARK: - Tweak Unpack, Remap & Injection

    private nonisolated static func injectQueuedTweaks(
        plan: LCPackageEditPlan,
        stagedAppURL: URL,
        mainExecURL: URL,
        fileManager fm: FileManager
    ) throws {
        let frameworksDir = stagedAppURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        let unpackWorkRoot = fm.temporaryDirectory.appendingPathComponent("LCTweakWork-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unpackWorkRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: unpackWorkRoot) }

        struct EmbeddedBinary {
            let binaryURL: URL
            let injectLoadPath: String
            let installNameID: String
            let weakLink: Bool
            let injectIntoExtensions: Bool
        }

        var embeddedBinaries: [EmbeddedBinary] = []
        var embeddedDylibNames = Set<String>()
        var embeddedFrameworkMap: [String: String] = [:] // "Foo.framework" -> "@rpath/Foo.framework/Foo"
        var needsSubstrateFramework = false

        for (index, tweak) in plan.queuedTweaks.enumerated() {
            let needsScope = tweak.sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsScope {
                    tweak.sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let perTweakDir = unpackWorkRoot.appendingPathComponent("tweak_\(index)", isDirectory: true)
            try fm.createDirectory(at: perTweakDir, withIntermediateDirectories: true)
            let payloads = try LCTweakDependencyResolver.unpackTweakSynchronously(
                from: tweak.sourceURL,
                kind: tweak.kind,
                into: perTweakDir,
                fileManager: fm
            )

            if tweak.needsElleKit {
                needsSubstrateFramework = true
            }

            for bundleURL in payloads.resourceBundles {
                let destBundleURL = stagedAppURL.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: destBundleURL.path) {
                    try fm.removeItem(at: destBundleURL)
                }
                try fm.copyItem(at: bundleURL, to: destBundleURL)
            }

            for dylibURL in payloads.dylibs {
                let fileName = LCTweakFormatDetector.strippedDisabledSuffix(dylibURL.lastPathComponent)
                let destURL = frameworksDir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: dylibURL, to: destURL)
                let rpathRef = "@rpath/\(fileName)"
                embeddedDylibNames.insert(fileName)
                embeddedBinaries.append(EmbeddedBinary(
                    binaryURL: destURL,
                    injectLoadPath: rpathRef,
                    installNameID: rpathRef,
                    weakLink: tweak.weakLink,
                    injectIntoExtensions: tweak.injectIntoExtensions
                ))
            }

            for fwURL in payloads.frameworks {
                let fwName = LCTweakFormatDetector.strippedDisabledSuffix(fwURL.lastPathComponent)
                let destFWURL = frameworksDir.appendingPathComponent(fwName, isDirectory: true)
                if fm.fileExists(atPath: destFWURL.path) {
                    try fm.removeItem(at: destFWURL)
                }
                try fm.copyItem(at: fwURL, to: destFWURL)
                if let fwExecURL = LCBoundedFileReader.resolveMachOExecutableURL(for: destFWURL) {
                    let rpathRef = "@rpath/\(fwName)/\(fwExecURL.lastPathComponent)"
                    embeddedFrameworkMap[fwName] = rpathRef
                    embeddedBinaries.append(EmbeddedBinary(
                        binaryURL: fwExecURL,
                        injectLoadPath: rpathRef,
                        installNameID: rpathRef,
                        weakLink: tweak.weakLink,
                        injectIntoExtensions: tweak.injectIntoExtensions
                    ))
                }
            }
        }

        // Also include existing Frameworks inside `<App>.app/Frameworks/` in our sibling remap lookup.
        if let existingFWs = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for itemURL in existingFWs {
                let ext = itemURL.pathExtension.lowercased()
                if ext == "framework", let exec = LCBoundedFileReader.resolveMachOExecutableURL(for: itemURL) {
                    embeddedFrameworkMap[itemURL.lastPathComponent] = "@rpath/\(itemURL.lastPathComponent)/\(exec.lastPathComponent)"
                } else if ext == "dylib" {
                    embeddedDylibNames.insert(itemURL.lastPathComponent)
                }
            }
        }

        // Auto-embed bundled ElleKit (`CydiaSubstrate.framework`) whenever any injected tweak links Substrate/ElleKit.
        let destSubstrateURL = frameworksDir.appendingPathComponent("CydiaSubstrate.framework", isDirectory: true)
        if needsSubstrateFramework && !fm.fileExists(atPath: destSubstrateURL.path) {
            let hostSubstrateURL = Bundle.main.bundleURL
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent("CydiaSubstrate.framework", isDirectory: true)
            guard fm.fileExists(atPath: hostSubstrateURL.path) else {
                throw "Bundled CydiaSubstrate.framework (ElleKit) could not be found in LiveContainer."
            }
            try fm.copyItem(at: hostSubstrateURL, to: destSubstrateURL)
            if let substrateExec = LCBoundedFileReader.resolveMachOExecutableURL(for: destSubstrateURL) {
                if let err = LCMachORemoveRPathAtPath(substrateExec.path, liveContainerTweaksRPath) {
                    throw err
                }
                if let err = LCMachOStripCodeSignatureAtPath(substrateExec.path) {
                    throw err
                }
                if let err = LCPatchMachOFixupARM64eSlice(substrateExec.path) {
                    throw err
                }
            }
        }

        // Clean & remap every embedded tweak dylib/framework binary.
        for item in embeddedBinaries {
            if let err = LCMachORemoveRPathAtPath(item.binaryURL.path, liveContainerTweaksRPath) {
                throw err
            }
            if let err = LCMachOSetDylibIDAtPath(item.binaryURL.path, item.installNameID) {
                throw err
            }

            if let ctx = try? LCMachOParser.parseSliceContext(at: item.binaryURL) {
                for dep in ctx.overview.dylibs where dep.kind != .id {
                    let oldPath = dep.path
                    var replacementPath: String? = nil

                    if LCTweakDependencyResolver.isSubstrateAlias(oldPath) {
                        replacementPath = LCTweakDependencyResolver.canonicalSubstrateLoadPath
                    } else if let fwFolder = oldPath.split(separator: "/").first(where: { $0.hasSuffix(".framework") }),
                              let mappedFW = embeddedFrameworkMap[String(fwFolder)] {
                        replacementPath = mappedFW
                    } else {
                        let base = (oldPath as NSString).lastPathComponent
                        if embeddedDylibNames.contains(base) && oldPath != "@rpath/\(base)" {
                            replacementPath = "@rpath/\(base)"
                        }
                    }

                    if let newPath = replacementPath, newPath != oldPath {
                        if let err = LCMachOChangeDylibPathAtPath(item.binaryURL.path, oldPath, newPath) {
                            throw err
                        }
                    }
                }
            }

            if let err = LCMachOStripCodeSignatureAtPath(item.binaryURL.path) {
                throw err
            }
            if let err = LCPatchMachOFixupARM64eSlice(item.binaryURL.path) {
                throw err
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.binaryURL.path)
        }

        // Strip code signature on mainExec before injecting so load-command header headroom is maximized.
        if let err = LCMachOStripCodeSignatureAtPath(mainExecURL.path) {
            throw err
        }

        if let err = LCMachOEnsureRPathAtPath(mainExecURL.path, "@executable_path/Frameworks") {
            throw err
        }

        // Only inject top-level libraries? Wait: inject all dylibs/frameworks requested by the queued tweak
        // (skipping helper frameworks if another binary in the same tweak links them is ideal, or inject safely;
        // deduplication makes repeated injects safe, and we avoid double-injecting sibling support frameworks that are already linked by the tweak itself).
        var siblingLinkedSet = Set<String>()
        for item in embeddedBinaries {
            if let ctx = try? LCMachOParser.parseSliceContext(at: item.binaryURL) {
                for dep in ctx.overview.dylibs where dep.kind != .id {
                    siblingLinkedSet.insert(dep.path)
                }
            }
        }

        var extensionExecURLs: [URL] = []
        let plugInsURL = stagedAppURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let appexDirs = try? fm.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for appex in appexDirs where appex.pathExtension.lowercased() == "appex" {
                if let extExec = LCBoundedFileReader.resolveMachOExecutableURL(for: appex) {
                    extensionExecURLs.append(extExec)
                }
            }
        }

        for item in embeddedBinaries {
            // Skip directly injecting a supporting framework (like Orion.framework) into the main executable if
            // another injected tweak already links it cleanly via `@rpath/...`.
            let isSupportingFramework = item.binaryURL.deletingLastPathComponent().pathExtension.lowercased() == "framework"
                && siblingLinkedSet.contains(item.injectLoadPath)
            if isSupportingFramework {
                continue
            }

            if let err = LCMachOInjectDylibAtPath(mainExecURL.path, item.injectLoadPath, item.weakLink) {
                throw err
            }

            if item.injectIntoExtensions {
                for extExec in extensionExecURLs {
                    _ = LCMachOStripCodeSignatureAtPath(extExec.path)
                    if let rpathErr = LCMachOEnsureRPathAtPath(extExec.path, "@executable_path/../../Frameworks") {
                        throw rpathErr
                    }
                    if let injErr = LCMachOInjectDylibAtPath(extExec.path, item.injectLoadPath, item.weakLink) {
                        throw injErr
                    }
                }
            }
        }
    }

    // MARK: - Metadata & Info.plist Edits

    private nonisolated static func applyMetadataEdits(
        _ metadata: LCPackageMetadataDraft,
        to stagedAppURL: URL,
        fileManager fm: FileManager
    ) throws {
        let infoPlistURL = stagedAppURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL) else {
            throw "Unable to read Info.plist."
        }
        var format: PropertyListSerialization.PropertyListFormat = .binary
        guard var plist = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw "Unable to parse Info.plist."
        }

        let trimmedDisplayName = metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleName = metadata.bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleId = metadata.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShortVer = metadata.shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuildVer = metadata.buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMinOS = metadata.minimumOSVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedBundleId.isEmpty {
            throw "Bundle Identifier cannot be empty."
        }
        if trimmedDisplayName.isEmpty && trimmedBundleName.isEmpty {
            throw "App Name cannot be empty."
        }

        if metadata.displayName != metadata.originalDisplayName || plist["CFBundleDisplayName"] != nil {
            if !trimmedDisplayName.isEmpty {
                plist["CFBundleDisplayName"] = trimmedDisplayName
            } else {
                plist.removeValue(forKey: "CFBundleDisplayName")
            }
        }
        if !trimmedBundleName.isEmpty {
            plist["CFBundleName"] = trimmedBundleName
        } else if !trimmedDisplayName.isEmpty {
            plist["CFBundleName"] = trimmedDisplayName
        }
        plist["CFBundleIdentifier"] = trimmedBundleId

        if !trimmedShortVer.isEmpty {
            plist["CFBundleShortVersionString"] = trimmedShortVer
        }
        if !trimmedBuildVer.isEmpty {
            plist["CFBundleVersion"] = trimmedBuildVer
        }
        if !trimmedMinOS.isEmpty {
            plist["MinimumOSVersion"] = trimmedMinOS
        }

        if metadata.removeSupportedDevices {
            plist.removeValue(forKey: "UISupportedDevices")
        }
        if metadata.enableFileSharing {
            plist["UIFileSharingEnabled"] = true
            plist["LSSupportsOpeningDocumentsInPlace"] = true
        } else if metadata.hasFileSharingEnabled {
            plist.removeValue(forKey: "UIFileSharingEnabled")
            plist.removeValue(forKey: "LSSupportsOpeningDocumentsInPlace")
        }
        if metadata.removeURLSchemes {
            plist.removeValue(forKey: "CFBundleURLTypes")
        }

        let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .xml) ? .xml : .binary
        let updatedData = try PropertyListSerialization.data(fromPropertyList: plist, format: writeFormat, options: 0)
        try updatedData.write(to: infoPlistURL, options: .atomic)

        if metadata.updateLocalizedNames &&
            (metadata.displayName != metadata.originalDisplayName || metadata.bundleName != metadata.originalBundleName) {
            updateLocalizedInfoPlistStrings(
                at: stagedAppURL,
                displayName: trimmedDisplayName.isEmpty ? trimmedBundleName : trimmedDisplayName,
                bundleName: trimmedBundleName.isEmpty ? trimmedDisplayName : trimmedBundleName,
                fileManager: fm
            )
        }

        if metadata.updateExtensionBundleIds &&
            !metadata.originalBundleIdentifier.isEmpty &&
            trimmedBundleId != metadata.originalBundleIdentifier {
            updateNestedBundleIdentifiers(
                at: stagedAppURL,
                oldBundleId: metadata.originalBundleIdentifier,
                newBundleId: trimmedBundleId,
                fileManager: fm
            )
        }
    }

    private nonisolated static func updateLocalizedInfoPlistStrings(
        at bundleURL: URL,
        displayName: String,
        bundleName: String,
        fileManager fm: FileManager
    ) {
        let items = (try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil, options: [])) ?? []
        for lproj in items where lproj.pathExtension.lowercased() == "lproj" {
            let stringsURL = lproj.appendingPathComponent("InfoPlist.strings")
            guard fm.fileExists(atPath: stringsURL.path),
                  let rawData = try? Data(contentsOf: stringsURL) else {
                continue
            }
            var format: PropertyListSerialization.PropertyListFormat = .binary
            guard var dict = try? PropertyListSerialization.propertyList(from: rawData, format: &format) as? [String: Any] else {
                continue
            }
            var changed = false
            if dict["CFBundleDisplayName"] != nil && !displayName.isEmpty {
                dict["CFBundleDisplayName"] = displayName
                changed = true
            }
            if dict["CFBundleName"] != nil && !bundleName.isEmpty {
                dict["CFBundleName"] = bundleName
                changed = true
            }
            if changed {
                let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .xml) ? .xml : .binary
                if let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: writeFormat, options: 0) {
                    try? out.write(to: stringsURL, options: .atomic)
                }
            }
        }
    }

    private nonisolated static func updateNestedBundleIdentifiers(
        at stagedAppURL: URL,
        oldBundleId: String,
        newBundleId: String,
        fileManager fm: FileManager
    ) {
        for subDirName in ["PlugIns", "Watch"] {
            let dirURL = stagedAppURL.appendingPathComponent(subDirName, isDirectory: true)
            let nested = (try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for childBundle in nested {
                let infoURL = childBundle.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: infoURL) else { continue }
                var format: PropertyListSerialization.PropertyListFormat = .binary
                guard var dict = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
                    continue
                }
                var changed = false
                if let childID = dict["CFBundleIdentifier"] as? String {
                    if childID == oldBundleId {
                        dict["CFBundleIdentifier"] = newBundleId
                        changed = true
                    } else if childID.hasPrefix(oldBundleId + ".") {
                        let suffix = String(childID.dropFirst(oldBundleId.count))
                        dict["CFBundleIdentifier"] = newBundleId + suffix
                        changed = true
                    }
                }
                if let companionID = dict["WKCompanionAppBundleIdentifier"] as? String, companionID == oldBundleId {
                    dict["WKCompanionAppBundleIdentifier"] = newBundleId
                    changed = true
                }
                if let watchAppID = dict["WKAppBundleIdentifier"] as? String {
                    if watchAppID == oldBundleId {
                        dict["WKAppBundleIdentifier"] = newBundleId
                        changed = true
                    } else if watchAppID.hasPrefix(oldBundleId + ".") {
                        let suffix = String(watchAppID.dropFirst(oldBundleId.count))
                        dict["WKAppBundleIdentifier"] = newBundleId + suffix
                        changed = true
                    }
                }
                if changed {
                    let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .xml) ? .xml : .binary
                    if let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: writeFormat, options: 0) {
                        try? out.write(to: infoURL, options: .atomic)
                    }
                }
            }
        }
    }

    // MARK: - Standalone Unsigned Hygiene

    private nonisolated static func stripSignaturesForStandaloneExport(
        at stagedAppURL: URL,
        mainExecURL: URL,
        fileManager fm: FileManager
    ) throws {
        // Strip legacy DRM SC_Info only when the binary is verified decrypted (cryptid == 0).
        let isDecrypted: Bool = {
            guard let ctx = try? LCMachOParser.parseSliceContext(at: mainExecURL) else { return false }
            return !ctx.overview.header.isEncrypted
        }()

        // Recursively remove all `_CodeSignature`, `embedded.mobileprovision`, `com.apple.WatchPlaceholder`, and `SignedBy*` markers.
        if let enumerator = fm.enumerator(
            at: stagedAppURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            var urlsToDelete: [URL] = []
            for case let itemURL as URL in enumerator {
                let name = itemURL.lastPathComponent
                if name == "_CodeSignature" ||
                    name == "embedded.mobileprovision" ||
                    name == "com.apple.WatchPlaceholder" ||
                    name.hasPrefix("SignedBy") ||
                    (isDecrypted && name == "SC_Info") {
                    urlsToDelete.append(itemURL)
                    enumerator.skipDescendants()
                }
            }
            for delURL in urlsToDelete {
                try? fm.removeItem(at: delURL)
            }
        }

        // Strip `LC_CODE_SIGNATURE` load commands from every Mach-O target in the staged bundle.
        let targets = LCMachOParser.listBundleTargets(bundleURL: stagedAppURL)
        for target in targets {
            _ = LCMachOStripCodeSignatureAtPath(target.executableURL.path)
        }
    }
}

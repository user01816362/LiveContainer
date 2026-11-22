//
//  LCAppBannerExportActions.swift
//  LiveContainerSwiftUI
//

import Foundation
import SwiftUI
import UIKit

extension LCAppBannerViewController {
    func cloneApp() async {
        do {
            let clonedAppModel = try await createClonedAppModel()
            await MainActor.run {
                DataManager.shared.model.apps.append(clonedAppModel)
                showExportSuccess("Cloned app created.")
            }
        } catch {
            await MainActor.run {
                showError(error.localizedDescription)
            }
        }
    }

    private func createClonedAppModel() async throws -> LCAppModel {
        let appInfo = configuration.model.appInfo
        guard let sourceBundlePath = appInfo.bundlePath() else {
            throw "Unable to read app bundle path."
        }

        let isShared = configuration.model.uiIsShared
        let sourceBundleURL = URL(fileURLWithPath: sourceBundlePath, isDirectory: true)
        let targetRootURL = isShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        let stemSource = (appInfo.bundleIdentifier() ?? appInfo.displayName() ?? "ClonedApp").sanitizeNonACSII()

        let (cloneRelativeBundlePath, destinationBundleURL) = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

            let cloneRelativeBundlePath = Self.makeCloneRelativeBundlePath(
                stemSource: stemSource,
                targetRootURL: targetRootURL,
                fileManager: fm
            )
            let destinationBundleURL = targetRootURL.appendingPathComponent(cloneRelativeBundlePath, isDirectory: true)

            do {
                try fm.copyItem(at: sourceBundleURL, to: destinationBundleURL)
            } catch {
                throw "Failed to copy app bundle: \(error.localizedDescription)"
            }

            do {
                try Self.resetClonedAppInfo(at: destinationBundleURL, fileManager: fm)
            } catch {
                try? fm.removeItem(at: destinationBundleURL)
                throw error
            }
            return (cloneRelativeBundlePath, destinationBundleURL)
        }.value

        do {
            guard let clonedAppInfo = LCAppInfo(bundlePath: destinationBundleURL.path) else {
                throw "Failed to initialize cloned app."
            }
            clonedAppInfo.relativeBundlePath = cloneRelativeBundlePath
            clonedAppInfo.isShared = isShared
            clonedAppInfo.spoofSDKVersion = true
            clonedAppInfo.installationDate = Date.now
            try await signClonedAppIfNeeded(clonedAppInfo)
            if !clonedAppInfo.is32bit,
               let bundleId = clonedAppInfo.bundleIdentifier(), !bundleId.isEmpty {
                let folderName = UUID().uuidString
                let initialContainer = LCContainer.makeNewContainer(
                    folderName: folderName,
                    name: folderName,
                    isShared: isShared
                )
                initialContainer.makeLCContainerInfoPlist(
                    appIdentifier: bundleId,
                    keychainGroupId: LCContainer.allocateKeychainGroupId()
                )
                clonedAppInfo.containers = [initialContainer]
                clonedAppInfo.dataUUID = folderName
                clonedAppInfo.save()
            }
            return LCAppModel(appInfo: clonedAppInfo, delegate: configuration.model.delegate)
        } catch {
            try? FileManager.default.removeItem(at: destinationBundleURL)
            throw error
        }
    }

    nonisolated private static func makeCloneRelativeBundlePath(stemSource: String, targetRootURL: URL, fileManager: FileManager) -> String {
        let stem = stemSource.isEmpty ? "ClonedApp" : stemSource
        let timestamp = Int(Date().timeIntervalSince1970)

        var candidate = "\(stem)_\(timestamp).app"
        var index = 2
        while fileManager.fileExists(atPath: targetRootURL.appendingPathComponent(candidate).path) {
            candidate = "\(stem)_\(timestamp)_\(index).app"
            index += 1
        }
        return candidate
    }

    nonisolated private static func resetClonedAppInfo(at clonedBundleURL: URL, fileManager: FileManager) throws {
        let lcAppInfoPath = clonedBundleURL.appendingPathComponent("LCAppInfo.plist")
        let infoPlistURL = clonedBundleURL.appendingPathComponent("Info.plist")
        if fileManager.fileExists(atPath: lcAppInfoPath.path) {
            if let lcData = try? Data(contentsOf: lcAppInfoPath),
               let lcDict = try? PropertyListSerialization.propertyList(from: lcData, format: nil) as? [String: Any],
               (lcDict["doUseLCBundleId"] as? NSNumber)?.boolValue == true,
               let originalBundleId = lcDict["LCOrignalBundleIdentifier"] as? String,
               !originalBundleId.isEmpty,
               fileManager.fileExists(atPath: infoPlistURL.path),
               let infoData = try? Data(contentsOf: infoPlistURL) {
                var format: PropertyListSerialization.PropertyListFormat = .binary
                if var infoDict = try? PropertyListSerialization.propertyList(from: infoData, format: &format) as? [String: Any] {
                    infoDict["CFBundleIdentifier"] = originalBundleId
                    let writeFormat: PropertyListSerialization.PropertyListFormat = (format == .xml) ? .xml : .binary
                    if let updatedData = try? PropertyListSerialization.data(fromPropertyList: infoDict, format: writeFormat, options: 0) {
                        try updatedData.write(to: infoPlistURL, options: .atomic)
                    }
                }
            }
            try fileManager.removeItem(at: lcAppInfoPath)
        }

        for fileName in ["LCAppIconLight.png", "LCAppIconDark.png", "zsign_cache.json", "LiveContainer.tmp"] {
            let fileURL = clonedBundleURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func signClonedAppIfNeeded(_ clonedAppInfo: LCAppInfo) async throws {
        let (signSuccess, signError) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            clonedAppInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                continuation.resume(returning: (success, error))
            }, progressHandler: { _ in
            }, forceSign: false)
        }
        if let signError, !signSuccess {
            throw signError.loc
        }
    }

    func exportIPA(includeData: Bool) async {
        do {
            let exportURL = try await createExportIPA(includeData: includeData)
            await MainActor.run {
                presentExportShareSheet(for: exportURL)
            }
        } catch {
            await MainActor.run {
                showError(error.localizedDescription)
            }
        }
    }

    func exportData() async {
        do {
            let exportURL = try await createDataArchive()
            await MainActor.run {
                presentExportShareSheet(for: exportURL)
            }
        } catch {
            await MainActor.run {
                showError(error.localizedDescription)
            }
        }
    }

    func openDylibAndFrameworkExportSelection() {
        guard let bundlePath = configuration.model.appInfo.bundlePath() else {
            showError("Unable to read app bundle path.")
            return
        }

        Task { [weak self] in
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try lcListExportableBinaries(bundlePath: bundlePath)
                }.value
                await MainActor.run {
                    self?.presentBinaryExportSelection(items: items)
                }
            } catch {
                await MainActor.run {
                    self?.showError(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    private func presentBinaryExportSelection(items: [AppBinaryExportItem]) {
        guard presentedViewController == nil else {
            return
        }

        let controller = UIHostingController(
            rootView: LCAppBinaryExportView(
                items: items,
                onCancel: { [weak self] in
                    self?.dismiss(animated: true)
                },
                onExport: { [weak self] selectedItems in
                    self?.dismiss(animated: true) {
                        Task { [weak self] in
                            await self?.exportSelectedDylibsAndFrameworks(selectedItems: selectedItems)
                        }
                    }
                },
                onCopyToTweaks: { [weak self] selectedItems in
                    self?.dismiss(animated: true) {
                        self?.presentCopyToTweaksDestination(selectedItems: selectedItems)
                    }
                }
            )
        )
        controller.modalPresentationStyle = .formSheet
        present(controller, animated: true)
    }

    private func exportSelectedDylibsAndFrameworks(selectedItems: [AppBinaryExportItem]) async {
        do {
            guard !selectedItems.isEmpty else {
                throw "Select at least one item to export."
            }
            let archiveURL = try await createSelectedBinaryArchive(selectedItems: selectedItems)
            await MainActor.run {
                presentExportShareSheet(for: archiveURL)
            }
        } catch {
            await MainActor.run {
                showError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func presentCopyToTweaksDestination(selectedItems: [AppBinaryExportItem]) {
        guard !selectedItems.isEmpty else {
            showError("Select at least one item first.")
            return
        }

        let controller = UIHostingController(
            rootView: LCTweaksCopyDestinationView(
                onClose: { [weak self] in
                    self?.dismiss(animated: true)
                },
                onCopyHere: { [weak self] destinationURL in
                    Task { [weak self] in
                        await self?.copySelectedToTweaks(selectedItems: selectedItems, destinationFolderURL: destinationURL)
                    }
                }
            )
            .environmentObject(DataManager.shared.model)
        )
        controller.modalPresentationStyle = .formSheet
        present(controller, animated: true)
    }

    private func copySelectedToTweaks(selectedItems: [AppBinaryExportItem], destinationFolderURL: URL) async {
        do {
            let copiedCount = try await Task.detached(priority: .userInitiated) {
                try Self.copySelectedBinaryItems(selectedItems: selectedItems, to: destinationFolderURL)
            }.value
            await MainActor.run {
                dismiss(animated: true) {
                    self.showExportSuccess("Copied \(copiedCount) item(s) to \(destinationFolderURL.lastPathComponent).")
                }
            }
        } catch {
            await MainActor.run {
                showError(error.localizedDescription)
            }
        }
    }

    nonisolated private static func copySelectedBinaryItems(selectedItems: [AppBinaryExportItem], to destinationFolderURL: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        var copiedCount = 0
        for item in selectedItems {
            let proposedURL = destinationFolderURL.appendingPathComponent(item.url.lastPathComponent, isDirectory: item.kind == .framework)
            let destinationURL = nextAvailableCopyURL(for: proposedURL)
            try fm.copyItem(at: item.url, to: destinationURL)
            copiedCount += 1
        }
        return copiedCount
    }

    nonisolated private static func nextAvailableCopyURL(for proposedURL: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: proposedURL.path) {
            return proposedURL
        }

        let pathExtension = proposedURL.pathExtension
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let parentURL = proposedURL.deletingLastPathComponent()

        var index = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(pathExtension)"
            let candidateURL = parentURL.appendingPathComponent(candidateName, isDirectory: pathExtension == "framework")
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func createExportIPA(includeData: Bool) async throws -> URL {
        let appInfo = configuration.model.appInfo
        guard let bundlePath = appInfo.bundlePath() else {
            throw "Unable to read app bundle path."
        }

        var containerDataURL: URL? = nil
        var containerHasBookmark = false
        if includeData {
            guard let container = configuration.model.uiSelectedContainer else {
                throw "Select a container before exporting app data."
            }
            if container.storageBookMark != nil && container.resolvedContainerURL == nil {
                throw container.bookmarkResolved
                    ? "lc.container.externalStorageUnavailable".loc
                    : "lc.container.bookmarkResolveInProgress".loc
            }
            containerDataURL = container.containerURL
            containerHasBookmark = (container.storageBookMark != nil)
        }
        let appName = Self.sanitizedFileStem(appInfo.displayName() ?? "App")
        let fallbackExecStem = Self.sanitizedFileStem(appInfo.info()?["CFBundleExecutable"] as? String ?? appName)

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCAppExport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagingRoot) }
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

            let sourceAppURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            let rawExecName = Self.readExecutableName(at: sourceAppURL) ?? fallbackExecStem
            let cleanBundleStem = Self.sanitizedFileStem(rawExecName)
            let stagedAppURL = stagingRoot.appendingPathComponent("\(cleanBundleStem).app", isDirectory: true)
            try fm.copyItem(at: sourceAppURL, to: stagedAppURL)

            // Restore original bundle ID if spoofed, remove LC-internal metadata/user data,
            // and unpatch Mach-O executables back to standard MH_EXECUTE for portability.
            try lcSanitizeStagedAppBundle(at: stagedAppURL, unpatchExecutables: true, fileManager: fm)

            var mappings: [[String: Any]] = [[
                "sourcePath": stagedAppURL.path,
                "archivePrefix": "Payload/\(cleanBundleStem).app",
                "skipSymlinks": false
            ]]

            if let dataURL = containerDataURL {
                if containerHasBookmark && !dataURL.startAccessingSecurityScopedResource() {
                    throw "Unable to access selected external container."
                }
                defer {
                    if containerHasBookmark {
                        dataURL.stopAccessingSecurityScopedResource()
                    }
                }
                var dataIsDir: ObjCBool = false
                guard fm.fileExists(atPath: dataURL.path, isDirectory: &dataIsDir), dataIsDir.boolValue else {
                    throw "Selected container data does not exist."
                }
                mappings.append([
                    "sourcePath": dataURL.path,
                    "archivePrefix": "LCContainerData",
                    "skipSymlinks": true,
                    "excludedNames": [".lc_profile_telemetry.plist", "tmp"]
                ])
            }

            let fileName = includeData ? "\(appName)-with-data.ipa" : "\(appName).ipa"
            let exportURL = try Self.makeScopedExportArtifactURL(fileName: fileName, fileManager: fm)
            if let archiveError = LCCreateZipArchive(exportURL.path, mappings) {
                throw archiveError
            }
            return exportURL
        }.value
    }

    private func createDataArchive() async throws -> URL {
        guard let container = configuration.model.uiSelectedContainer else {
            throw "Select a container before exporting data."
        }
        if container.storageBookMark != nil && container.resolvedContainerURL == nil {
            throw container.bookmarkResolved
                ? "lc.container.externalStorageUnavailable".loc
                : "lc.container.bookmarkResolveInProgress".loc
        }

        let containerURL = container.containerURL
        let needsSecurityAccess = container.storageBookMark != nil
        let appName = Self.sanitizedFileStem(configuration.model.appInfo.displayName() ?? "App")
        let containerName = Self.sanitizedFileStem(container.name)

        return try await Task.detached(priority: .userInitiated) {
            if needsSecurityAccess && !containerURL.startAccessingSecurityScopedResource() {
                throw "Unable to access selected external container."
            }
            defer {
                if needsSecurityAccess {
                    containerURL.stopAccessingSecurityScopedResource()
                }
            }

            let fm = FileManager.default
            var sourceIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: containerURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
                throw "Selected container path is not a directory."
            }

            let exportURL = try Self.makeScopedExportArtifactURL(fileName: "\(appName)-\(containerName)-data.zip", fileManager: fm)
            let mappings: [[String: Any]] = [[
                "sourcePath": containerURL.path,
                "archivePrefix": "",
                "skipSymlinks": true,
                "excludedNames": [".lc_profile_telemetry.plist", "tmp"]
            ]]
            if let archiveError = LCCreateZipArchive(exportURL.path, mappings) {
                throw archiveError
            }
            return exportURL
        }.value
    }

    private func createSelectedBinaryArchive(selectedItems: [AppBinaryExportItem]) async throws -> URL {
        let appInfo = configuration.model.appInfo
        guard appInfo.bundlePath() != nil else {
            throw "Unable to read app bundle path."
        }
        let appName = Self.sanitizedFileStem(appInfo.displayName() ?? "App")

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCBinaryExport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagingRoot) }

            let contentRoot = stagingRoot.appendingPathComponent("\(appName)-dylibs-frameworks", isDirectory: true)
            try fm.createDirectory(at: contentRoot, withIntermediateDirectories: true)

            for item in selectedItems {
                let destinationURL = contentRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .framework)
                try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destinationURL)
                try fm.copyItem(at: item.url, to: destinationURL)
            }

            let archiveURL = try Self.makeScopedExportArtifactURL(fileName: "\(appName)-dylibs-frameworks.zip", fileManager: fm)
            let mappings: [[String: Any]] = [[
                "sourcePath": contentRoot.path,
                "archivePrefix": "",
                "skipSymlinks": false
            ]]
            if let archiveError = LCCreateZipArchive(archiveURL.path, mappings) {
                throw archiveError
            }
            return archiveURL
        }.value
    }

    nonisolated private static func makeScopedExportArtifactURL(fileName: String, fileManager: FileManager) throws -> URL {
        let baseDir = try lcEnsureExportArtifactDirectory(fileManager: fileManager)
        let scopedDir = baseDir.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scopedDir, withIntermediateDirectories: true)
        return scopedDir.appendingPathComponent(fileName)
    }

    nonisolated private static func readExecutableName(at appBundleURL: URL) -> String? {
        let infoURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = dict["CFBundleExecutable"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    @MainActor
    private func presentExportShareSheet(for fileURL: URL) {
        let activityController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        activityController.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        present(activityController, animated: true)
    }

    @MainActor
    private func showExportSuccess(_ message: String) {
        guard viewIfLoaded?.window != nil else {
            return
        }
        let alert = UIAlertController(title: "lc.common.success".loc, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
        present(alert, animated: true)
    }

    nonisolated private static func sanitizedFileStem(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "Export"
        }
        return String(cleaned.prefix(80))
    }
}

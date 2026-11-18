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
                    keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
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
        if fileManager.fileExists(atPath: lcAppInfoPath.path) {
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
            containerDataURL = container.containerURL
            containerHasBookmark = (container.storageBookMark != nil)
        }
        let appName = Self.sanitizedFileStem(appInfo.displayName() ?? "App")

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCAppExport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagingRoot) }

            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let payloadDir = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
            try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

            let sourceAppURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
            let destinationAppURL = payloadDir.appendingPathComponent(sourceAppURL.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: sourceAppURL, to: destinationAppURL)

            if let dataURL = containerDataURL {
                if containerHasBookmark && !dataURL.startAccessingSecurityScopedResource() {
                    throw "Unable to access selected external container."
                }
                defer {
                    if containerHasBookmark {
                        dataURL.stopAccessingSecurityScopedResource()
                    }
                }
                guard fm.fileExists(atPath: dataURL.path) else {
                    throw "Selected container data does not exist."
                }
                try Self.copyContainerDataForExport(
                    from: dataURL,
                    to: destinationAppURL.appendingPathComponent("LCUserData", isDirectory: true)
                )
            }

            let fileName = includeData ? "\(appName)-with-data.ipa" : "\(appName).ipa"
            let exportURL = try lcExportArtifactFileURL(fileName: fileName, fileManager: fm)
            try? fm.removeItem(at: exportURL)
            try Self.zipDirectorySync(sourceURL: stagingRoot, destinationURL: exportURL)
            return exportURL
        }.value
    }

    private func createDataArchive() async throws -> URL {
        guard let container = configuration.model.uiSelectedContainer else {
            throw "Select a container before exporting data."
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

            let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCDataExport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagingRoot) }
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

            let stagedContainerURL = stagingRoot.appendingPathComponent("\(appName)-\(containerName)-data", isDirectory: true)
            try Self.copyContainerDataForExport(from: containerURL, to: stagedContainerURL)

            let exportURL = try lcExportArtifactFileURL(fileName: "\(appName)-\(containerName)-data.zip", fileManager: fm)
            try? fm.removeItem(at: exportURL)
            try Self.zipDirectorySync(sourceURL: stagedContainerURL, destinationURL: exportURL)
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

            let archiveURL = try lcExportArtifactFileURL(fileName: "\(appName)-dylibs-frameworks.zip", fileManager: fm)
            try? fm.removeItem(at: archiveURL)
            try Self.zipDirectorySync(sourceURL: contentRoot, destinationURL: archiveURL)
            return archiveURL
        }.value
    }

    nonisolated private static func zipDirectorySync(sourceURL: URL, destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordinationError) { zippedURL in
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let copyError {
            throw copyError
        }
        if let coordinationError {
            throw coordinationError
        }
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
            Self.cleanupExportArtifacts()
        }
        present(activityController, animated: true)
    }

    nonisolated private static func cleanupExportArtifacts() {
        try? FileManager.default.removeItem(at: lcExportArtifactDirectoryURL())
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
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Export" : cleaned
    }

    nonisolated private static func copyContainerDataForExport(from sourceContainerURL: URL, to destinationContainerURL: URL) throws {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceContainerURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw "Selected container path is not a directory."
        }
        try copyDirectoryForExport(from: sourceContainerURL, to: destinationContainerURL)
    }

    nonisolated private static func copyDirectoryForExport(from sourceDirectoryURL: URL, to destinationDirectoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        let items = try fm.contentsOfDirectory(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey],
            options: []
        )

        for itemURL in items {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey])
            if shouldSkipDataExportItem(values: values) {
                continue
            }

            let destinationItemURL = destinationDirectoryURL.appendingPathComponent(itemURL.lastPathComponent, isDirectory: values.isDirectory ?? false)
            if values.isDirectory == true {
                try copyDirectoryForExport(from: itemURL, to: destinationItemURL)
                continue
            }

            do {
                try fm.copyItem(at: itemURL, to: destinationItemURL)
            } catch {
                if shouldIgnoreDataExportCopyError(error, resourceValues: values) {
                    continue
                }
                throw error
            }
        }
    }

    nonisolated private static func shouldSkipDataExportItem(values: URLResourceValues) -> Bool {
        if values.isSymbolicLink == true {
            return true
        }
        if let resourceType = values.fileResourceType {
            switch resourceType {
            case .socket, .characterSpecial, .blockSpecial, .namedPipe, .unknown:
                return true
            default:
                break
            }
        }
        return false
    }

    nonisolated private static func shouldIgnoreDataExportCopyError(_ error: Error, resourceValues: URLResourceValues) -> Bool {
        if shouldSkipDataExportItem(values: resourceValues) {
            return true
        }
        let nsError = error as NSError
        if !isNoSuchFileError(nsError) {
            if nsError.domain == NSPOSIXErrorDomain {
                switch nsError.code {
                case Int(POSIXErrorCode.EINVAL.rawValue),
                     Int(POSIXErrorCode.EPERM.rawValue),
                     Int(POSIXErrorCode.ENOTSUP.rawValue),
                     Int(POSIXErrorCode.EOPNOTSUPP.rawValue):
                    return true
                default:
                    break
                }
            }
            return false
        }
        if resourceValues.isSymbolicLink == true {
            return true
        }
        if let resourceType = resourceValues.fileResourceType {
            return resourceType == .socket || resourceType == .namedPipe
        }
        return false
    }

    nonisolated private static func isNoSuchFileError(_ nsError: NSError) -> Bool {
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }
}

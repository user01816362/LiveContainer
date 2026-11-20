//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Foundation
import os
import SwiftUI
import UIKit

struct LCAppBannerConfiguration {
    let model: LCAppModel
    let dynamicColors: Bool
    let darkModeIcon: Bool
    let updateCandidate: LCAppUpdateCandidate?
    let activeDownload: LCDownloadTaskItem?
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {

    fileprivate let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    private(set) var configuration: LCAppBannerConfiguration
    private let exportTemporaryDirectoryLock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    init(delegate: LCAppBannerDelegate, config: LCAppBannerConfiguration) {
        self.delegate = delegate
        self.configuration = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = bannerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 0, height: LCAppBannerRootView.bannerHeight)
        bannerView.runControl.addTarget(self, action: #selector(runButtonTapped), for: .touchUpInside)
        bannerView.updateButton.addTarget(self, action: #selector(updateButtonTapped), for: .touchUpInside)
        bannerView.addInteraction(UIContextMenuInteraction(delegate: self))

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(bannerDoubleTapped))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        bannerView.addGestureRecognizer(doubleTapGesture)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.refreshView()
        }
    }

    deinit {
        cleanupExportTemporaryDirectory()
    }

    func update(
        model: LCAppModel,
        dynamicColors: Bool,
        darkModeIcon: Bool,
        updateCandidate: LCAppUpdateCandidate?,
        activeDownload: LCDownloadTaskItem?
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            updateCandidate: updateCandidate,
            activeDownload: activeDownload
        )
        refreshView()
    }

    private func refreshView() {
        bannerView.update(
            model: configuration.model,
            appInfo: configuration.model.appInfo,
            dynamicColors: configuration.dynamicColors,
            darkModeIcon: configuration.darkModeIcon,
            updateCandidate: configuration.updateCandidate,
            activeDownload: configuration.activeDownload,
            traitCollection: traitCollection
        )
    }

    @objc private func bannerDoubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        let location = gestureRecognizer.location(in: bannerView.runControl)
        let updateLoc = gestureRecognizer.location(in: bannerView.updateButton)
        guard !bannerView.runControl.bounds.contains(location),
              !(!bannerView.updateButton.isHidden && bannerView.updateButton.bounds.contains(updateLoc)) else {
            return
        }
        openSettings()
    }

    @objc private func updateButtonTapped() {
        if configuration.activeDownload != nil {
            LCDownloadManager.shared.isQueueSheetPresented = true
        } else if DataManager.shared.model.multiLCStatus != 2,
                  let candidate = configuration.updateCandidate {
            AltStoreSourcesViewModel.shared.enqueueUpdate(candidate)
        }
    }

    @objc private func runButtonTapped() {
        if let currentDataFolder = configuration.model.uiSelectedContainer?.folderName,
           MultitaskManager.isUsing(container: currentDataFolder) {
            var found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
            }
            if found {
                return
            }
        }

        Task { [weak self] in
            await self?.runApp()
        }
    }

    private func runApp(multitask: Bool? = nil) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        do {
            try await configuration.model.runApp(multitask: multitask)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        let appInfo = model.appInfo
        var menuChildren: [UIMenuElement] = []

        // Update & Version History Menu Section
        let isPrimaryLC = DataManager.shared.model.multiLCStatus != 2
        let versionCount = AltStoreSourcesViewModel.shared.availableVersionCount(forBundleId: model.bundleIdentifier)
        var versionActions: [UIMenuElement] = []
        if isPrimaryLC, let candidate = configuration.updateCandidate {
            versionActions.append(UIAction(
                title: "Update to \(candidate.latestDisplayVersion)",
                image: UIImage(systemName: "arrow.down.circle.fill")
            ) { _ in
                AltStoreSourcesViewModel.shared.enqueueUpdate(candidate)
            })
            versionActions.append(UIAction(
                title: "Ignore Version \(candidate.latestDisplayVersion)",
                image: UIImage(systemName: "eye.slash")
            ) { _ in
                AltStoreSourcesViewModel.shared.ignoreUpdate(candidate)
            })
        }
        if versionCount > 0 || configuration.updateCandidate != nil || appInfo.ignoredUpdateVersion != nil {
            let versionsAction = UIAction(
                title: "Versions…",
                subtitle: versionCount > 0 ? "\(versionCount) available" : nil,
                image: UIImage(systemName: "clock.arrow.circlepath")
            ) { [weak self] _ in
                self?.openVersionHistory()
            }
            versionActions.append(versionsAction)
        }
        if !versionActions.isEmpty {
            let sectionTitle = (isPrimaryLC && configuration.updateCandidate != nil) ? "Update Available" : ""
            menuChildren.append(UIMenu(title: sectionTitle, options: .displayInline, children: versionActions))
        }

        // 1. Containers Picker (Equivalent to a Menu with single selection)
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { [weak self] container in
                UIAction(
                    title: container.name,
                    state: container == model.uiSelectedContainer ? .on : .off
                ) { _ in
                    model.uiSelectedContainer = container
                    self?.refreshView()
                }
            }
            menuChildren.append(UIMenu(title: "Containers", options: .displayInline, children: containerActions))
        }

        // 2. Main Section
        var sectionChildren: [UIMenuElement] = []
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.openDataFolder".loc,
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            })
        }

        // Multitask Toggle
        let shouldLaunchInMultitaskMode = model.shouldLaunchInMultitaskMode
        sectionChildren.append(UIAction(
            title: shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
            image: UIImage(systemName: shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.runApp(multitask: !shouldLaunchInMultitaskMode)
            }
        })

        sectionChildren.append(UIAction(
            title: "Launch in Debug Studio",
            image: UIImage(systemName: "ladybug.fill")
        ) { _ in
            DataManager.shared.model.activeDebugApp = model
        })

        let addToHomeScreenMenu = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [
                UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.copyLaunchUrl()
                },
                UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.saveIcon()
                    }
                },
                UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.createAppClip()
                    }
                }
            ]
        )
        sectionChildren.append(addToHomeScreenMenu)

        let dataExportDisabled: UIMenuElement.Attributes = model.uiSelectedContainer == nil ? [.disabled] : []
        sectionChildren.append(UIMenu(
            title: "Inspect & Files",
            image: UIImage(systemName: "cpu.fill"),
            children: [
                UIAction(
                    title: "Inspect Binary & Dump",
                    image: UIImage(systemName: "doc.text.magnifyingglass")
                ) { [weak self] _ in
                    self?.openBinaryInspector()
                },
                UIAction(
                    title: "Browse App Bundle",
                    image: UIImage(systemName: "folder.fill")
                ) { [weak self] _ in
                    self?.openAppBundleExplorer()
                },
                UIAction(
                    title: "Browse Container Data",
                    image: UIImage(systemName: "externaldrive.fill"),
                    attributes: dataExportDisabled
                ) { [weak self] _ in
                    self?.openContainerExplorer()
                }
            ]
        ))

        sectionChildren.append(UIMenu(
            title: "Export",
            image: UIImage(systemName: "square.and.arrow.up"),
            children: [
                UIAction(
                    title: "Export IPA",
                    image: UIImage(systemName: "shippingbox")
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.exportIPA(includeData: false)
                    }
                },
                UIAction(
                    title: "Export Data",
                    image: UIImage(systemName: "folder.fill"),
                    attributes: dataExportDisabled
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.exportData()
                    }
                },
                UIAction(
                    title: "Export IPA + Data",
                    image: UIImage(systemName: "square.and.arrow.up.on.square"),
                    attributes: dataExportDisabled
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.exportIPA(includeData: true)
                    }
                },
                UIAction(
                    title: "Export Dylibs & Frameworks",
                    image: UIImage(systemName: "list.bullet.rectangle")
                ) { [weak self] _ in
                    self?.openDylibAndFrameworkExportSelection()
                }
            ]
        ))

        sectionChildren.append(UIAction(
            title: "Clone App",
            image: UIImage(systemName: "square.on.square")
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.cloneApp()
            }
        })

        sectionChildren.append(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        })

        if !model.uiIsShared {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.uninstall".loc,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.uninstall()
                }
            })
        }

        menuChildren.append(UIMenu(
            title: appInfo.relativeBundlePath ?? "",
            options: .displayInline,
            children: sectionChildren
        ))
        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    private func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: configuration.model)))
    }

    private func openBinaryInspector() {
        let appInfo = configuration.model.appInfo
        guard let bundlePath = appInfo.bundlePath() else {
            showError("Cannot locate app bundle path.")
            return
        }
        let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let title = appInfo.displayName() ?? configuration.model.displayName
        delegate.openNavigationView(view: AnyView(
            LCBinaryInspectorView(bundleURL: bundleURL, title: title)
        ))
    }

    private func openAppBundleExplorer() {
        let appInfo = configuration.model.appInfo
        guard let bundlePath = appInfo.bundlePath() else {
            showError("Cannot locate app bundle path.")
            return
        }
        let isSecondary = DataManager.shared.model.multiLCStatus == 2
        let root = LCFileExplorerRoot(
            title: appInfo.displayName() ?? configuration.model.displayName,
            rootURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            isReadOnly: isSecondary,
            readOnlyReason: isSecondary ? "Secondary LiveContainer" : nil
        )
        delegate.openNavigationView(view: AnyView(LCFileExplorerView(root: root)))
    }

    private func openContainerExplorer() {
        guard let container = configuration.model.uiSelectedContainer else {
            return
        }
        let inUse = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) != nil
        let root = LCFileExplorerRoot(
            title: container.name,
            rootURL: container.containerURL,
            needsSecurityScope: container.storageBookMark != nil,
            isReadOnly: inUse,
            readOnlyReason: inUse ? "Container is Running" : nil
        )
        delegate.openNavigationView(view: AnyView(LCFileExplorerView(root: root)))
    }

    private func openVersionHistory() {
        let presenter = UIApplication.shared.lcTopmostViewController() ?? self
        guard presenter.presentedViewController == nil else {
            return
        }
        let target = LCVersionHistoryTarget(app: configuration.model)
        let rootView = LCAppVersionsView(target: target, isPresentedAsSheet: true)
            .environmentObject(DataManager.shared.model)
            .environmentObject(LCDownloadManager.shared)
        let controller = UIHostingController(rootView: rootView)
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
    }

    private func openDataFolder() {
        guard let folderName = configuration.model.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        let displayName = appInfo.displayName() ?? configuration.model.displayName
        let shouldUninstall = await presentConfirmation(
            title: "lc.appBanner.confirmUninstallTitle".loc,
            message: "lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(displayName),
            confirmTitle: "lc.appBanner.uninstall".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard shouldUninstall == true else {
            return
        }

        var shouldRemoveAppFolders = false
        let containers = appInfo.containers
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }

            let fileManager = FileManager.default
            try fileManager.removeItem(atPath: bundlePath)
            delegate.removeApp(app: configuration.model)

            if shouldRemoveAppFolders {
                for container in containers {
                    let dataUUID = container.folderName
                    try fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }



    private func copyLaunchUrl() {
        guard let relativeBundlePath = configuration.model.appInfo.relativeBundlePath else {
            return
        }

        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(folderName)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    private func createAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let profile = configuration.model.appInfo.generateWebClipConfig(
                withContainerId: configuration.model.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let rawDisplayName = configuration.model.appInfo.displayName() ?? configuration.model.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectoryLock.withLock { $0 = temporaryDirectory }

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            documentPicker.delegate = self
            documentPicker.presentationController?.delegate = self
            present(documentPicker, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupExportTemporaryDirectory()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupExportTemporaryDirectory()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupExportTemporaryDirectory()
    }

    nonisolated private func cleanupExportTemporaryDirectory() {
        let directory = exportTemporaryDirectoryLock.withLock { dir -> URL? in
            let current = dir
            dir = nil
            return current
        }
        guard let directory else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

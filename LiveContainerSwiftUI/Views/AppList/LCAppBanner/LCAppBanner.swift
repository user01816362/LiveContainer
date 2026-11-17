//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate

    @ObservedObject var model: LCAppModel
    @ObservedObject private var sourcesVM = AltStoreSourcesViewModel.shared
    @EnvironmentObject private var downloadManager: LCDownloadManager

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
    }

    private func currentUpdateAndDownload() -> (LCAppUpdateCandidate?, LCDownloadTaskItem?) {
        let candidate = sourcesVM.updateCandidate(for: model)
        let dl = (model.appInfo.relativeBundlePath.flatMap { downloadManager.activeTask(forBundleId: $0) })
            ?? downloadManager.activeTask(forBundleId: model.bundleIdentifier)
        return (candidate, dl)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let (candidate, dl) = currentUpdateAndDownload()
        return LCAppBannerViewController(
            delegate: delegate,
            config: LCAppBannerConfiguration(
                model: model,
                dynamicColors: dynamicColors,
                darkModeIcon: darkModeIcon,
                updateCandidate: candidate,
                activeDownload: dl
            )
        )
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let viewController = uiViewController as? LCAppBannerViewController else {
            return
        }
        let (candidate, dl) = currentUpdateAndDownload()
        viewController.update(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            updateCandidate: candidate,
            activeDownload: dl
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        return CGSize(width: width, height: LCAppBannerRootView.bannerHeight)
    }
}

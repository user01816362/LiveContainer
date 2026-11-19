//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate

    @ObservedObject var model: LCAppModel
    var updateCandidate: LCAppUpdateCandidate?
    @EnvironmentObject private var downloadManager: LCDownloadManager

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, updateCandidate: LCAppUpdateCandidate? = nil) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
        self.updateCandidate = updateCandidate
    }

    private func currentDownload() -> LCDownloadTaskItem? {
        (model.appInfo.relativeBundlePath.flatMap { downloadManager.activeTask(forBundleId: $0) })
            ?? downloadManager.activeTask(forBundleId: model.bundleIdentifier)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        LCAppBannerViewController(
            delegate: delegate,
            config: LCAppBannerConfiguration(
                model: model,
                dynamicColors: dynamicColors,
                darkModeIcon: darkModeIcon,
                updateCandidate: updateCandidate,
                activeDownload: currentDownload()
            )
        )
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let viewController = uiViewController as? LCAppBannerViewController else {
            return
        }
        viewController.update(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            updateCandidate: updateCandidate,
            activeDownload: currentDownload()
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        return CGSize(width: width, height: LCAppBannerRootView.bannerHeight)
    }
}

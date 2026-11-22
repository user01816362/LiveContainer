//
//  LCTabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""

    @EnvironmentObject var sharedModel: SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @EnvironmentObject var downloadManager: LCDownloadManager
    @ObservedObject var sourcesViewModel = AltStoreSourcesViewModel.shared
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.openWindow) private var openWindow

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)

    var body: some View {
        TabView(selection: $sharedModel.selectedTab) {
            if sharedModel.multiLCStatus != 2 {
                Tab("lc.tabView.sources".loc, systemImage: "books.vertical", value: LCTabIdentifier.sources) {
                    LCSourcesView()
                }
            }

            Tab("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill", value: LCTabIdentifier.apps) {
                LCAppListView()
            }
            .badge(sourcesViewModel.availableUpdates.count)

            if sharedModel.multiLCStatus != 2 {
                Tab("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver", value: LCTabIdentifier.tweaks) {
                    LCTweaksView()
                }
            }

            Tab("lc.tabView.settings".loc, systemImage: "gearshape.fill", value: LCTabIdentifier.settings) {
                LCSettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .bottom) {
            LCDownloadPillBar()
                .padding(.bottom, 76)
        }
        .sheet(isPresented: $downloadManager.isQueueSheetPresented) {
            LCDownloadQueueSheet()
                .environmentObject(downloadManager)
        }
        .fullScreenCover(item: $sharedModel.activeDebugApp) { debugApp in
            LCDebugStudioView(appModel: debugApp)
        }
        .alert("lc.common.error".loc, isPresented: Binding(
            get: { downloadManager.alertMessage != nil },
            set: { if !$0 { downloadManager.alertMessage = nil } }
        )) {
            Button("lc.common.ok".loc) {
                downloadManager.alertMessage = nil
            }
        } message: {
            Text(downloadManager.alertMessage ?? "")
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {})
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationStack {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                            ShareLink(item: log)
                        } else {
                            ShareLink(item: errorInfo)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            MultitaskWindowManager.openWindowAction = openWindow
        }
        .task {
            MultitaskWindowManager.openWindowAction = openWindow
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
        }
        .onChange(of: sharedModel.apps) { _, _ in
            LCLaunchCatalogSync.syncFromSharedModel()
        }
        .onChange(of: sharedModel.hiddenApps) { _, _ in
            LCLaunchCatalogSync.syncFromSharedModel()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }

    func dispatchURL(url: URL) {
        if url.isFileURL {
            sharedModel.selectedTab = .apps
            sharedModel.deepLink = url
            return
        }
        if url.scheme?.lowercased() == "sidestore" {
            sharedModel.selectedTab = .apps
            sharedModel.deepLink = url
            return
        }

        guard let host = url.host?.lowercased() else {
            return
        }

        switch host {
        case "install":
            if sharedModel.multiLCStatus != 2,
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let installUrlStr = components.queryItems?.first(where: { $0.name == "url" })?.value,
               let installUrl = URL(string: installUrlStr),
               (installUrl.scheme?.lowercased() == "http" || installUrl.scheme?.lowercased() == "https") {
                downloadManager.enqueueAppDownload(
                    url: installUrl,
                    displayName: installUrl.deletingPathExtension().lastPathComponent
                )
                return
            }
            sharedModel.selectedTab = .apps
            sharedModel.deepLink = url
        case "livecontainer-launch", "open-web-page", "open-url":
            sharedModel.selectedTab = .apps
            sharedModel.deepLink = url
        case "certificate":
            sharedModel.selectedTab = .settings
            sharedModel.deepLink = url
        case "source":
            sharedModel.selectedTab = .sources
            sharedModel.deepLink = url
        default:
            return
        }
    }

    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }

    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")

        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }

        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }

    func copyError() {
        UIPasteboard.general.string = errorInfo
    }

    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }

            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }

        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }

        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }

    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }

        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }

        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil),
              let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }

        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }

        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }

        if bundleId != correctBundleId {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }

    func checkGetTaskAllow() {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil),
              (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
}

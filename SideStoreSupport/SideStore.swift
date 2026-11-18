//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications
import os

func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.setProgress(intentProgress)
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent
{
    public static let intentClassName = "RefreshAllIntent"
    public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    
    public static let title: LocalizedStringResource = "Refresh All Apps"
    public static var description: IntentDescription {
        IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    }
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
}


final class RefreshHandler: NSObject, RefreshServer, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var refreshContinuation: CheckedContinuation<Void, any Error>? = nil
        var launchContinuation: CheckedContinuation<Void, any Error>? = nil
        var launchTimeoutTask: Task<Void, Never>? = nil
        var progress: Progress? = nil
        var listener: NSXPCListener? = nil
        var sideStorePid: Int32 = 0
        var client: (any RefreshClient)? = nil
        var ext: NSExtension? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    static let shared = RefreshHandler()

    func setProgress(_ progress: Progress?) {
        state.withLockUnchecked { $0.progress = progress }
    }

    private func terminateSideStoreIfNeeded(pid: Int32) {
        guard pid > 0 else {
            return
        }
        kill(pid, SIGKILL)
    }

    func startRefresh(identifier: String, mangledName: String) async throws {
        let staleContinuation: CheckedContinuation<Void, any Error>? = try state.withLockUnchecked { s in
            var stale: CheckedContinuation<Void, any Error>? = nil
            if (s.sideStorePid <= 0 || getpgid(s.sideStorePid) <= 0), let existing = s.refreshContinuation {
                s.refreshContinuation = nil
                stale = existing
            }
            if s.refreshContinuation != nil {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another refresh task is in progress."])
            }
            return stale
        }
        staleContinuation?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))

        var listener = state.withLockUnchecked { $0.listener }
        if listener == nil {
            guard let created = startAnonymousListener(self) else {
                return
            }
            listener = state.withLockUnchecked { s in
                if s.listener == nil {
                    s.listener = created
                }
                return s.listener
            }
        }
        guard let listener else {
            return
        }

        // Launch SideStore if it's not running
        let shouldLaunch = state.withLockUnchecked { s in
            (s.sideStorePid <= 0 || getpgid(s.sideStorePid) <= 0) && s.launchContinuation == nil
        }

        if shouldLaunch {
            let lcHome = getenv("LC_HOME_PATH").map { String(cString: $0) } ?? NSHomeDirectory()
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            try FileManager.default.createDirectory(at: sideStoreHomeURL, withIntermediateDirectories: true)
            guard let bookmarkData = bookmarkForURL(sideStoreHomeURL) else {
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create security-scoped bookmark for SideStore data folder."])
            }

            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use PlumeImpactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            
            let ext: NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            guard let ext else {
                return
            }
            state.withLockUnchecked { $0.ext = ext }
            
            ext.setRequestInterruptionBlock { [weak self] _ in
                guard let self else { return }
                let crashError = NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"])
                let (pendingLaunch, pendingRefresh, timeoutTask) = self.state.withLockUnchecked { s -> (CheckedContinuation<Void, any Error>?, CheckedContinuation<Void, any Error>?, Task<Void, Never>?) in
                    let launch = s.launchContinuation
                    let refresh = s.refreshContinuation
                    let task = s.launchTimeoutTask
                    s.launchContinuation = nil
                    s.refreshContinuation = nil
                    s.launchTimeoutTask = nil
                    s.sideStorePid = 0
                    s.client = nil
                    return (launch, refresh, task)
                }
                timeoutTask?.cancel()
                pendingLaunch?.resume(throwing: crashError)
                pendingRefresh?.resume(throwing: crashError)
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            let pid = ext.pid(forRequestIdentifier: uuid)
            state.withLockUnchecked { $0.sideStorePid = pid }
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(300))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    let (pendingLaunch, currentPid) = self.state.withLockUnchecked { s -> (CheckedContinuation<Void, any Error>?, Int32) in
                        let pending = s.launchContinuation
                        s.launchContinuation = nil
                        s.launchTimeoutTask = nil
                        return (pending, s.sideStorePid)
                    }
                    if let pendingLaunch {
                        pendingLaunch.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore failed to start in reasonable time"]))
                        self.terminateSideStoreIfNeeded(pid: currentPid)
                    }
                }
                state.withLockUnchecked { s in
                    s.launchContinuation = continuation
                    s.launchTimeoutTask = timeoutTask
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let currentClient = state.withLockUnchecked { s -> (any RefreshClient)? in
                s.refreshContinuation = continuation
                return s.client
            }
            if let currentClient {
                currentClient.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
            } else {
                let pending = state.withLockUnchecked { s -> CheckedContinuation<Void, any Error>? in
                    let cont = s.refreshContinuation
                    s.refreshContinuation = nil
                    return cont
                }
                pending?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore XPC connection unavailable"]))
            }
        }
    }
    
    func updateProgress(_ value: Double) {
        let currentProgress = state.withLockUnchecked { $0.progress }
        currentProgress?.completedUnitCount = Int64(value * 100)
    }
    
    func finish(_ error: String?) {
        let continuation = state.withLockUnchecked { s -> CheckedContinuation<Void, any Error>? in
            let cont = s.refreshContinuation
            s.refreshContinuation = nil
            return cont
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
        } else {
            continuation.resume()
        }
    }
    
    func onConnection(_ connection: NSXPCConnection) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        let proxy = connection.remoteObjectProxy as? any RefreshClient
        state.withLockUnchecked { $0.client = proxy }
    }
    
    func finishedLaunching() {
        let (continuation, timeoutTask) = state.withLockUnchecked { s -> (CheckedContinuation<Void, any Error>?, Task<Void, Never>?) in
            let cont = s.launchContinuation
            let task = s.launchTimeoutTask
            s.launchContinuation = nil
            s.launchTimeoutTask = nil
            return (cont, task)
        }
        timeoutTask?.cancel()
        continuation?.resume()
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}

//
//  LaunchAppExtension.swift
//  LaunchAppExtension
//
//  Created by s s on 2026/1/23.
//

import AppIntents
import Foundation
import UIKit

private struct LaunchAppExtensionError: LocalizedError, CustomLocalizedStringResourceConvertible, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

private actor LaunchExtensionCoordinator {
    static let shared = LaunchExtensionCoordinator()
    private var ext: NSExtension?

    func openURL(launchURL: URL, classicMode: UInt?) async throws {
        let extensionInstance: NSExtension
        if let existing = ext {
            extensionInstance = existing
        } else {
            do {
                let baseID = ((Bundle.main.bundleIdentifier ?? "") as NSString).deletingPathExtension as NSString
                let created = try NSExtension(identifier: baseID.appendingPathExtension("ShareExtension"))
                ext = created
                extensionInstance = created
            } catch {
                NSLog("Failed to start extension \(error)")
                throw LaunchAppExtensionError("Failed to start extension \(error). To use the Launch App shortcut, reinstall LiveContainer with LaunchAppExtension and ShareExtension installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension.")
            }
        }
        var launchOptions: [String: Any] = ["url": launchURL]
        if let classicMode {
            launchOptions["classicMode"] = classicMode
        }
        let extensionItem = NSExtensionItem()
        extensionItem.userInfo = launchOptions
        await extensionInstance.beginRequest(withInputItems: [extensionItem])
    }
}

struct LaunchAppExtension: AppIntent {
    static var title: LocalizedStringResource { "Launch App" }
    static var description: IntentDescription { "This action directly launches an app in normal mode in LiveContainer. To get the launch URL, open LiveContainer, hold the app, tap \"Add to Home Screen\" -> \"Copy Launch URL\"" }
    @Parameter(title: "Launch URL")
    var launchURL: URL

    func forEachInstalledLC(schemes: [String] = LCSharedUtils.lcUrlSchemes() ?? [], isFree: Bool, block: (String, inout Bool) -> Void) {
        for scheme in schemes {
            // Check if the app is installed
            guard let url = URL(string: "\(scheme)://"),
                  lsApplicationWorkspaceCanOpenURL(url) else {
                continue
            }
            
            // Check shared utility logic
            if isFree && LCSharedUtils.isLCScheme(inUse: scheme) {
                continue
            }
            
            var shouldBreak = false
            block(scheme, &shouldBreak)
            
            if shouldBreak {
                break
            }
        }
    }

    func firstFreeInstalledLC(preferredScheme: String?) -> String? {
        var schemeToLaunch: String? = nil
        
        var schemes = LCSharedUtils.lcUrlSchemes() ?? []
        if let preferredScheme {
            schemes.removeAll { $0 == preferredScheme }
            schemes.insert(preferredScheme, at: 0)
        }
        
        forEachInstalledLC(schemes: schemes, isFree: true) { scheme, stop in
            schemeToLaunch = scheme
            stop = true
        }
        return schemeToLaunch
    }

    func openURL(launchURL: URL, classicMode: UInt? = nil) async throws {
        try await LaunchExtensionCoordinator.shared.openURL(launchURL: launchURL, classicMode: classicMode)
    }
    
    func perform() async throws -> some IntentResult {
        // sanitize url
        let normalizedLaunchScheme = launchURL.scheme?.lowercased()
        var isLiveContainerURL = normalizedLaunchScheme == "livecontainer"
        let preferredScheme = isLiveContainerURL ? nil : (normalizedLaunchScheme == "livecontainer1" ? "livecontainer" : normalizedLaunchScheme)
        
        if let preferredScheme, let schemes = LCSharedUtils.lcUnorderedUrlSchemes() {
            isLiveContainerURL = schemes.contains(preferredScheme)
        }
        
        if !isLiveContainerURL && normalizedLaunchScheme != "sidestore" {
            throw LaunchAppExtensionError("Not a livecontainer URL!")
        }
        
        guard
            let appGroupId = LCSharedUtils.appGroupID(),
            let lcSharedDefaults = UserDefaults(suiteName: appGroupId)
        else {
            throw LaunchAppExtensionError("lcSharedDefaults failed to initialize, because no app group was found. Did you sign LiveContainer correctly?")
        }
        
        if normalizedLaunchScheme == "sidestore" {
            lcSharedDefaults.set("livecontainer", forKey: "LCLaunchExtensionScheme")
            lcSharedDefaults.set("builtinSideStore", forKey: "LCLaunchExtensionBundleID")
            lcSharedDefaults.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
            try await openURL(launchURL: launchURL)
            return .result()
        }
        
        if launchURL.host != "livecontainer-launch" {
            throw LaunchAppExtensionError("Not a livecontainer launch URL!")
        }

        var bundleId: String? = nil
        var containerName: String? = nil
        var forceJIT: Bool = false
        guard var components = URLComponents(url: launchURL, resolvingAgainstBaseURL: false) else {
            throw LaunchAppExtensionError("URLComponents failed to initialize.")
        }
        
        for queryItem in components.queryItems ?? [] {
            if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                bundleId = bundleId1
            } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                guard Self.isSafeContainerFolderName(containerName1) else {
                    throw LaunchAppExtensionError("Invalid container-folder-name parameter.")
                }
                containerName = containerName1
            } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                if forceJIT1 == "true" {
                    forceJIT = true
                } else if forceJIT1 == "false" {
                    forceJIT = false
                }
            }
        }
        guard let bundleId else {
            throw LaunchAppExtensionError("No bundle-name parameter found.")
        }

        // Look up read-only launch catalog published by primary LiveContainer (no private Documents access needed).
        var isSharedApp = false
        var catalogEntry: [String: Any]? = (lcSharedDefaults.dictionary(forKey: "LCLaunchAppCatalog")?[bundleId] as? [String: Any])
        if let catalogEntry {
            isSharedApp = catalogEntry["isShared"] as? Bool ?? false
        } else if let sharedBundle = LCSharedUtils.findBundle(withBundleId: bundleId, isSharedAppOut: &isSharedApp),
                  isSharedApp,
                  let appInfoURL = sharedBundle.url(forResource: "LCAppInfo", withExtension: "plist"),
                  let data = try? Data(contentsOf: appInfoURL),
                  let rawDict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            catalogEntry = rawDict
        }

        guard let catalogEntry else {
            // App metadata is not in shared catalog; forward the URL cleanly to primary LiveContainer.
            try await openURL(launchURL: launchURL)
            return .result()
        }

        let isHiden = catalogEntry["isHidden"] as? Bool ?? false
        let isLocked = catalogEntry["isLocked"] as? Bool ?? false
        let isJITNeeded = catalogEntry["isJITNeeded"] as? Bool ?? false

        var schemeToLaunch: String? = nil
        // if containerName is not specified, use LCDataUUID as default
        if containerName == nil, let defaultContainer = catalogEntry["LCDataUUID"] as? String,
           Self.isSafeContainerFolderName(defaultContainer) {
            containerName = defaultContainer
        }
        
        var newLaunch = false
        var allowClassicMode = false
        // if the container is running in a lc, use its scheme, otherwise find free one
        if var runningScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: containerName) {
            if(runningScheme.hasSuffix("liveprocess")) {
                runningScheme = (runningScheme as NSString).deletingPathExtension
            }
            schemeToLaunch = runningScheme
            allowClassicMode = true
        } else {
            newLaunch = true
            if isSharedApp {
                schemeToLaunch = firstFreeInstalledLC(preferredScheme: preferredScheme)
                allowClassicMode = schemeToLaunch != nil
            } else {
                schemeToLaunch = "livecontainer"
                allowClassicMode = !LCSharedUtils.isLCScheme(inUse: "livecontainer")
            }
        }

        guard let schemeToLaunch else {
            // no free lc, we just open the lc1 and let the user to decide what to do
            try await openURL(launchURL: launchURL)
            return .result()
        }
        
        let willDirectLaunch = newLaunch && !forceJIT && !isHiden && !isLocked && !isJITNeeded
        if willDirectLaunch {
            lcSharedDefaults.removeObject(forKey: "LCLaunchExtensionLaunchURL")
            lcSharedDefaults.set(schemeToLaunch, forKey: "LCLaunchExtensionScheme")
            lcSharedDefaults.set(bundleId, forKey: "LCLaunchExtensionBundleID")
            lcSharedDefaults.set(containerName, forKey: "LCLaunchExtensionContainerName")
            lcSharedDefaults.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
        }

        components.scheme = schemeToLaunch
        guard let newURL = components.url else {
            throw LaunchAppExtensionError("unable to construct new url")
        }

        let classicMode: UInt?
        if allowClassicMode && (!newLaunch || willDirectLaunch) {
            if let directDefault = catalogEntry["defaultClassicMode"] as? NSNumber {
                classicMode = (catalogEntry["classicMode"] as? Bool ?? false) ? directDefault.uintValue : 0
            } else {
                classicMode = (catalogEntry["classicMode"] as? Bool ?? false)
                    ? ((catalogEntry["LCClassicModeCache"] as? [String: Any])?["defaultClassicMode"] as? NSNumber)?.uintValue ?? 0
                    : 0
            }
        } else {
            classicMode = nil
        }
        try await openURL(launchURL: newURL, classicMode: classicMode)
        return .result()
    }

    private static func isSafeContainerFolderName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
}

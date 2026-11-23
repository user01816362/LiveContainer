//
//  LCTweakMachOInspector.swift
//  LiveContainerSwiftUI
//
//  Validates arm64 iOS Mach-O compatibility across thin/universal slices and analyzes
//  Substrate, ElleKit, Substitute, libhooker, and third-party jailbreak dependencies.
//

import Foundation

enum LCTweakMachOInspector {
    nonisolated static let canonicalSubstrateLoadPath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"

    private nonisolated static let substrateAliases: Set<String> = [
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
        "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "@rpath/libsubstrate.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libellekit.dylib",
        "@rpath/libellekit.dylib",
        "/usr/lib/libsubstitute.dylib",
        "/var/jb/usr/lib/libsubstitute.dylib",
        "@rpath/libsubstitute.dylib",
        "/usr/lib/libhooker.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
        "@rpath/libhooker.dylib"
    ]

    private nonisolated static let knownJailbreakLibTokens: [String] = [
        "substrate", "ellekit", "substitute", "libhooker", "libroot",
        "libsandy", "libcolorpicker", "libprefs", "libhdev", "rocketbootstrap",
        "cephei", "mryipc", "spark", "gcuniversal", "applist", "altlist",
        "alderis", "orion", "blackjack", "libkrw", "dimentio"
    ]

    private nonisolated static let knownJailbreakFrameworkDisplayNames: [(token: String, name: String)] = [
        ("orion.framework", "Orion.framework"),
        ("cepheiui.framework", "CepheiUI.framework"),
        ("cepheiprefs.framework", "CepheiPrefs.framework"),
        ("cephei.framework", "Cephei.framework"),
        ("alderis.framework", "Alderis.framework"),
        ("altlist.framework", "AltList.framework"),
        ("rocketbootstrap.framework", "RocketBootstrap.framework"),
        ("librocketbootstrap", "RocketBootstrap"),
        ("libroot", "libroot"),
        ("libsandy", "libSandy"),
        ("libcolorpicker", "libcolorpicker"),
        ("sparkcolourpicker", "SparkColourPicker"),
        ("libprefs", "libprefs")
    ]

    nonisolated static func isSubstrateAlias(_ path: String) -> Bool {
        if substrateAliases.contains(path) {
            return true
        }
        let lower = path.lowercased()
        return lower.hasSuffix("/cydiasubstrate.framework/cydiasubstrate") ||
            lower.hasSuffix("/libsubstrate.dylib") ||
            lower.hasSuffix("/libellekit.dylib") ||
            lower.hasSuffix("/libsubstitute.dylib") ||
            lower.hasSuffix("/libhooker.dylib")
    }

    nonisolated static func knownJailbreakDependencyName(for path: String) -> String? {
        let lower = path.lowercased()
        return knownJailbreakFrameworkDisplayNames.first(where: { lower.contains($0.token) })?.name
    }

    nonisolated static func isAppleSystemLibraryPath(_ path: String) -> Bool {
        if path.hasPrefix("/System/Library/") || path.hasPrefix("/System/Cryptexes/") {
            return true
        }
        if path.hasPrefix("/usr/lib/") {
            let lowerName = (path as NSString).lastPathComponent.lowercased()
            let lowerFull = path.lowercased()
            if knownJailbreakLibTokens.contains(where: { lowerName.contains($0) || lowerFull.contains($0) }) {
                return false
            }
            return true
        }
        return false
    }

    nonisolated static func isIOSDevicePlatform(_ platformName: String?) -> Bool {
        guard let platformName, !platformName.isEmpty else {
            return true
        }
        let lower = platformName.lowercased()
        if lower.contains("simulator") || lower.contains("macos") || lower.contains("catalyst")
            || lower.contains("watchos") || lower.contains("tvos") {
            return false
        }
        return true
    }

    nonisolated static func matchesSiblingPayload(_ path: String, siblingKeys: Set<String>) -> Bool {
        guard !siblingKeys.isEmpty else { return false }
        let parts = path.split(separator: "/").map(String.init)
        return siblingKeys.contains(where: { parts.contains($0) })
    }

    /// Inspects a `.dylib` file or `.framework` bundle across slices for arm64 iOS compatibility
    /// and dependency requirements.
    nonisolated static func inspectBinary(at url: URL, siblingKeys: Set<String> = []) -> LCTweakCompatibilityReport {
        let execURL = LCBoundedFileReader.resolveMachOExecutableURL(for: url) ?? url
        guard let reader = try? LCBoundedFileReader(url: execURL),
              let slices = try? LCMachOParser.enumerateSlices(reader: reader),
              !slices.isEmpty else {
            return .nonMachO
        }

        var architectures: [String] = []
        var platforms = Set<String>()
        var hasArm64iOSSlice = false
        var hasAnyArm64Slice = false
        var needsSubstrate = false
        var substrateDeps = Set<String>()
        var knownJBDeps = Set<String>()
        var unresolvedDeps = Set<String>()
        var loadPaths: [String] = []

        // Parse primary slice first, plus any arm64/arm64e slices if this is a fat binary
        // so fat binaries don't misreport only one slice's platform.
        var indicesToInspect: [Int] = []
        if slices.count == 1 {
            indicesToInspect = [0]
        } else {
            indicesToInspect = slices.indices.filter {
                slices[$0].is64Bit && slices[$0].architectureName.lowercased().hasPrefix("arm64")
            }
            if indicesToInspect.isEmpty {
                indicesToInspect = [0]
            }
        }

        for slice in slices where !architectures.contains(slice.architectureName) {
            architectures.append(slice.architectureName)
        }

        for idx in indicesToInspect {
            guard let ctx = try? LCMachOParser.parseSliceContext(at: execURL, sliceIndex: idx) else {
                continue
            }
            let slice = slices[idx]
            let platform = ctx.overview.header.platformName
            if let platform, !platform.isEmpty {
                platforms.insert(platform)
            }
            let sliceIsArm64 = slice.is64Bit && slice.architectureName.lowercased().hasPrefix("arm64")
            if sliceIsArm64 {
                hasAnyArm64Slice = true
                if isIOSDevicePlatform(platform) {
                    hasArm64iOSSlice = true
                }
            }

            if loadPaths.isEmpty {
                loadPaths = ctx.overview.dylibs
                    .filter { $0.kind != .id }
                    .map(\.path)
            }

            for dep in ctx.overview.dylibs where dep.kind != .id {
                if isSubstrateAlias(dep.path) {
                    needsSubstrate = true
                    substrateDeps.insert(dep.path)
                    continue
                }
                if isAppleSystemLibraryPath(dep.path) {
                    continue
                }
                if matchesSiblingPayload(dep.path, siblingKeys: siblingKeys) {
                    continue
                }
                if let jbName = knownJailbreakDependencyName(for: dep.path) {
                    knownJBDeps.insert(jbName)
                    unresolvedDeps.insert(dep.path)
                    continue
                }
                if dep.path.hasPrefix("@") {
                    continue
                }
                unresolvedDeps.insert(dep.path)
            }
        }

        let isSimulatorOrMacOnly = hasAnyArm64Slice && !hasArm64iOSSlice
        var warnings: [String] = []
        if isSimulatorOrMacOnly {
            let platformDesc = platforms.sorted().joined(separator: ", ")
            warnings.append("Built for \(platformDesc.isEmpty ? "Simulator/macOS" : platformDesc), not iOS device.")
        } else if !hasArm64iOSSlice {
            warnings.append("Missing 64-bit arm64 iOS slice (found: \(architectures.joined(separator: ", "))).")
        }
        if !knownJBDeps.isEmpty {
            warnings.append("Requires jailbreak support library: \(knownJBDeps.sorted().joined(separator: ", ")).")
        }
        if !unresolvedDeps.isEmpty && knownJBDeps.isEmpty {
            warnings.append("External dependency path(s): \(unresolvedDeps.sorted().joined(separator: ", ")).")
        }

        return LCTweakCompatibilityReport(
            isMachOValid: true,
            hasArm64iOSSlice: hasArm64iOSSlice,
            architectures: architectures,
            platforms: platforms.sorted(),
            isSimulatorOrMacOnly: isSimulatorOrMacOnly,
            needsSubstrate: needsSubstrate,
            substrateDependencies: substrateDeps.sorted(),
            unresolvedDependencies: unresolvedDeps.sorted(),
            knownJailbreakDependencies: knownJBDeps.sorted(),
            loadPaths: loadPaths,
            warnings: warnings
        )
    }
}

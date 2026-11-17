//
//  LCProfileLeakAnalyzer.swift
//  LiveContainerSwiftUI
//
//  Smart Leak & Consistency Analyzer that inspects a container's spoof
//  configuration, runtime interception telemetry, and host environment across
//  Network, WebKit/JS, and In-App Hardware/OS vectors.
//

import Foundation
import SwiftUI
import UIKit

/// Surface vector through which real host identity or device contradictions can leak.
enum LCLeakVector: String, CaseIterable, Identifiable {
    case network = "Network & HTTP"
    case webkit = "WebKit & Browser JS"
    case hardware = "In-App Hardware & Kernel"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .network: return "network.badge.shield.half.filled"
        case .webkit: return "safari"
        case .hardware: return "cpu"
        }
    }
}

/// Severity of an identified leak risk or fingerprint contradiction.
enum LCLeakSeverity: Int, Comparable {
    case info = 0
    case warning = 1
    case critical = 2

    static func < (lhs: LCLeakSeverity, rhs: LCLeakSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    var badgeText: String {
        switch self {
        case .critical: return "Leak"
        case .warning: return "Risk"
        case .info: return "Note"
        }
    }
}

/// Single diagnostic finding produced by ``LCProfileLeakAnalyzer``.
struct LCProfileLeakFinding: Identifiable, Hashable {
    let id = UUID()
    let vector: LCLeakVector
    let severity: LCLeakSeverity
    let title: String
    let detail: String
    let isAutoFixable: Bool
}

/// Overall protection summary across all three leak vectors.
struct LCProfileAuditReport {
    enum OverallStatus {
        case disabled
        case bypassExposed
        case leaksDetected
        case risksPresent
        case protectedAndCoherent

        var title: String {
            switch self {
            case .disabled: return "Spoof Inactive — Host Exposed"
            case .bypassExposed: return "TweakLoader Disabled — All Hooks Bypassed"
            case .leaksDetected: return "Real Device Data Leaks Detected"
            case .risksPresent: return "Consistency Risks Found"
            case .protectedAndCoherent: return "Protected & Coherent"
            }
        }

        var color: Color {
            switch self {
            case .disabled, .bypassExposed, .leaksDetected: return .red
            case .risksPresent: return .orange
            case .protectedAndCoherent: return .green
            }
        }

        var symbolName: String {
            switch self {
            case .disabled, .bypassExposed, .leaksDetected:
                return "exclamationmark.shield.fill"
            case .risksPresent:
                return "shield.lefthalf.filled"
            case .protectedAndCoherent:
                return "checkmark.shield.fill"
            }
        }
    }

    let status: OverallStatus
    let findings: [LCProfileLeakFinding]
    let telemetry: LCProfileRuntimeTelemetry?
    let matchedSpec: LCDeviceModelSpec?
    let realHostMachine: String

    func findings(for vector: LCLeakVector) -> [LCProfileLeakFinding] {
        findings.filter { $0.vector == vector }.sorted { $0.severity > $1.severity }
    }

    var hasAutoFixableIssues: Bool {
        findings.contains(where: \.isAutoFixable)
    }

    var networkInterceptions: Int { telemetry?.networkInterceptions ?? 0 }
    var webkitInterceptions: Int { telemetry?.webkitInterceptions ?? 0 }
    var hardwareInterceptions: Int { telemetry?.hardwareInterceptions ?? 0 }
}

/// Analyzes ``LCContainer`` profiles for host-identity leakage, cross-API
/// contradictions, and app-breaking feature overrides across Network, WebKit,
/// and native hardware layers.
enum LCProfileLeakAnalyzer {
    /// Captures the unspoofed `uname().machine` identifier of the running host device.
    static func currentHostMachine() -> String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "" }
        let machine = uts.machine
        let machineSize = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: machineSize) { cstr in
                String(cString: cstr)
            }
        }
    }

    /// Evaluates a container configuration and returns a full three-vector audit report.
    static func analyze(container: LCContainer, dontInjectTweakLoader: Bool) -> LCProfileAuditReport {
        var findings: [LCProfileLeakFinding] = []
        let telemetry = container.loadTelemetrySnapshot()
        let hostMachine = (telemetry?.realHostMachine.isEmpty == false ? telemetry?.realHostMachine : nil) ?? currentHostMachine()
        let hostOSVersion = UIDevice.current.systemVersion
        let hostIDFV = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let hostLocale = Locale.current.identifier
        let hostTimeZone = TimeZone.current.identifier
        let hostName = ProcessInfo.processInfo.hostName

        let matchedSpec = LCDeviceModelSpec.find(
            variantId: container.spoofDeviceVariantId,
            hwMachine: container.spoofHardwareModel
        )

        if dontInjectTweakLoader {
            let detail = "Don't Inject TweakLoader is enabled in App Settings, so runtime network, WebKit, and kernel hooks never load."
            findings.append(LCProfileLeakFinding(vector: .network, severity: .critical, title: "Network Hooks Bypassed", detail: detail, isAutoFixable: false))
            findings.append(LCProfileLeakFinding(vector: .webkit, severity: .critical, title: "WebKit Hooks Bypassed", detail: detail, isAutoFixable: false))
            findings.append(LCProfileLeakFinding(vector: .hardware, severity: .critical, title: "Hardware & OS Hooks Bypassed", detail: detail, isAutoFixable: false))
            return LCProfileAuditReport(status: .bypassExposed, findings: findings, telemetry: telemetry, matchedSpec: matchedSpec, realHostMachine: hostMachine)
        }

        if !container.spoofProfileEnabled && !container.blockDeviceInfoReads && !container.strictTestMode {
            findings.append(LCProfileLeakFinding(
                vector: .hardware,
                severity: .info,
                title: "Spoof Profile Disabled",
                detail: "Apps read real host machine (\(hostMachine)), iOS \(hostOSVersion), IDFV, Metal GPU, and locale/time zone directly.",
                isAutoFixable: false
            ))
            return LCProfileAuditReport(status: .disabled, findings: findings, telemetry: telemetry, matchedSpec: matchedSpec, realHostMachine: hostMachine)
        }

        if container.spoofProfileEnabled {
            analyzeNetworkVector(
                container: container,
                hostName: hostName,
                findings: &findings
            )
            analyzeWebKitVector(
                container: container,
                matchedSpec: matchedSpec,
                findings: &findings
            )
            analyzeHardwareVector(
                container: container,
                matchedSpec: matchedSpec,
                hostMachine: hostMachine,
                hostOSVersion: hostOSVersion,
                hostIDFV: hostIDFV,
                hostLocale: hostLocale,
                hostTimeZone: hostTimeZone,
                findings: &findings
            )
        }

        let hasCritical = findings.contains { $0.severity == .critical }
        let hasWarning = findings.contains { $0.severity == .warning }
        let status: LCProfileAuditReport.OverallStatus
        if hasCritical {
            status = .leaksDetected
        } else if hasWarning {
            status = .risksPresent
        } else {
            status = .protectedAndCoherent
        }
        return LCProfileAuditReport(
            status: status,
            findings: findings,
            telemetry: telemetry,
            matchedSpec: matchedSpec,
            realHostMachine: hostMachine
        )
    }

    private static func analyzeNetworkVector(
        container: LCContainer,
        hostName: String,
        findings: inout [LCProfileLeakFinding]
    ) {
        if !container.spoofNetworkHeadersCategoryEnabled {
            findings.append(LCProfileLeakFinding(
                vector: .network,
                severity: .critical,
                title: "HTTP User-Agent Rewriting Disabled",
                detail: "Outgoing NSURLSession/CFNetwork requests expose the real hw.machine and iOS/Darwin version.",
                isAutoFixable: true
            ))
        } else if !container.isSpoofFeatureEnabled("networkHeaders.userAgent") {
            findings.append(LCProfileLeakFinding(
                vector: .network,
                severity: .critical,
                title: "User-Agent Override Feature Disabled",
                detail: "Granular override 'networkHeaders.userAgent' is OFF while spoofing hardware/OS.",
                isAutoFixable: true
            ))
        }

        if !container.spoofCustomUserAgent.isEmpty && !container.spoofHardwareModel.isEmpty {
            let ua = container.spoofCustomUserAgent
            if ua.contains("Android") && container.spoofDeviceModel.lowercased().contains("iphone") {
                findings.append(LCProfileLeakFinding(
                    vector: .network,
                    severity: .warning,
                    title: "Custom User-Agent Contradicts Device Model",
                    detail: "Custom HTTP User-Agent appears Android-based while native UIDevice/Metal APIs report Apple hardware.",
                    isAutoFixable: false
                ))
            }
        }

        if !container.spoofLocaleCategoryEnabled && container.spoofNetworkHeadersCategoryEnabled {
            findings.append(LCProfileLeakFinding(
                vector: .network,
                severity: .warning,
                title: "Accept-Language Mirrors Host Device",
                detail: "Locale & Time Zone category is OFF, so HTTP Accept-Language headers reveal the real system language.",
                isAutoFixable: false
            ))
        }

        if container.spoofNetworkEnvironmentCategoryEnabled && container.isSpoofFeatureEnabled("network.pathMonitor") {
            findings.append(LCProfileLeakFinding(
                vector: .network,
                severity: .warning,
                title: "NWPathMonitor Blocked (Connectivity Risk)",
                detail: "'Stop Path Monitoring' silently drops network reachability callbacks, which breaks offline/online detection in many apps.",
                isAutoFixable: true
            ))
        }

        if !container.spoofHostName.isEmpty && container.spoofHostName.caseInsensitiveCompare(hostName) == .orderedSame {
            findings.append(LCProfileLeakFinding(
                vector: .network,
                severity: .warning,
                title: "Hostname Matches Real Host",
                detail: "Spoofed hostname '\(container.spoofHostName)' matches the physical device hostname.",
                isAutoFixable: true
            ))
        }
    }

    private static func analyzeWebKitVector(
        container: LCContainer,
        matchedSpec: LCDeviceModelSpec?,
        findings: inout [LCProfileLeakFinding]
    ) {
        if !container.spoofWebViewCategoryEnabled {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .critical,
                title: "WebKit JS & Custom UA Spoofing Disabled",
                detail: "In-app WKWebView pages read real navigator.userAgent, screen dimensions, WebGL GPU, and Intl timezone.",
                isAutoFixable: true
            ))
            return
        }

        if !container.isSpoofFeatureEnabled("web.navigator") {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .critical,
                title: "WebKit Navigator/UA Override Off",
                detail: "WebKit HTTP navigation headers and navigator.* JS properties expose the real host device.",
                isAutoFixable: true
            ))
        }
        if !container.isSpoofFeatureEnabled("web.screen") {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .warning,
                title: "WebKit Screen Metrics Exposed",
                detail: "screen.width/height/devicePixelRatio will mismatch UIScreen.bounds if 'web.screen' is OFF.",
                isAutoFixable: true
            ))
        }
        if !container.isSpoofFeatureEnabled("web.webGL") {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .warning,
                title: "WebGL Unmasked Renderer Exposed",
                detail: "Canvas WebGL/WebGL2 queries can fingerprint the real physical Apple GPU if 'web.webGL' is OFF.",
                isAutoFixable: true
            ))
        }
        if !container.isSpoofFeatureEnabled("web.timeZone") && container.spoofLocaleCategoryEnabled && !container.spoofTimeZoneIdentifier.isEmpty {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .warning,
                title: "WebKit Time Zone Mismatch",
                detail: "Native TimeZone is spoofed to '\(container.spoofTimeZoneIdentifier)' while 'web.timeZone' is OFF.",
                isAutoFixable: true
            ))
        }
        if let matchedSpec,
           !matchedSpec.isPad && container.spoofCustomUserAgent.lowercased().contains("ipad") {
            findings.append(LCProfileLeakFinding(
                vector: .webkit,
                severity: .warning,
                title: "Phone Screen vs iPad WebKit UA",
                detail: "Hardware model is iPhone but Custom User-Agent advertises iPad.",
                isAutoFixable: false
            ))
        }
    }

    private static func analyzeHardwareVector(
        container: LCContainer,
        matchedSpec: LCDeviceModelSpec?,
        hostMachine: String,
        hostOSVersion: String,
        hostIDFV: String,
        hostLocale: String,
        hostTimeZone: String,
        findings: inout [LCProfileLeakFinding]
    ) {
        if container.spoofIdentityCategoryEnabled {
            if !hostMachine.isEmpty && container.spoofHardwareModel == hostMachine && !container.rotateSpoofProfileOnLaunch {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .critical,
                    title: "Hardware Model Matches Real Device",
                    detail: "Container hw.machine ('\(hostMachine)') is identical to the physical host device.",
                    isAutoFixable: true
                ))
            }
            if !container.spoofIdentifierForVendor {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .critical,
                    title: "Real IDFV Exposed",
                    detail: "UIDevice.identifierForVendor is not spoofed; apps can track this container across reinstalls via real vendor ID.",
                    isAutoFixable: true
                ))
            } else if let spoofedIDFV = container.spoofedIdentifier,
                      !hostIDFV.isEmpty,
                      spoofedIDFV.caseInsensitiveCompare(hostIDFV) == .orderedSame {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .critical,
                    title: "Spoofed IDFV Equals Host IDFV",
                    detail: "Container Vendor ID matches LiveContainer's real host IDFV.",
                    isAutoFixable: true
                ))
            }
        } else {
            findings.append(LCProfileLeakFinding(
                vector: .hardware,
                severity: .critical,
                title: "Device Identity Category Disabled",
                detail: "hw.machine, hw.model, UIDevice.name, and IDFV leak the physical host device.",
                isAutoFixable: true
            ))
        }

        if let spec = matchedSpec {
            if !container.spoofBoardModel.isEmpty && container.spoofBoardModel != spec.hwModel {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .critical,
                    title: "Board Config Contradicts hw.machine",
                    detail: "\(spec.marketingName) (\(spec.hwMachine)) expects board '\(spec.hwModel)', but '\(container.spoofBoardModel)' is set.",
                    isAutoFixable: true
                ))
            }
            let expectedMemoryBytes = Int64(spec.physicalMemoryGB) * 1_073_741_824
            if container.spoofPhysicalMemory != expectedMemoryBytes || container.spoofProcessorCount != spec.cpuCores {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .warning,
                    title: "CPU / RAM Does Not Match \(spec.marketingName)",
                    detail: "Expected \(spec.cpuCores) cores and \(spec.physicalMemoryGB) GB RAM; current profile reports \(container.spoofProcessorCount) cores / \(container.spoofPhysicalMemory / 1_073_741_824) GB.",
                    isAutoFixable: true
                ))
            }
            if abs(container.spoofScreenWidth - spec.pixelWidth) > 1 ||
                abs(container.spoofScreenHeight - spec.pixelHeight) > 1 ||
                container.spoofMaximumFramesPerSecond != spec.maxFPS {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .warning,
                    title: "Display Geometry Contradicts \(spec.marketingName)",
                    detail: "Expected \(Int(spec.pixelWidth))×\(Int(spec.pixelHeight)) @ \(spec.maxFPS) Hz.",
                    isAutoFixable: true
                ))
            }
            if container.spoofGraphicsCategoryEnabled && container.spoofGPUName != spec.gpuName {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .warning,
                    title: "Metal GPU Name Mismatch",
                    detail: "\(spec.marketingName) uses '\(spec.gpuName)' in Metal, not '\(container.spoofGPUName)'.",
                    isAutoFixable: true
                ))
            }
            if let osMajor = Int(container.spoofSystemVersion.split(separator: ".").first ?? ""), osMajor < spec.minOSMajor {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .critical,
                    title: "Impossible OS Version for \(spec.marketingName)",
                    detail: "\(spec.marketingName) shipped with iOS \(spec.minOSMajor)+; spoofing iOS \(container.spoofSystemVersion) fails device-support checks.",
                    isAutoFixable: true
                ))
            }
        }

        if let osMajor = Int(container.spoofSystemVersion.split(separator: ".").first ?? ""),
           container.spoofSystemCategoryEnabled {
            let expectedDarwin = Int(LCExpectedDarwinMajorForOSMajor(Int32(osMajor)))
            let expectedPrefix = "Darwin Kernel Version \(expectedDarwin)."
            if !container.spoofKernelVersion.hasPrefix(expectedPrefix) && !container.spoofKernelVersion.isEmpty {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .warning,
                    title: "Darwin Kernel / OS Version Mismatch",
                    detail: "iOS \(osMajor) pairs with Darwin \(expectedDarwin).x, not '\(container.spoofKernelVersion)'.",
                    isAutoFixable: true
                ))
            }
        }

        if container.spoofLocaleCategoryEnabled {
            if container.spoofLocaleIdentifier.isEmpty {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .warning,
                    title: "Locale Identifier Empty (Uses Host \(hostLocale))",
                    detail: "Set a Locale ID so NSLocale and preferredLanguages do not fall back to the host locale.",
                    isAutoFixable: true
                ))
            } else if container.spoofLocaleIdentifier == hostLocale && container.spoofTimeZoneIdentifier == hostTimeZone && !container.rotateSpoofProfileOnLaunch {
                findings.append(LCProfileLeakFinding(
                    vector: .hardware,
                    severity: .info,
                    title: "Locale & Time Zone Match Host",
                    detail: "Profile geo ('\(hostLocale)', '\(hostTimeZone)') matches physical device settings.",
                    isAutoFixable: false
                ))
            }
        }

        if container.spoofBatteryCategoryEnabled &&
            container.spoofLowPowerModeEnabled &&
            container.spoofBatteryState == UIDevice.BatteryState.full.rawValue {
            findings.append(LCProfileLeakFinding(
                vector: .hardware,
                severity: .warning,
                title: "Power State Contradiction",
                detail: "Low Power Mode is ON while battery state reports 100% Full.",
                isAutoFixable: true
            ))
        }

        if container.spoofAppPrivacyCategoryEnabled && container.isSpoofFeatureEnabled("app.fonts") {
            findings.append(LCProfileLeakFinding(
                vector: .hardware,
                severity: .info,
                title: "Font Enumeration Substituted",
                detail: "UIFont.familyNames returns a safe neutral baseline list instead of installed host fonts.",
                isAutoFixable: false
            ))
        }

        if container.rotateSpoofProfileOnLaunch && !container.strictAutoWipeOnExit {
            findings.append(LCProfileLeakFinding(
                vector: .hardware,
                severity: .info,
                title: "Keychain Persists Across Rotations",
                detail: "Rotate on Launch assigns a fresh IDFV each boot, but apps storing tokens in Keychain can still link launches unless you Clean Up Keychain or use Strict Ephemeral mode.",
                isAutoFixable: false
            ))
        }
    }

    /// Repairs all automatically fixable coherence contradictions and host-identity
    /// collisions on `container` using the verified catalog.
    static func autoFixCoherence(for container: LCContainer) {
        container.spoofIdentityCategoryEnabled = true
        container.spoofSystemCategoryEnabled = true
        container.spoofDisplayCategoryEnabled = true
        container.spoofNetworkHeadersCategoryEnabled = true
        container.spoofWebViewCategoryEnabled = true

        var overrides = container.spoofFeatureOverrides
        overrides["networkHeaders.userAgent"] = true
        overrides["web.navigator"] = true
        overrides["web.screen"] = true
        overrides["web.webGL"] = true
        overrides["web.timeZone"] = true
        overrides["network.pathMonitor"] = false
        overrides["graphics.allFamilies"] = false
        container.spoofFeatureOverrides = overrides
        container.spoofGraphicsSupportsAllFamilies = false

        let hostMachine = currentHostMachine()
        let hostIDFV = UIDevice.current.identifierForVendor?.uuidString ?? ""

        var spec = LCDeviceModelSpec.find(
            variantId: container.spoofDeviceVariantId,
            hwMachine: container.spoofHardwareModel
        )
        if spec == nil || (!hostMachine.isEmpty && spec?.hwMachine == hostMachine) {
            let candidates = LCDeviceModelSpec.all.filter { !$0.isPad && $0.hwMachine != hostMachine }
            spec = candidates.first ?? LCDeviceModelSpec.all[0]
        }
        if let resolvedSpec = spec {
            container.applyHardwareSpec(resolvedSpec)
        }

        if !container.spoofIdentifierForVendor ||
            container.spoofedIdentifier == nil ||
            (!hostIDFV.isEmpty && container.spoofedIdentifier?.caseInsensitiveCompare(hostIDFV) == .orderedSame) {
            container.spoofIdentifierForVendor = true
            container.spoofedIdentifier = UUID().uuidString
        }

        if container.spoofHostName.isEmpty ||
            container.spoofHostName.caseInsensitiveCompare(ProcessInfo.processInfo.hostName) == .orderedSame {
            container.spoofHostName = (spec?.marketingName ?? "iPhone")
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
        }

        if container.spoofLocaleCategoryEnabled &&
            (container.spoofLocaleIdentifier.isEmpty || container.spoofTimeZoneIdentifier.isEmpty) {
            let geo = LCDeviceModelSpec.coherentGeoPair()
            container.spoofLocaleIdentifier = geo.locale
            container.spoofTimeZoneIdentifier = geo.timeZone
            if container.spoofRadioAccessTechnology.isEmpty {
                container.spoofRadioAccessTechnology = geo.radio
            }
        }

        if container.spoofLowPowerModeEnabled && container.spoofBatteryState == UIDevice.BatteryState.full.rawValue {
            container.spoofLowPowerModeEnabled = false
        }
    }
}

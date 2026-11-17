//
//  LCProfilePreset.swift
//  LiveContainerSwiftUI
//
//  Verified Apple hardware catalog wrapper, reusable spoof profile presets,
//  and App Group-backed storage for custom presets and the global default
//  new-container profile policy.
//

import Foundation
import SwiftUI
import UIKit

/// Swift representation of a verified Apple hardware configuration sourced from
/// ``LCDeviceProfileCatalog.h`` (`LCDeviceHardwareSpec`).
struct LCDeviceModelSpec: Identifiable, Hashable, Sendable {
    /// UI grouping categories for the hardware picker.
    enum GroupKind: String, CaseIterable, Identifiable {
        case iPhone18AndDuo = "iPhone 18 & Duo (2026–2027)"
        case iPhone17AndAir = "iPhone 17 & Air"
        case iPhone16AndEarlier = "iPhone 16 / 15 / 14"
        case iPad = "iPad Pro & Air"

        var id: String { rawValue }
    }

    let variantId: String
    let marketingName: String
    let hwMachine: String
    let hwModel: String
    let deviceModel: String
    let gpuName: String
    let cpuCores: Int
    let physicalMemoryGB: Int
    let gpuWorkingSetGB: Int
    let supportsRayTracing: Bool
    let pixelWidth: Double
    let pixelHeight: Double
    let pointWidth: Double
    let pointHeight: Double
    let scale: Double
    let nativeScale: Double
    let maxFPS: Int
    let horizontalSizeClass: Int
    let verticalSizeClass: Int
    let userInterfaceIdiom: Int
    let safeAreaTop: Double
    let safeAreaBottom: Double
    let minOSMajor: Int

    var id: String { variantId }

    var isPad: Bool { userInterfaceIdiom == 1 }

    var groupKind: GroupKind {
        if isPad { return .iPad }
        if minOSMajor >= 27 { return .iPhone18AndDuo }
        if minOSMajor == 26 { return .iPhone17AndAir }
        return .iPhone16AndEarlier
    }

    var systemName: String {
        isPad ? "iPadOS" : "iOS"
    }

    var shortSummary: String {
        "\(hwMachine) · \(hwModel) · \(physicalMemoryGB) GB · \(Int(pixelWidth))×\(Int(pixelHeight)) @\(maxFPS)Hz"
    }

    /// All verified Apple hardware models bridged directly from `LCDeviceProfileCatalog.h`.
    static let all: [LCDeviceModelSpec] = {
        let count = LCDeviceHardwareSpecCount()
        var items: [LCDeviceModelSpec] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let ptr = LCDeviceHardwareSpecAt(index) else { continue }
            let spec = ptr.pointee
            items.append(LCDeviceModelSpec(
                variantId: String(cString: spec.variantId),
                marketingName: String(cString: spec.marketingName),
                hwMachine: String(cString: spec.hwMachine),
                hwModel: String(cString: spec.hwModel),
                deviceModel: String(cString: spec.deviceModel),
                gpuName: String(cString: spec.gpuName),
                cpuCores: Int(spec.cpuCores),
                physicalMemoryGB: Int(spec.physicalMemoryGB),
                gpuWorkingSetGB: Int(spec.gpuWorkingSetGB),
                supportsRayTracing: spec.supportsRayTracing,
                pixelWidth: spec.pixelWidth,
                pixelHeight: spec.pixelHeight,
                pointWidth: spec.pointWidth,
                pointHeight: spec.pointHeight,
                scale: spec.scale,
                nativeScale: spec.nativeScale,
                maxFPS: Int(spec.maxFPS),
                horizontalSizeClass: Int(spec.horizontalSizeClass),
                verticalSizeClass: Int(spec.verticalSizeClass),
                userInterfaceIdiom: Int(spec.userInterfaceIdiom),
                safeAreaTop: spec.safeAreaTop,
                safeAreaBottom: spec.safeAreaBottom,
                minOSMajor: Int(spec.minOSMajor)
            ))
        }
        return items
    }()

    /// Looks up a catalog model preferring exact `variantId` before falling back to `hwMachine`.
    static func find(variantId: String? = nil, hwMachine: String? = nil) -> LCDeviceModelSpec? {
        if let variantId, !variantId.isEmpty,
           let exact = all.first(where: { $0.variantId == variantId }) {
            return exact
        }
        if let hwMachine, !hwMachine.isEmpty {
            return all.first(where: { $0.hwMachine == hwMachine })
        }
        return nil
    }

    /// Picks a coherent random device matching the requested idiom.
    static func random(isPad: Bool) -> LCDeviceModelSpec {
        let pool = all.filter { $0.isPad == isPad }
        return pool.randomElement() ?? all[0]
    }

    /// Returns a geographically matched `(locale, timeZone, radioTech)` tuple to avoid geo contradictions.
    static func coherentGeoPair() -> (locale: String, timeZone: String, radio: String) {
        let pairs: [(String, String, String)] = [
            ("en_US", "America/New_York", "CTRadioAccessTechnologyNRNSA"),
            ("en_US", "America/Los_Angeles", "CTRadioAccessTechnologyNR"),
            ("en_GB", "Europe/London", "CTRadioAccessTechnologyNRNSA"),
            ("en_CA", "America/Toronto", "CTRadioAccessTechnologyLTE"),
            ("en_AU", "Australia/Sydney", "CTRadioAccessTechnologyNRNSA"),
            ("de_DE", "Europe/Berlin", "CTRadioAccessTechnologyLTE"),
            ("fr_FR", "Europe/Paris", "CTRadioAccessTechnologyNRNSA"),
            ("ja_JP", "Asia/Tokyo", "CTRadioAccessTechnologyNR"),
            ("ko_KR", "Asia/Seoul", "CTRadioAccessTechnologyNR"),
            ("ar_SA", "Asia/Riyadh", "CTRadioAccessTechnologyNR")
        ]
        return pairs.randomElement() ?? pairs[0]
    }
}

/// Global policy controlling how newly created app containers receive spoof profiles.
enum LCGlobalDefaultProfileMode: String, Codable, CaseIterable, Identifiable {
    case off
    case randomCoherentPhone
    case preset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off (Manual Configuration)"
        case .randomCoherentPhone: return "Auto-Random Coherent Device"
        case .preset: return "Apply Selected Preset"
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return "New containers start with real host defaults until configured manually."
        case .randomCoherentPhone:
            return "Each newly created container gets a coherent hardware profile, fresh IDFV, and matching locale/time zone."
        case .preset:
            return "Every newly created container inherits the selected preset with freshly minted unique identifiers."
        }
    }
}

/// Complete, serializable container profile preset supporting built-in 2026/2027 templates and user presets.
struct LCProfilePreset: Codable, Identifiable, Equatable, Hashable {
    struct Payload: Codable, Equatable, Hashable {
        var strictTestMode: Bool = false
        var strictAutoWipeOnExit: Bool = false
        var isolateAppGroup: Bool = false
        var blockDeviceInfoReads: Bool = false
        var spoofProfileEnabled: Bool = true
        var spoofIdentifierForVendor: Bool = true
        var rotateSpoofProfileOnLaunch: Bool = false
        var rotateOSMajorVersions: String = "26,27"
        var rotateUsesRealDeviceTemplates: Bool = true

        var spoofIdentityCategoryEnabled: Bool = true
        var spoofSystemCategoryEnabled: Bool = true
        var spoofDisplayCategoryEnabled: Bool = true
        var spoofLocaleCategoryEnabled: Bool = true
        var spoofBatteryCategoryEnabled: Bool = true
        var spoofTelephonyCategoryEnabled: Bool = true
        var spoofNetworkHeadersCategoryEnabled: Bool = true
        var spoofAccessibilityCategoryEnabled: Bool = true
        var spoofStorageCategoryEnabled: Bool = true
        var spoofNetworkEnvironmentCategoryEnabled: Bool = true
        var spoofAudioCategoryEnabled: Bool = true
        var spoofGraphicsCategoryEnabled: Bool = true
        var spoofWebViewCategoryEnabled: Bool = true
        var spoofAppPrivacyCategoryEnabled: Bool = true
        var spoofSensorsAndUserDataCategoryEnabled: Bool = false

        var deviceVariantId: String = "iphone18-pro-max"
        var deviceName: String = "iPhone"
        var deviceModel: String = "iPhone"
        var systemName: String = "iOS"
        var systemVersion: String = "27.2"
        var hardwareModel: String = "iPhone19,3"
        var boardModel: String = "V64AP"
        var hostName: String = "iPhone"
        var kernelVersion: String = "Darwin Kernel Version 26.2.0"
        var cpuType: Int = 16_777_228
        var cpuSubtype: Int = 2
        var processorCount: Int = 6
        var physicalMemory: Int64 = 12 * 1_073_741_824
        var gpuName: String = "Apple A20 Pro GPU"
        var gpuWorkingSetSize: Int64 = 8 * 1_073_741_824
        var graphicsSupportsRayTracing: Bool = true
        var graphicsSupportsAllFamilies: Bool = false

        var screenWidth: Double = 1320
        var screenHeight: Double = 2868
        var screenScale: Double = 3.0
        var screenNativeScale: Double = 3.0
        var maximumFramesPerSecond: Int = 120
        var screenBrightness: Double = 0.62
        var userInterfaceStyle: Int = 0
        var accessibilityContrast: Int = 0
        var displayGamut: Int = 2
        var horizontalSizeClass: Int = 1
        var verticalSizeClass: Int = 2
        var preferredContentSizeCategory: String = "UICTContentSizeCategoryL"
        var safeAreaTop: Double = 62
        var safeAreaLeft: Double = 0
        var safeAreaBottom: Double = 34
        var safeAreaRight: Double = 0

        var localeIdentifier: String = "en_US"
        var timeZoneIdentifier: String = "America/New_York"
        var batteryLevel: Double = 0.84
        var batteryState: Int = 2
        var lowPowerModeEnabled: Bool = false
        var thermalState: Int = 0

        var radioAccessTechnology: String = "CTRadioAccessTechnologyNRNSA"
        var subscriberSIMInsertedEnabled: Bool = true
        var subscriberSIMInserted: Bool = true

        var storageTotalCapacity: Int64 = 256 * 1_073_741_824
        var storageVolumeName: String = "Data"

        var audioOutputVolume: Double = 0.55
        var audioSampleRate: Double = 48_000
        var audioOutputLatency: Double = 0.01
        var audioInputLatency: Double = 0.01
        var audioOtherPlaying: Bool = false
        var audioOutputChannels: Int = 2
        var audioInputChannels: Int = 1

        var customUserAgent: String = ""
        var webGLVendor: String = "Apple Inc."
        var webGLRenderer: String = "Apple GPU"
        var webCanvasDataURL: String = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        var webColorDepth: Int = 24
        var featureOverrides: [String: Bool] = [:]
    }

    let id: String
    var name: String
    var subtitle: String
    var iconSystemName: String
    var isBuiltIn: Bool
    var createdAt: Date
    var payload: Payload

    /// Builds a preset capturing all settings from an existing ``LCContainer``.
    static func from(
        container: LCContainer,
        id: String = "custom.\(UUID().uuidString)",
        name: String,
        subtitle: String? = nil,
        iconSystemName: String = "iphone.gen3.radiowaves.left.and.right",
        isBuiltIn: Bool = false
    ) -> LCProfilePreset {
        let modelLabel = LCDeviceModelSpec.find(variantId: container.spoofDeviceVariantId, hwMachine: container.spoofHardwareModel)?.marketingName
            ?? (container.spoofHardwareModel.isEmpty ? "Custom Device" : container.spoofHardwareModel)
        let osLabel = container.spoofSystemVersion.isEmpty ? "27.2" : container.spoofSystemVersion
        let resolvedSubtitle = subtitle ?? "\(modelLabel) · \(container.spoofSystemName.isEmpty ? "iOS" : container.spoofSystemName) \(osLabel)"

        let p = Payload(
            strictTestMode: container.strictTestMode,
            strictAutoWipeOnExit: container.strictAutoWipeOnExit,
            isolateAppGroup: container.isolateAppGroup,
            blockDeviceInfoReads: container.blockDeviceInfoReads,
            spoofProfileEnabled: container.spoofProfileEnabled,
            spoofIdentifierForVendor: container.spoofIdentifierForVendor,
            rotateSpoofProfileOnLaunch: container.rotateSpoofProfileOnLaunch,
            rotateOSMajorVersions: container.rotateOSMajorVersions,
            rotateUsesRealDeviceTemplates: container.rotateUsesRealDeviceTemplates,
            spoofIdentityCategoryEnabled: container.spoofIdentityCategoryEnabled,
            spoofSystemCategoryEnabled: container.spoofSystemCategoryEnabled,
            spoofDisplayCategoryEnabled: container.spoofDisplayCategoryEnabled,
            spoofLocaleCategoryEnabled: container.spoofLocaleCategoryEnabled,
            spoofBatteryCategoryEnabled: container.spoofBatteryCategoryEnabled,
            spoofTelephonyCategoryEnabled: container.spoofTelephonyCategoryEnabled,
            spoofNetworkHeadersCategoryEnabled: container.spoofNetworkHeadersCategoryEnabled,
            spoofAccessibilityCategoryEnabled: container.spoofAccessibilityCategoryEnabled,
            spoofStorageCategoryEnabled: container.spoofStorageCategoryEnabled,
            spoofNetworkEnvironmentCategoryEnabled: container.spoofNetworkEnvironmentCategoryEnabled,
            spoofAudioCategoryEnabled: container.spoofAudioCategoryEnabled,
            spoofGraphicsCategoryEnabled: container.spoofGraphicsCategoryEnabled,
            spoofWebViewCategoryEnabled: container.spoofWebViewCategoryEnabled,
            spoofAppPrivacyCategoryEnabled: container.spoofAppPrivacyCategoryEnabled,
            spoofSensorsAndUserDataCategoryEnabled: container.spoofSensorsAndUserDataCategoryEnabled,
            deviceVariantId: container.spoofDeviceVariantId,
            deviceName: container.spoofDeviceName,
            deviceModel: container.spoofDeviceModel,
            systemName: container.spoofSystemName,
            systemVersion: container.spoofSystemVersion,
            hardwareModel: container.spoofHardwareModel,
            boardModel: container.spoofBoardModel,
            hostName: container.spoofHostName,
            kernelVersion: container.spoofKernelVersion,
            cpuType: container.spoofCPUType,
            cpuSubtype: container.spoofCPUSubtype,
            processorCount: container.spoofProcessorCount,
            physicalMemory: container.spoofPhysicalMemory,
            gpuName: container.spoofGPUName,
            gpuWorkingSetSize: container.spoofGPUWorkingSetSize,
            graphicsSupportsRayTracing: container.spoofGraphicsSupportsRayTracing,
            graphicsSupportsAllFamilies: container.spoofGraphicsSupportsAllFamilies,
            screenWidth: container.spoofScreenWidth,
            screenHeight: container.spoofScreenHeight,
            screenScale: container.spoofScreenScale,
            screenNativeScale: container.spoofScreenNativeScale,
            maximumFramesPerSecond: container.spoofMaximumFramesPerSecond,
            screenBrightness: container.spoofScreenBrightness,
            userInterfaceStyle: container.spoofUserInterfaceStyle,
            accessibilityContrast: container.spoofAccessibilityContrast,
            displayGamut: container.spoofDisplayGamut,
            horizontalSizeClass: container.spoofHorizontalSizeClass,
            verticalSizeClass: container.spoofVerticalSizeClass,
            preferredContentSizeCategory: container.spoofPreferredContentSizeCategory,
            safeAreaTop: container.spoofSafeAreaTop,
            safeAreaLeft: container.spoofSafeAreaLeft,
            safeAreaBottom: container.spoofSafeAreaBottom,
            safeAreaRight: container.spoofSafeAreaRight,
            localeIdentifier: container.spoofLocaleIdentifier,
            timeZoneIdentifier: container.spoofTimeZoneIdentifier,
            batteryLevel: container.spoofBatteryLevel,
            batteryState: container.spoofBatteryState,
            lowPowerModeEnabled: container.spoofLowPowerModeEnabled,
            thermalState: container.spoofThermalState,
            radioAccessTechnology: container.spoofRadioAccessTechnology,
            subscriberSIMInsertedEnabled: container.spoofSubscriberSIMInsertedEnabled,
            subscriberSIMInserted: container.spoofSubscriberSIMInserted,
            storageTotalCapacity: container.spoofStorageTotalCapacity,
            storageVolumeName: container.spoofStorageVolumeName,
            audioOutputVolume: container.spoofAudioOutputVolume,
            audioSampleRate: container.spoofAudioSampleRate,
            audioOutputLatency: container.spoofAudioOutputLatency,
            audioInputLatency: container.spoofAudioInputLatency,
            audioOtherPlaying: container.spoofAudioOtherPlaying,
            audioOutputChannels: container.spoofAudioOutputChannels,
            audioInputChannels: container.spoofAudioInputChannels,
            customUserAgent: container.spoofCustomUserAgent,
            webGLVendor: container.spoofWebGLVendor,
            webGLRenderer: container.spoofWebGLRenderer,
            webCanvasDataURL: container.spoofWebCanvasDataURL,
            webColorDepth: container.spoofWebColorDepth,
            featureOverrides: container.spoofFeatureOverrides
        )

        return LCProfilePreset(
            id: id,
            name: name,
            subtitle: resolvedSubtitle,
            iconSystemName: iconSystemName,
            isBuiltIn: isBuiltIn,
            createdAt: Date(),
            payload: p
        )
    }

    /// Applies this preset onto `container`, generating fresh unique per-container identifiers
    /// (IDFV, Volume UUID, Subscriber ID, Carrier Token, Boot Time) so separate containers never link.
    func apply(to container: LCContainer) {
        let p = payload
        container.isolateAppGroup = p.isolateAppGroup || p.strictTestMode
        container.strictTestMode = p.strictTestMode
        container.strictAutoWipeOnExit = p.strictAutoWipeOnExit
        container.blockDeviceInfoReads = p.blockDeviceInfoReads || p.strictTestMode
        container.spoofProfileEnabled = p.spoofProfileEnabled
        container.spoofIdentifierForVendor = p.spoofIdentifierForVendor
        container.spoofedIdentifier = UUID().uuidString
        container.rotateSpoofProfileOnLaunch = p.rotateSpoofProfileOnLaunch
        container.rotateOSMajorVersions = p.rotateOSMajorVersions
        container.rotateUsesRealDeviceTemplates = p.rotateUsesRealDeviceTemplates

        container.spoofIdentityCategoryEnabled = p.spoofIdentityCategoryEnabled
        container.spoofSystemCategoryEnabled = p.spoofSystemCategoryEnabled
        container.spoofDisplayCategoryEnabled = p.spoofDisplayCategoryEnabled
        container.spoofLocaleCategoryEnabled = p.spoofLocaleCategoryEnabled
        container.spoofBatteryCategoryEnabled = p.spoofBatteryCategoryEnabled
        container.spoofTelephonyCategoryEnabled = p.spoofTelephonyCategoryEnabled
        container.spoofNetworkHeadersCategoryEnabled = p.spoofNetworkHeadersCategoryEnabled
        container.spoofAccessibilityCategoryEnabled = p.spoofAccessibilityCategoryEnabled
        container.spoofStorageCategoryEnabled = p.spoofStorageCategoryEnabled
        container.spoofNetworkEnvironmentCategoryEnabled = p.spoofNetworkEnvironmentCategoryEnabled
        container.spoofAudioCategoryEnabled = p.spoofAudioCategoryEnabled
        container.spoofGraphicsCategoryEnabled = p.spoofGraphicsCategoryEnabled
        container.spoofWebViewCategoryEnabled = p.spoofWebViewCategoryEnabled
        container.spoofAppPrivacyCategoryEnabled = p.spoofAppPrivacyCategoryEnabled
        container.spoofSensorsAndUserDataCategoryEnabled = p.spoofSensorsAndUserDataCategoryEnabled

        container.spoofDeviceVariantId = p.deviceVariantId
        container.spoofDeviceName = p.deviceName
        container.spoofDeviceModel = p.deviceModel
        container.spoofSystemName = p.systemName
        container.spoofSystemVersion = p.systemVersion
        container.spoofHardwareModel = p.hardwareModel
        container.spoofBoardModel = p.boardModel
        container.spoofHostName = p.hostName.isEmpty
            ? p.deviceName.replacingOccurrences(of: " ", with: "-")
            : p.hostName
        container.spoofKernelVersion = p.kernelVersion
        container.spoofBootTime = Int64(Date().timeIntervalSince1970) - Int64.random(in: 43_200...1_209_600)
        container.spoofCPUType = p.cpuType
        container.spoofCPUSubtype = p.cpuSubtype
        container.spoofProcessorCount = p.processorCount
        container.spoofPhysicalMemory = p.physicalMemory
        container.spoofGPUName = p.gpuName
        container.spoofGPUWorkingSetSize = p.gpuWorkingSetSize
        container.spoofGraphicsSupportsRayTracing = p.graphicsSupportsRayTracing
        container.spoofGraphicsSupportsAllFamilies = p.graphicsSupportsAllFamilies

        container.spoofScreenWidth = p.screenWidth
        container.spoofScreenHeight = p.screenHeight
        container.spoofScreenScale = p.screenScale
        container.spoofScreenNativeScale = p.screenNativeScale
        container.spoofMaximumFramesPerSecond = p.maximumFramesPerSecond
        container.spoofScreenBrightness = p.screenBrightness
        container.spoofUserInterfaceStyle = p.userInterfaceStyle
        container.spoofAccessibilityContrast = p.accessibilityContrast
        container.spoofDisplayGamut = p.displayGamut
        container.spoofHorizontalSizeClass = p.horizontalSizeClass
        container.spoofVerticalSizeClass = p.verticalSizeClass
        container.spoofPreferredContentSizeCategory = p.preferredContentSizeCategory
        container.spoofSafeAreaTop = p.safeAreaTop
        container.spoofSafeAreaLeft = p.safeAreaLeft
        container.spoofSafeAreaBottom = p.safeAreaBottom
        container.spoofSafeAreaRight = p.safeAreaRight

        container.spoofLocaleIdentifier = p.localeIdentifier
        container.spoofTimeZoneIdentifier = p.timeZoneIdentifier
        container.spoofBatteryLevel = p.batteryLevel
        container.spoofBatteryState = p.batteryState
        container.spoofLowPowerModeEnabled = p.lowPowerModeEnabled
        container.spoofThermalState = p.thermalState

        container.spoofRadioAccessTechnology = p.radioAccessTechnology
        container.spoofSubscriberIdentifier = UUID().uuidString.uppercased()
        let tokenBytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        container.spoofSubscriberCarrierTokenBase64 = Data(tokenBytes).base64EncodedString()
        container.spoofSubscriberSIMInsertedEnabled = p.subscriberSIMInsertedEnabled
        container.spoofSubscriberSIMInserted = p.subscriberSIMInserted

        container.spoofStorageTotalCapacity = p.storageTotalCapacity
        let minFree = Int64(16 * 1_073_741_824)
        let maxFree = max(minFree + 1, p.storageTotalCapacity - Int64(24 * 1_073_741_824))
        container.spoofStorageAvailableCapacity = Int64.random(in: minFree...maxFree)
        container.spoofStorageVolumeName = p.storageVolumeName
        container.spoofStorageVolumeUUID = UUID().uuidString.uppercased()

        container.spoofAudioOutputVolume = p.audioOutputVolume
        container.spoofAudioSampleRate = p.audioSampleRate
        container.spoofAudioOutputLatency = p.audioOutputLatency
        container.spoofAudioInputLatency = p.audioInputLatency
        container.spoofAudioOtherPlaying = p.audioOtherPlaying
        container.spoofAudioOutputChannels = p.audioOutputChannels
        container.spoofAudioInputChannels = p.audioInputChannels

        container.spoofCustomUserAgent = p.customUserAgent
        container.spoofWebGLVendor = p.webGLVendor
        container.spoofWebGLRenderer = p.webGLRenderer
        container.spoofWebCanvasDataURL = p.webCanvasDataURL
        container.spoofWebColorDepth = p.webColorDepth
        container.spoofFeatureOverrides = p.featureOverrides
    }

    private static func payload(for spec: LCDeviceModelSpec, osVersion: String, storageGB: Int64 = 256) -> Payload {
        let osMajor = Int(osVersion.split(separator: ".").first ?? "27") ?? 27
        let effectiveMajor = max(osMajor, spec.minOSMajor)
        let resolvedOS = effectiveMajor == osMajor ? osVersion : "\(effectiveMajor).2"
        let darwinMajor = Int(LCExpectedDarwinMajorForOSMajor(Int32(effectiveMajor)))
        let darwinMinor = effectiveMajor >= 27 ? 2 : 0

        var p = Payload()
        p.deviceVariantId = spec.variantId
        p.deviceName = spec.marketingName
        p.deviceModel = spec.deviceModel
        p.systemName = spec.systemName
        p.systemVersion = resolvedOS
        p.hardwareModel = spec.hwMachine
        p.boardModel = spec.hwModel
        p.hostName = spec.marketingName
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        p.kernelVersion = "Darwin Kernel Version \(darwinMajor).\(darwinMinor).0"
        p.processorCount = spec.cpuCores
        p.physicalMemory = Int64(spec.physicalMemoryGB) * 1_073_741_824
        p.gpuName = spec.gpuName
        p.gpuWorkingSetSize = Int64(spec.gpuWorkingSetGB) * 1_073_741_824
        p.graphicsSupportsRayTracing = spec.supportsRayTracing
        p.graphicsSupportsAllFamilies = false
        p.screenWidth = spec.pixelWidth
        p.screenHeight = spec.pixelHeight
        p.screenScale = spec.scale
        p.screenNativeScale = spec.nativeScale
        p.maximumFramesPerSecond = spec.maxFPS
        p.horizontalSizeClass = spec.horizontalSizeClass
        p.verticalSizeClass = spec.verticalSizeClass
        p.safeAreaTop = spec.safeAreaTop
        p.safeAreaLeft = 0
        p.safeAreaBottom = spec.safeAreaBottom
        p.safeAreaRight = 0
        p.storageTotalCapacity = storageGB * 1_073_741_824
        p.isolateAppGroup = true
        return p
    }

    /// Built-in curated presets featuring the 2026–2027 iPhone 18 & iPhone Duo hardware lineup.
    static let builtInPresets: [LCProfilePreset] = {
        func makeDevicePreset(
            id: String,
            variantId: String,
            name: String,
            subtitle: String,
            icon: String,
            osVersion: String = "27.2",
            storageGB: Int64 = 256,
            customize: (inout Payload) -> Void = { _ in }
        ) -> LCProfilePreset {
            let spec = LCDeviceModelSpec.find(variantId: variantId) ?? LCDeviceModelSpec.all[0]
            var p = payload(for: spec, osVersion: osVersion, storageGB: storageGB)
            customize(&p)
            return LCProfilePreset(
                id: id,
                name: name,
                subtitle: subtitle,
                iconSystemName: icon,
                isBuiltIn: true,
                createdAt: Date(timeIntervalSince1970: 0),
                payload: p
            )
        }

        return [
            makeDevicePreset(
                id: "builtin.iphone18-pro-max",
                variantId: "iphone18-pro-max",
                name: "iPhone 18 Pro Max (iOS 27.2)",
                subtitle: "A20 Pro · iPhone19,3 / V64AP · 12 GB · 120 Hz",
                icon: "iphone.gen3",
                storageGB: 512
            ),
            makeDevicePreset(
                id: "builtin.iphone18-pro",
                variantId: "iphone18-pro",
                name: "iPhone 18 Pro (iOS 27.2)",
                subtitle: "A20 Pro · iPhone19,2 / V63AP · 12 GB · 120 Hz",
                icon: "iphone.gen3",
                storageGB: 256
            ),
            makeDevicePreset(
                id: "builtin.iphone-duo-unfolded",
                variantId: "iphone-duo-unfolded",
                name: "iPhone Duo — Unfolded 7.6\" (iOS 27.2)",
                subtitle: "A20 Pro Foldable · iPhone19,4 / V68AP · 1878×2670 Regular",
                icon: "iphone.landscape",
                storageGB: 512
            ),
            makeDevicePreset(
                id: "builtin.iphone-duo-cover",
                variantId: "iphone-duo-cover",
                name: "iPhone Duo — Cover 5.4\" (iOS 27.2)",
                subtitle: "A20 Pro Cover Display · iPhone19,4 / V68AP · 1398×2034 Compact",
                icon: "iphone",
                storageGB: 512
            ),
            makeDevicePreset(
                id: "builtin.iphone-air",
                variantId: "iphone-air",
                name: "iPhone Air (iOS 27.2)",
                subtitle: "A19 Pro · iPhone18,4 / D23AP · 12 GB · 120 Hz",
                icon: "iphone.gen3",
                storageGB: 256
            ),
            makeDevicePreset(
                id: "builtin.iphone17-pro-max",
                variantId: "iphone17-pro-max",
                name: "iPhone 17 Pro Max (iOS 27.2)",
                subtitle: "A19 Pro · iPhone18,2 / V54AP · 12 GB · 120 Hz",
                icon: "iphone.gen3",
                storageGB: 256
            ),
            makeDevicePreset(
                id: "builtin.iphone17e",
                variantId: "iphone17e",
                name: "iPhone 17e (iOS 27.2)",
                subtitle: "A19 · iPhone18,5 / V159AP · 8 GB · 60 Hz",
                icon: "iphone.gen2",
                storageGB: 128
            ),
            makeDevicePreset(
                id: "builtin.ipad-pro-m5",
                variantId: "ipad-pro-m5-13",
                name: "iPad Pro M5 13\" (iPadOS 27.2)",
                subtitle: "Apple M5 · iPad17,3 / J820AP · 12 GB · 2064×2752",
                icon: "ipad",
                storageGB: 512
            ),
            makeDevicePreset(
                id: "builtin.dynamic-rotation",
                variantId: "iphone18-pro",
                name: "Dynamic Launch Rotation (iOS 26–27)",
                subtitle: "Rotates verified template + IDFV + Geo on every launch",
                icon: "arrow.triangle.2.circlepath",
                customize: { p in
                    p.rotateSpoofProfileOnLaunch = true
                    p.rotateOSMajorVersions = "26,27"
                    p.rotateUsesRealDeviceTemplates = true
                }
            ),
            makeDevicePreset(
                id: "builtin.ephemeral-sandbox",
                variantId: "iphone17",
                name: "Strict Ephemeral Sandbox",
                subtitle: "Isolates App Group, blocks device reads & auto-wipes on exit",
                icon: "shield.lefthalf.filled.badge.checkmark",
                customize: { p in
                    p.strictTestMode = true
                    p.strictAutoWipeOnExit = true
                    p.isolateAppGroup = true
                    p.blockDeviceInfoReads = true
                }
            )
        ]
    }()
}

/// Manages custom user presets and the global default new-container policy in App Group defaults.
final class LCProfilePresetStore: ObservableObject {
    static let shared = LCProfilePresetStore()

    private static let customPresetsKey = "LCProfileCustomPresetsV1"
    private static let globalDefaultModeKey = "LCProfileGlobalDefaultModeV1"
    private static let globalDefaultPresetIdKey = "LCProfileGlobalDefaultPresetIDV1"

    @Published private(set) var customPresets: [LCProfilePreset] = []
    @Published var globalDefaultMode: LCGlobalDefaultProfileMode {
        didSet {
            LCUtils.appGroupUserDefault.set(globalDefaultMode.rawValue, forKey: Self.globalDefaultModeKey)
        }
    }
    @Published var globalDefaultPresetId: String {
        didSet {
            LCUtils.appGroupUserDefault.set(globalDefaultPresetId, forKey: Self.globalDefaultPresetIdKey)
        }
    }

    var builtInPresets: [LCProfilePreset] {
        LCProfilePreset.builtInPresets
    }

    var allPresets: [LCProfilePreset] {
        customPresets + builtInPresets
    }

    var selectedDefaultPreset: LCProfilePreset? {
        allPresets.first(where: { $0.id == globalDefaultPresetId }) ?? builtInPresets.first
    }

    init() {
        let defaults = LCUtils.appGroupUserDefault
        let modeRaw = defaults.string(forKey: Self.globalDefaultModeKey) ?? LCGlobalDefaultProfileMode.off.rawValue
        self.globalDefaultMode = LCGlobalDefaultProfileMode(rawValue: modeRaw) ?? .off
        self.globalDefaultPresetId = defaults.string(forKey: Self.globalDefaultPresetIdKey) ?? "builtin.iphone18-pro-max"
        self.customPresets = Self.loadCustomPresetsFromDefaults()
    }

    /// Saves or appends a new custom preset copied from `container`.
    @discardableResult
    func saveCustomPreset(name: String, from container: LCContainer) -> LCProfilePreset {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = LCProfilePreset.from(container: container, name: cleanName.isEmpty ? "Custom Preset" : cleanName)
        customPresets.insert(preset, at: 0)
        persistCustomPresets()
        return preset
    }

    /// Deletes a custom user preset by its identifier.
    func deleteCustomPreset(id: String) {
        customPresets.removeAll { $0.id == id }
        if globalDefaultPresetId == id {
            globalDefaultPresetId = builtInPresets.first?.id ?? ""
        }
        persistCustomPresets()
    }

    /// Renames an existing custom user preset.
    func renameCustomPreset(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = customPresets.firstIndex(where: { $0.id == id }) else { return }
        customPresets[idx].name = trimmed
        persistCustomPresets()
    }

    /// Encodes all user custom presets as pretty-printed JSON for backup/sharing.
    func exportCustomPresetsJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(customPresets)
    }

    /// Imports user custom presets from JSON data, assigning unique IDs to prevent collisions.
    @discardableResult
    func importCustomPresetsJSON(_ data: Data) throws -> Int {
        let decoded = try JSONDecoder().decode([LCProfilePreset].self, from: data)
        var added = 0
        for var preset in decoded {
            preset.isBuiltIn = false
            let imported = LCProfilePreset(
                id: "custom.\(UUID().uuidString)",
                name: preset.name,
                subtitle: preset.subtitle,
                iconSystemName: preset.iconSystemName,
                isBuiltIn: false,
                createdAt: Date(),
                payload: preset.payload
            )
            customPresets.insert(imported, at: 0)
            added += 1
        }
        persistCustomPresets()
        return added
    }

    private func persistCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            LCUtils.appGroupUserDefault.set(data, forKey: Self.customPresetsKey)
        }
    }

    private static func loadCustomPresetsFromDefaults() -> [LCProfilePreset] {
        guard let data = LCUtils.appGroupUserDefault.data(forKey: customPresetsKey),
              let decoded = try? JSONDecoder().decode([LCProfilePreset].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Applies the user's configured global default preset policy to a newly created ``LCContainer``.
    ///
    /// Thread-safe and reads directly from App Group defaults so background installers
    /// and app-cloning flows do not need to hop onto `MainActor`.
    static func applyConfiguredDefault(to container: LCContainer) {
        let defaults = LCUtils.appGroupUserDefault
        let modeRaw = defaults.string(forKey: globalDefaultModeKey) ?? LCGlobalDefaultProfileMode.off.rawValue
        let mode = LCGlobalDefaultProfileMode(rawValue: modeRaw) ?? .off

        switch mode {
        case .off:
            return
        case .randomCoherentPhone:
            let spec = LCDeviceModelSpec.random(isPad: false)
            let osVersion = "\(max(27, spec.minOSMajor)).2"
            let geo = LCDeviceModelSpec.coherentGeoPair()
            container.spoofProfileEnabled = true
            container.spoofIdentifierForVendor = true
            container.spoofedIdentifier = UUID().uuidString
            container.isolateAppGroup = true
            container.applyHardwareSpec(spec, osVersionOverride: osVersion)
            container.spoofLocaleIdentifier = geo.locale
            container.spoofTimeZoneIdentifier = geo.timeZone
            container.spoofRadioAccessTechnology = geo.radio
            container.spoofSubscriberIdentifier = UUID().uuidString.uppercased()
            let tokenBytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
            container.spoofSubscriberCarrierTokenBase64 = Data(tokenBytes).base64EncodedString()
            container.spoofSubscriberSIMInsertedEnabled = true
            container.spoofSubscriberSIMInserted = true
            container.spoofBatteryLevel = Double((Int.random(in: 35...92))) / 100.0
            container.spoofBatteryState = UIDevice.BatteryState.unplugged.rawValue
            container.spoofLowPowerModeEnabled = false
        case .preset:
            let presetId = defaults.string(forKey: globalDefaultPresetIdKey) ?? ""
            let catalog = loadCustomPresetsFromDefaults() + LCProfilePreset.builtInPresets
            if let preset = catalog.first(where: { $0.id == presetId }) ?? LCProfilePreset.builtInPresets.first {
                preset.apply(to: container)
            }
        }
    }
}

//
//  LCContainerProfileSections.swift
//  LiveContainerSwiftUI
//
//  Modular, independently-typed SwiftUI subviews for the container spoof profile screen.
//  Each section forms an isolated struct with its own body boundary, avoiding deep generic
//  type recursion in the Swift compiler / runtime demangler on iOS 27.
//

import SwiftUI
import UIKit

// MARK: - Reusable Row Helpers

struct LCLabeledTextRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var onCommit: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(label)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .onSubmit { onCommit?() }
        }
    }
}

struct LCLabeledIntRow: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(label)
            TextField(label, value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LCLabeledInt64Row: View {
    let label: String
    @Binding var value: Int64

    var body: some View {
        HStack {
            Text(label)
            TextField(label, value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LCLabeledDoubleRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            TextField(label, value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LCFeatureToggleRow: View {
    let title: String
    let key: String
    @ObservedObject var container: LCContainer
    var onToggle: (() -> Void)? = nil

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { container.isSpoofFeatureEnabled(key) },
            set: { value in
                var overrides = container.spoofFeatureOverrides
                overrides[key] = value
                container.spoofFeatureOverrides = overrides
                onToggle?()
            }
        ))
    }
}

struct LCCategoryToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var onToggle: (() -> Void)? = nil

    var body: some View {
        Toggle(title, isOn: $isOn)
            .onChange(of: isOn) { _, _ in onToggle?() }
    }
}

// MARK: - Spoof Profile Groups

struct LCContainerLaunchRotationSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        Toggle("Rotate Profile Every Launch", isOn: $container.rotateSpoofProfileOnLaunch)
            .onChange(of: container.rotateSpoofProfileOnLaunch) { _, _ in _ = onSave() }
        if container.rotateSpoofProfileOnLaunch {
            HStack {
                Text("OS Major Versions")
                TextField("26,27", text: $container.rotateOSMajorVersions)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit { _ = onSave() }
            }
            Toggle("Use Real Device Templates", isOn: $container.rotateUsesRealDeviceTemplates)
                .onChange(of: container.rotateUsesRealDeviceTemplates) { _, _ in _ = onSave() }
            Text("Enter comma-separated OS major versions. Real Device Templates rotate among verified 2026–2027 iPhone/iPad specs cleanly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LCContainerKillSwitchesSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Category Kill Switches") {
            LCCategoryToggleRow(title: "Device Identity", isOn: $container.spoofIdentityCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "System", isOn: $container.spoofSystemCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Display", isOn: $container.spoofDisplayCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Locale & Time Zone", isOn: $container.spoofLocaleCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Battery & Power", isOn: $container.spoofBatteryCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Telephony", isOn: $container.spoofTelephonyCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Network Headers", isOn: $container.spoofNetworkHeadersCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Accessibility", isOn: $container.spoofAccessibilityCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Storage", isOn: $container.spoofStorageCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Network Environment", isOn: $container.spoofNetworkEnvironmentCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Audio Routes", isOn: $container.spoofAudioCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Graphics & Metal", isOn: $container.spoofGraphicsCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "WebView Fingerprint", isOn: $container.spoofWebViewCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "App & Account Privacy", isOn: $container.spoofAppPrivacyCategoryEnabled, onToggle: { _ = onSave() })
            LCCategoryToggleRow(title: "Sensors & Permissions", isOn: $container.spoofSensorsAndUserDataCategoryEnabled, onToggle: { _ = onSave() })
        }
    }
}

struct LCContainerDeviceIdentitySection: View {
    @ObservedObject var container: LCContainer
    @Binding var typingIDFV: String
    @Binding var typingSpoofDeviceName: String
    @Binding var typingSpoofDeviceModel: String
    @Binding var typingSpoofHardwareModel: String
    @Binding var selectedCatalogVariantId: String
    let onSyncDraftState: () -> Void
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Device Identity") {
            Toggle(isOn: $container.spoofIdentifierForVendor) {
                Text("lc.container.spoofIdentifierForVendor".loc)
            }
            .onChange(of: container.spoofIdentifierForVendor) { _, _ in _ = onSave() }

            if container.spoofIdentifierForVendor {
                HStack {
                    Text("Vendor ID (UUID)")
                    TextField("lc.common.auto".loc, text: $typingIDFV)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { _ = onSave() }
                }
            }

            HStack {
                Text("Device Name")
                TextField("iPhone", text: $typingSpoofDeviceName)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            HStack {
                Text("Device Model")
                TextField("iPhone", text: $typingSpoofDeviceModel)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }

            Picker("Verified Hardware Model", selection: $selectedCatalogVariantId) {
                Text("Custom / None").tag("")
                ForEach(LCDeviceModelSpec.GroupKind.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(LCDeviceModelSpec.all.filter { $0.groupKind == group }) { spec in
                            Text(spec.marketingName).tag(spec.variantId)
                        }
                    }
                }
            }
            .onChange(of: selectedCatalogVariantId) { _, newVariantId in
                guard !newVariantId.isEmpty,
                      let spec = LCDeviceModelSpec.find(variantId: newVariantId) else {
                    if newVariantId.isEmpty {
                        container.spoofDeviceVariantId = ""
                    }
                    return
                }
                container.applyHardwareSpec(spec)
                onSyncDraftState()
                _ = onSave()
            }

            HStack {
                Text("Raw hw.machine")
                TextField("iPhone19,3", text: $typingSpoofHardwareModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        if let spec = LCDeviceModelSpec.find(hwMachine: typingSpoofHardwareModel),
                           spec.variantId == selectedCatalogVariantId {
                            _ = onSave()
                        } else {
                            selectedCatalogVariantId = ""
                            container.spoofDeviceVariantId = ""
                            _ = onSave()
                        }
                    }
            }
        }
        .disabled(!container.spoofIdentityCategoryEnabled)
    }
}

struct LCContainerSystemAndDisplaySection: View {
    @ObservedObject var container: LCContainer
    @Binding var typingSpoofSystemName: String
    @Binding var typingSpoofSystemVersion: String
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("System & Display") {
            HStack {
                Text("System Name")
                TextField("iOS", text: $typingSpoofSystemName)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            HStack {
                Text("System Version")
                TextField("27.2", text: $typingSpoofSystemVersion)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            LCFeatureToggleRow(title: "Report Low Data Mode Disabled", key: "system.lowDataMode", container: container, onToggle: { _ = onSave() })

            LCContainerAdvancedHardwareSection(container: container, onSave: onSave)
        }
        .disabled(!container.spoofSystemCategoryEnabled && !container.spoofDisplayCategoryEnabled)
    }
}

struct LCContainerAdvancedHardwareSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Advanced Hardware & Display") {
            LCLabeledTextRow(label: "Host Name", placeholder: "iPhone-18-Pro-Max", text: $container.spoofHostName, onCommit: { _ = onSave() })
            LCLabeledTextRow(label: "Board Config (hw.model)", placeholder: "V64AP", text: $container.spoofBoardModel, onCommit: { _ = onSave() })
            LCLabeledTextRow(label: "Kernel Version", placeholder: "Darwin Kernel Version 26.2.0", text: $container.spoofKernelVersion, onCommit: { _ = onSave() })
            LCLabeledInt64Row(label: "Boot Time (Unix)", value: $container.spoofBootTime)
            LCLabeledIntRow(label: "CPU Type", value: $container.spoofCPUType)
            LCLabeledIntRow(label: "CPU Subtype", value: $container.spoofCPUSubtype)
            Stepper("Processor Cores: \(container.spoofProcessorCount)", value: $container.spoofProcessorCount, in: 1...16)
                .onChange(of: container.spoofProcessorCount) { _, _ in _ = onSave() }
            Picker("Physical Memory", selection: $container.spoofPhysicalMemory) {
                Text("2 GB").tag(Int64(2 * 1_073_741_824))
                Text("3 GB").tag(Int64(3 * 1_073_741_824))
                Text("4 GB").tag(Int64(4 * 1_073_741_824))
                Text("6 GB").tag(Int64(6 * 1_073_741_824))
                Text("8 GB").tag(Int64(8 * 1_073_741_824))
                Text("12 GB").tag(Int64(12 * 1_073_741_824))
                Text("16 GB").tag(Int64(16 * 1_073_741_824))
            }
            .onChange(of: container.spoofPhysicalMemory) { _, _ in _ = onSave() }

            Picker("Thermal State", selection: $container.spoofThermalState) {
                Text("Nominal").tag(0)
                Text("Fair").tag(1)
                Text("Serious").tag(2)
                Text("Critical").tag(3)
            }
            .onChange(of: container.spoofThermalState) { _, _ in _ = onSave() }

            LCContainerDisplayGeometrySection(container: container, onSave: onSave)
            Button("Save System & Display") { _ = onSave() }
        }
    }
}

struct LCContainerDisplayGeometrySection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        HStack {
            Text("Native Pixels")
            TextField("Width", value: $container.spoofScreenWidth, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            Text("×")
            TextField("Height", value: $container.spoofScreenHeight, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
        LCLabeledDoubleRow(label: "Screen Scale", value: $container.spoofScreenScale)
        LCLabeledDoubleRow(label: "Native Scale", value: $container.spoofScreenNativeScale)
        Picker("Maximum FPS", selection: $container.spoofMaximumFramesPerSecond) {
            Text("60 Hz").tag(60)
            Text("120 Hz").tag(120)
        }
        .onChange(of: container.spoofMaximumFramesPerSecond) { _, _ in _ = onSave() }
        LCLabeledDoubleRow(label: "Brightness (0–1)", value: $container.spoofScreenBrightness)
        Picker("Appearance", selection: $container.spoofUserInterfaceStyle) {
            Text("Use System").tag(0)
            Text("Light Mode").tag(1)
            Text("Dark Mode").tag(2)
        }
        .onChange(of: container.spoofUserInterfaceStyle) { _, _ in _ = onSave() }
        Picker("Display Gamut", selection: $container.spoofDisplayGamut) {
            Text("Unspecified").tag(0)
            Text("sRGB").tag(1)
            Text("Display P3").tag(2)
        }
        .onChange(of: container.spoofDisplayGamut) { _, _ in _ = onSave() }
        Picker("Horizontal Size Class", selection: $container.spoofHorizontalSizeClass) {
            Text("Unspecified").tag(0)
            Text("Compact").tag(1)
            Text("Regular").tag(2)
        }
        .onChange(of: container.spoofHorizontalSizeClass) { _, _ in _ = onSave() }
        Picker("Vertical Size Class", selection: $container.spoofVerticalSizeClass) {
            Text("Unspecified").tag(0)
            Text("Compact").tag(1)
            Text("Regular").tag(2)
        }
        .onChange(of: container.spoofVerticalSizeClass) { _, _ in _ = onSave() }
        Picker("Text Size", selection: $container.spoofPreferredContentSizeCategory) {
            Text("Extra Small").tag("UICTContentSizeCategoryXS")
            Text("Small").tag("UICTContentSizeCategoryS")
            Text("Medium").tag("UICTContentSizeCategoryM")
            Text("Large").tag("UICTContentSizeCategoryL")
            Text("Extra Large").tag("UICTContentSizeCategoryXL")
            Text("XX Large").tag("UICTContentSizeCategoryXXL")
            Text("XXX Large").tag("UICTContentSizeCategoryXXXL")
            Text("Accessibility Medium").tag("UICTContentSizeCategoryAccessibilityM")
            Text("Accessibility Large").tag("UICTContentSizeCategoryAccessibilityL")
            Text("Accessibility XL").tag("UICTContentSizeCategoryAccessibilityXL")
            Text("Accessibility XXL").tag("UICTContentSizeCategoryAccessibilityXXL")
            Text("Accessibility XXXL").tag("UICTContentSizeCategoryAccessibilityXXXL")
        }
        .onChange(of: container.spoofPreferredContentSizeCategory) { _, _ in _ = onSave() }
        HStack {
            Text("Safe Area T/B")
            TextField("Top", value: $container.spoofSafeAreaTop, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            TextField("Bottom", value: $container.spoofSafeAreaBottom, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        HStack {
            Text("Safe Area L/R")
            TextField("Left", value: $container.spoofSafeAreaLeft, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            TextField("Right", value: $container.spoofSafeAreaRight, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LCContainerLocaleSection: View {
    @ObservedObject var container: LCContainer
    @Binding var typingSpoofLocaleIdentifier: String
    @Binding var typingSpoofTimeZoneIdentifier: String
    @Binding var showLocalePickerSheet: Bool
    @Binding var showTimeZonePickerSheet: Bool
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Locale & Time Zone") {
            HStack {
                Text("Locale ID")
                TextField("en_US", text: $typingSpoofLocaleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            Button {
                showLocalePickerSheet = true
            } label: {
                HStack {
                    Text("Browse Locales")
                    Spacer()
                    Text(LCContainerProfileCatalog.localeDisplayName(typingSpoofLocaleIdentifier))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Text("Time Zone")
                TextField("America/New_York", text: $typingSpoofTimeZoneIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            Button {
                showTimeZonePickerSheet = true
            } label: {
                HStack {
                    Text("Browse Time Zones")
                    Spacer()
                    Text(typingSpoofTimeZoneIdentifier.isEmpty ? "None (Use Host)" : typingSpoofTimeZoneIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            LCFeatureToggleRow(title: "Hide Active Keyboard/Input Modes", key: "locale.inputModes", container: container, onToggle: { _ = onSave() })
            Button("Save Locale & Time Zone") { _ = onSave() }
        }
        .disabled(!container.spoofLocaleCategoryEnabled)
    }
}

struct LCContainerBatterySection: View {
    @ObservedObject var container: LCContainer
    @Binding var typingSpoofBatteryLevel: String
    @Binding var spoofBatteryStateSelection: Int
    @Binding var spoofLowPowerModeEnabled: Bool
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Battery & Power") {
            HStack {
                Text("Battery Level (0–1)")
                TextField("0.84", text: $typingSpoofBatteryLevel)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            Picker("Battery State", selection: $spoofBatteryStateSelection) {
                Text("Unknown").tag(UIDevice.BatteryState.unknown.rawValue)
                Text("Unplugged").tag(UIDevice.BatteryState.unplugged.rawValue)
                Text("Charging").tag(UIDevice.BatteryState.charging.rawValue)
                Text("Full").tag(UIDevice.BatteryState.full.rawValue)
            }
            .onChange(of: spoofBatteryStateSelection) { _, _ in _ = onSave() }
            Toggle("Low Power Mode", isOn: $spoofLowPowerModeEnabled)
                .onChange(of: spoofLowPowerModeEnabled) { _, _ in _ = onSave() }
            Button("Save Battery") { _ = onSave() }
        }
        .disabled(!container.spoofBatteryCategoryEnabled)
    }
}

struct LCContainerTelephonySection: View {
    @ObservedObject var container: LCContainer
    @Binding var typingSpoofSubscriberIdentifier: String
    @Binding var typingSpoofSubscriberCarrierTokenBase64: String
    @Binding var spoofSubscriberSIMInsertedEnabled: Bool
    @Binding var spoofSubscriberSIMInserted: Bool
    @Binding var typingSpoofRadioAccessTechnology: String
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Telephony") {
            HStack {
                Text("Subscriber ID")
                TextField("UUID", text: $typingSpoofSubscriberIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            HStack {
                Text("Carrier Token (Base64)")
                TextField("Optional", text: $typingSpoofSubscriberCarrierTokenBase64)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = onSave() }
            }
            Toggle("Spoof SIM Inserted", isOn: $spoofSubscriberSIMInsertedEnabled)
                .onChange(of: spoofSubscriberSIMInsertedEnabled) { _, _ in _ = onSave() }
            if spoofSubscriberSIMInsertedEnabled {
                Toggle("SIM Inserted", isOn: $spoofSubscriberSIMInserted)
                    .onChange(of: spoofSubscriberSIMInserted) { _, _ in _ = onSave() }
            }
            Picker("Radio Tech", selection: $typingSpoofRadioAccessTechnology) {
                Text("None (Use Host)").tag("")
                ForEach(LCContainerProfileCatalog.availableRadioAccessTechnologies, id: \.self) { tech in
                    Text(tech).tag(tech)
                }
            }
            .onChange(of: typingSpoofRadioAccessTechnology) { _, _ in _ = onSave() }
            Button("Save Telephony") { _ = onSave() }
        }
        .disabled(!container.spoofTelephonyCategoryEnabled)
    }
}

struct LCContainerNetworkHeadersSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Network Headers") {
            LCFeatureToggleRow(title: "Rewrite User-Agent Headers", key: "networkHeaders.userAgent", container: container, onToggle: { _ = onSave() })
            LCLabeledTextRow(label: "Custom User-Agent", placeholder: "Empty = synthesized", text: $container.spoofCustomUserAgent, onCommit: { _ = onSave() })
            Button("Save Network Headers") { _ = onSave() }
        }
        .disabled(!container.spoofNetworkHeadersCategoryEnabled)
    }
}

struct LCContainerAccessibilitySection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Accessibility") {
            Picker("Contrast", selection: $container.spoofAccessibilityContrast) {
                Text("Normal").tag(0)
                Text("High").tag(1)
            }
            .onChange(of: container.spoofAccessibilityContrast) { _, _ in _ = onSave() }
            LCContainerAccessibilityFeaturesOffSection(container: container, onSave: onSave)
        }
        .disabled(!container.spoofAccessibilityCategoryEnabled)
    }
}

struct LCContainerAccessibilityFeaturesOffSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Accessibility Features Reported Off") {
            LCFeatureToggleRow(title: "VoiceOver", key: "accessibility.voiceOver", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Switch Control", key: "accessibility.switchControl", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Guided Access", key: "accessibility.guidedAccess", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Grayscale", key: "accessibility.grayscale", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Invert Colors", key: "accessibility.invertColors", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Reduce Motion", key: "accessibility.reduceMotion", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Reduce Transparency", key: "accessibility.reduceTransparency", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "AssistiveTouch", key: "accessibility.assistiveTouch", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Shake to Undo", key: "accessibility.shakeToUndo", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Bold Text", key: "accessibility.boldText", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Button Shapes", key: "accessibility.buttonShapes", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Darker System Colors", key: "accessibility.darkerColors", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Mono Audio", key: "accessibility.monoAudio", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Speak Screen", key: "accessibility.speakScreen", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Speak Selection", key: "accessibility.speakSelection", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Closed Captions", key: "accessibility.closedCaptions", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Video Autoplay", key: "accessibility.videoAutoplay", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Differentiate Without Color", key: "accessibility.differentiateWithoutColor", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "On/Off Switch Labels", key: "accessibility.onOffLabels", container: container, onToggle: { _ = onSave() })
        }
    }
}

struct LCContainerStorageSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Storage") {
            LCFeatureToggleRow(title: "Override Capacity", key: "storage.capacity", container: container, onToggle: { _ = onSave() })
            LCLabeledInt64Row(label: "Total Capacity (Bytes)", value: $container.spoofStorageTotalCapacity)
            LCLabeledInt64Row(label: "Available Capacity (Bytes)", value: $container.spoofStorageAvailableCapacity)
            LCFeatureToggleRow(title: "Override Volume Identity", key: "storage.identity", container: container, onToggle: { _ = onSave() })
            LCLabeledTextRow(label: "Volume Name", placeholder: "Data", text: $container.spoofStorageVolumeName, onCommit: { _ = onSave() })
            LCLabeledTextRow(label: "Volume UUID", placeholder: "UUID", text: $container.spoofStorageVolumeUUID, onCommit: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Creation Dates", key: "storage.creationDates", container: container, onToggle: { _ = onSave() })
            LCLabeledInt64Row(label: "File Creation (Unix)", value: $container.spoofStorageFileCreationTime)
            LCLabeledInt64Row(label: "Volume Creation (Unix)", value: $container.spoofStorageVolumeCreationTime)
            Button("Save Storage") { _ = onSave() }
        }
        .disabled(!container.spoofStorageCategoryEnabled)
    }
}

struct LCContainerNetworkEnvSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Network Environment") {
            LCFeatureToggleRow(title: "Override Host Name", key: "network.hostName", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Hide Network Interfaces", key: "network.interfaces", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Stop Path Monitoring (Off by Default)", key: "network.pathMonitor", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Block Bonjour / Service Discovery", key: "network.serviceDiscovery", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Hide Proxy and VPN Settings", key: "network.proxy", container: container, onToggle: { _ = onSave() })
        }
        .disabled(!container.spoofNetworkEnvironmentCategoryEnabled)
    }
}

struct LCContainerAudioRoutesSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Audio Routes") {
            LCFeatureToggleRow(title: "Hide Available Inputs", key: "audio.availableInputs", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Hide Current Route Inputs/Outputs", key: "audio.routes", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Output Volume", key: "audio.outputVolume", container: container, onToggle: { _ = onSave() })
            LCLabeledDoubleRow(label: "Output Volume (0–1)", value: $container.spoofAudioOutputVolume)
            LCFeatureToggleRow(title: "Override Sample Rate", key: "audio.sampleRate", container: container, onToggle: { _ = onSave() })
            LCLabeledDoubleRow(label: "Sample Rate (Hz)", value: $container.spoofAudioSampleRate)
            LCFeatureToggleRow(title: "Override Output Latency", key: "audio.outputLatency", container: container, onToggle: { _ = onSave() })
            LCLabeledDoubleRow(label: "Output Latency (s)", value: $container.spoofAudioOutputLatency)
            LCFeatureToggleRow(title: "Override Input Latency", key: "audio.inputLatency", container: container, onToggle: { _ = onSave() })
            LCLabeledDoubleRow(label: "Input Latency (s)", value: $container.spoofAudioInputLatency)
            LCFeatureToggleRow(title: "Override Other Audio Playing", key: "audio.otherPlaying", container: container, onToggle: { _ = onSave() })
            Toggle("Other Audio Playing", isOn: $container.spoofAudioOtherPlaying)
                .onChange(of: container.spoofAudioOtherPlaying) { _, _ in _ = onSave() }
            LCFeatureToggleRow(title: "Override Channel Counts", key: "audio.channels", container: container, onToggle: { _ = onSave() })
            Stepper("Output Channels: \(container.spoofAudioOutputChannels)", value: $container.spoofAudioOutputChannels, in: 0...32)
                .onChange(of: container.spoofAudioOutputChannels) { _, _ in _ = onSave() }
            Stepper("Input Channels: \(container.spoofAudioInputChannels)", value: $container.spoofAudioInputChannels, in: 0...32)
                .onChange(of: container.spoofAudioInputChannels) { _, _ in _ = onSave() }
            Button("Save Audio") { _ = onSave() }
        }
        .disabled(!container.spoofAudioCategoryEnabled)
    }
}

struct LCContainerGraphicsMetalSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Graphics & Metal") {
            LCFeatureToggleRow(title: "Override GPU Name", key: "graphics.name", container: container, onToggle: { _ = onSave() })
            LCLabeledTextRow(label: "GPU Name", placeholder: "Apple A20 Pro GPU", text: $container.spoofGPUName, onCommit: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Recommended Working Set", key: "graphics.workingSet", container: container, onToggle: { _ = onSave() })
            LCLabeledInt64Row(label: "Working Set (Bytes)", value: $container.spoofGPUWorkingSetSize)
            LCFeatureToggleRow(title: "Report Ray Tracing Support", key: "graphics.rayTracing", container: container, onToggle: { _ = onSave() })
            Toggle("Ray Tracing Result", isOn: $container.spoofGraphicsSupportsRayTracing)
                .onChange(of: container.spoofGraphicsSupportsRayTracing) { _, _ in _ = onSave() }
            LCFeatureToggleRow(title: "Report All Metal Families", key: "graphics.allFamilies", container: container, onToggle: { _ = onSave() })
            Toggle("Metal Families Result", isOn: $container.spoofGraphicsSupportsAllFamilies)
                .onChange(of: container.spoofGraphicsSupportsAllFamilies) { _, _ in _ = onSave() }
            Button("Save Graphics") { _ = onSave() }
        }
        .disabled(!container.spoofGraphicsCategoryEnabled)
    }
}

struct LCContainerWebViewSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("WebView Fingerprint") {
            LCFeatureToggleRow(title: "Override Navigator and User-Agent", key: "web.navigator", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Screen and Device Pixel Ratio", key: "web.screen", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Time Zone", key: "web.timeZone", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Override WebGL (WebGL1 + WebGL2)", key: "web.webGL", container: container, onToggle: { _ = onSave() })
            LCLabeledTextRow(label: "WebGL Vendor", placeholder: "Apple Inc.", text: $container.spoofWebGLVendor, onCommit: { _ = onSave() })
            LCLabeledTextRow(label: "WebGL Renderer", placeholder: "Apple GPU", text: $container.spoofWebGLRenderer, onCommit: { _ = onSave() })
            LCFeatureToggleRow(title: "Override Canvas Output", key: "web.canvas", container: container, onToggle: { _ = onSave() })
            HStack {
                LCLabeledTextRow(label: "Canvas & Audio Farbling Seed", placeholder: "0xA53F91C2", text: $container.spoofWebCanvasSeed, onCommit: { _ = onSave() })
                Button {
                    container.spoofWebCanvasSeed = String(format: "0x%08X", UInt32.random(in: 1...UInt32.max))
                    _ = onSave()
                } label: {
                    Image(systemName: "die.face.5")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Randomize Canvas Farbling Seed")
            }
            Stepper("Color Depth: \(container.spoofWebColorDepth)", value: $container.spoofWebColorDepth, in: 1...64)
                .onChange(of: container.spoofWebColorDepth) { _, _ in _ = onSave() }
            Button("Save WebView") { _ = onSave() }
        }
        .disabled(!container.spoofWebViewCategoryEnabled)
    }
}

struct LCContainerAppPrivacySection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("App & Account Privacy") {
            LCFeatureToggleRow(title: "Hide URL-Scheme App Detection", key: "app.canOpenURL", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Use Neutral Font Families", key: "app.fonts", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Hide Installed Speech Voices", key: "app.voices", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Hide iCloud Account Identity", key: "app.iCloud", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Use Isolated General Pasteboard", key: "app.pasteboard", container: container, onToggle: { _ = onSave() })
        }
        .disabled(!container.spoofAppPrivacyCategoryEnabled)
    }
}

struct LCContainerSensorsSection: View {
    @ObservedObject var container: LCContainer
    let onSave: () -> Bool

    var body: some View {
        DisclosureGroup("Sensors & Permissions (Deny/Hide)") {
            LCFeatureToggleRow(title: "Accelerometer Unavailable", key: "sensors.accelerometer", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Gyroscope Unavailable", key: "sensors.gyroscope", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Magnetometer Unavailable", key: "sensors.magnetometer", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Device Motion Unavailable", key: "sensors.deviceMotion", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Pedometer Unavailable", key: "sensors.pedometer", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Altimeter Unavailable", key: "sensors.altimeter", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Location Status", key: "permissions.location", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Camera & Microphone Status", key: "permissions.capture", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Photos Status", key: "permissions.photos", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Contacts Status", key: "permissions.contacts", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Calendars & Reminders Status", key: "permissions.events", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Media Library Status", key: "permissions.media", container: container, onToggle: { _ = onSave() })
            LCFeatureToggleRow(title: "Deny Bluetooth Status", key: "permissions.bluetooth", container: container, onToggle: { _ = onSave() })
        }
        .disabled(!container.spoofSensorsAndUserDataCategoryEnabled)
    }
}

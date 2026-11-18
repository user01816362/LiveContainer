//
//  LCContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import AVFoundation
import Metal
import SwiftUI

/// Delegate bridging container persistence and app-level metadata into ``LCContainerView``.
@MainActor
protocol LCContainerViewDelegate {
    func unbindContainer(container: LCContainer)
    func setDefaultContainer(container: LCContainer)
    func saveContainer(container: LCContainer)

    func getSettingsBundle() -> Bundle?
    func getContainerURL(container: LCContainer) -> URL
    func getBundleId() -> String
    func isTweakLoaderInjectionDisabled() -> Bool
}

/// Container details, isolation controls, 2026–2027 hardware profile presets,
/// three-vector Leak Inspector, and granular spoof editor for a single ``LCContainer``.
struct LCContainerView: View {
    @ObservedObject var container: LCContainer
    let delegate: LCContainerViewDelegate
    @Binding var uiDefaultDataFolder: String?
    @State var settingsBundle: Bundle? = nil

    @StateObject private var removeContainerAlert = YesNoHelper()
    @StateObject private var deleteDataAlert = YesNoHelper()
    @StateObject private var removeKeychainAlert = YesNoHelper()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var typingContainerName: String
    @State private var typingIDFV: String
    @State private var typingSpoofDeviceName: String
    @State private var typingSpoofDeviceModel: String
    @State private var typingSpoofSystemName: String
    @State private var typingSpoofSystemVersion: String
    @State private var typingSpoofLocaleIdentifier: String
    @State private var typingSpoofTimeZoneIdentifier: String
    @State private var typingSpoofBatteryLevel: String
    @State private var spoofBatteryStateSelection: Int
    @State private var spoofLowPowerModeEnabled: Bool
    @State private var typingSpoofSubscriberIdentifier: String
    @State private var typingSpoofSubscriberCarrierTokenBase64: String
    @State private var spoofSubscriberSIMInsertedEnabled: Bool
    @State private var spoofSubscriberSIMInserted: Bool
    @State private var typingSpoofRadioAccessTechnology: String
    @State private var typingSpoofHardwareModel: String
    @State private var selectedCatalogVariantId: String

    @State private var showLocalePickerSheet = false
    @State private var showTimeZonePickerSheet = false
    @State private var inUse = false
    @State private var runningLC: String? = nil

    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""

    private var tweakLoaderDependentControlsEnabled: Bool {
        !delegate.isTweakLoaderInjectionDisabled()
    }

    init(container: LCContainer, uiDefaultDataFolder: Binding<String?>, delegate: LCContainerViewDelegate) {
        self._container = ObservedObject(initialValue: container)
        self.delegate = delegate
        self._typingContainerName = State(initialValue: container.name)
        self._typingIDFV = State(initialValue: container.spoofedIdentifier ?? "")
        self._typingSpoofDeviceName = State(initialValue: container.spoofDeviceName)
        self._typingSpoofDeviceModel = State(initialValue: container.spoofDeviceModel)
        self._typingSpoofSystemName = State(initialValue: container.spoofSystemName)
        self._typingSpoofSystemVersion = State(initialValue: container.spoofSystemVersion)
        self._typingSpoofLocaleIdentifier = State(initialValue: container.spoofLocaleIdentifier)
        self._typingSpoofTimeZoneIdentifier = State(initialValue: container.spoofTimeZoneIdentifier)
        self._typingSpoofBatteryLevel = State(initialValue: String(format: "%.2f", container.spoofBatteryLevel))
        self._spoofBatteryStateSelection = State(initialValue: container.spoofBatteryState)
        self._spoofLowPowerModeEnabled = State(initialValue: container.spoofLowPowerModeEnabled)
        self._typingSpoofSubscriberIdentifier = State(initialValue: container.spoofSubscriberIdentifier)
        self._typingSpoofSubscriberCarrierTokenBase64 = State(initialValue: container.spoofSubscriberCarrierTokenBase64)
        self._spoofSubscriberSIMInsertedEnabled = State(initialValue: container.spoofSubscriberSIMInsertedEnabled)
        self._spoofSubscriberSIMInserted = State(initialValue: container.spoofSubscriberSIMInserted)
        self._typingSpoofRadioAccessTechnology = State(initialValue: container.spoofRadioAccessTechnology)
        self._typingSpoofHardwareModel = State(initialValue: container.spoofHardwareModel)
        let matchedVariant = LCDeviceModelSpec.find(
            variantId: container.spoofDeviceVariantId,
            hwMachine: container.spoofHardwareModel
        )?.variantId ?? ""
        self._selectedCatalogVariantId = State(initialValue: matchedVariant)
        self._uiDefaultDataFolder = Binding(projectedValue: uiDefaultDataFolder)
    }

    var body: some View {
        Form {
            if !(container.storageBookMark != nil && container.resolvedContainerURL == nil) {
                containerMetadataSection
                strictModeSection
                spoofProfileSection
                managementActionsSection
            } else {
                unavailableBookmarkSection
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    commitContainerNameIfChanged()
                    if saveSpoofProfile() {
                        successInfo = "Container profile saved."
                        successShow = true
                    }
                }
            }
        }
        .sheet(isPresented: $showLocalePickerSheet) {
            LCLocalePickerSheet(selectedLocale: $typingSpoofLocaleIdentifier) {
                _ = saveSpoofProfile()
            }
        }
        .sheet(isPresented: $showTimeZonePickerSheet) {
            LCTimeZonePickerSheet(selectedTimeZone: $typingSpoofTimeZoneIdentifier) {
                _ = saveSpoofProfile()
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow) {
        } message: {
            Text(successInfo)
        }
        .alert("lc.container.removeContainer".loc, isPresented: $removeContainerAlert.show) {
            Button(role: .destructive) { removeContainerAlert.close(result: true) } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) { removeContainerAlert.close(result: false) }
        } message: {
            Text("lc.container.removeContainerDesc".loc)
        }
        .alert("lc.container.deleteData".loc, isPresented: $deleteDataAlert.show) {
            Button(role: .destructive) { deleteDataAlert.close(result: true) } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) { deleteDataAlert.close(result: false) }
        } message: {
            Text("lc.container.deleteDataDesc".loc)
        }
        .alert("lc.settings.cleanKeychain".loc, isPresented: $removeKeychainAlert.show) {
            Button(role: .destructive) { removeKeychainAlert.close(result: true) } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) { removeKeychainAlert.close(result: false) }
        } message: {
            Text("lc.container.removeKeychainDesc".loc)
        }
        .onAppear {
            handleAppear()
        }
        .onDisappear {
            saveSpoofProfileSilently()
        }
    }

    // MARK: - Top-Level Sections

    @ViewBuilder
    private var containerMetadataSection: some View {
        Section {
            HStack {
                Text("lc.container.containerName".loc)
                Spacer()
                TextField("lc.container.containerName".loc, text: $typingContainerName)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        commitContainerNameIfChanged()
                        saveContainer()
                    }
            }
            HStack {
                Text("lc.container.containerFolderName".loc)
                Spacer()
                Text(container.folderName)
                    .foregroundStyle(.gray)
            }
            Toggle(isOn: $container.isolateAppGroup) {
                Text("lc.container.isolateAppGroup".loc)
            }
            .disabled(container.strictTestMode)
            .onChange(of: container.isolateAppGroup) { _, _ in
                saveContainer()
            }

            if let settingsBundle {
                NavigationLink {
                    AppPreferenceView(
                        bundleId: delegate.getBundleId(),
                        settingsBundle: settingsBundle,
                        containerURL: delegate.getContainerURL(container: container)
                    )
                } label: {
                    Text("lc.container.preferences".loc)
                }
            }

            if container.folderName == uiDefaultDataFolder {
                Text("lc.container.alreadyDefaultContainer".loc)
                    .foregroundStyle(.gray)
            } else {
                Button {
                    setAsDefault()
                } label: {
                    Text("lc.container.setDefaultContainer".loc)
                }
            }
        } footer: {
            Text("lc.container.defaultContainerDesc".loc)
        }
    }

    @ViewBuilder
    private var strictModeSection: some View {
        Section {
            Toggle("Strict Test Mode", isOn: $container.strictTestMode)
                .disabled(!tweakLoaderDependentControlsEnabled)
                .onChange(of: container.strictTestMode) { _, _ in
                    saveStrictModeSettings()
                }

            if container.strictTestMode {
                Toggle("Auto-Wipe Container on App Exit", isOn: $container.strictAutoWipeOnExit)
                    .disabled(!tweakLoaderDependentControlsEnabled)
                    .onChange(of: container.strictAutoWipeOnExit) { _, _ in
                        saveContainer()
                    }
            }
        } header: {
            Text("Strict Test Mode")
        } footer: {
            if tweakLoaderDependentControlsEnabled {
                Text("Aggressive isolation for app testing: forces app-group isolation, blocks device identity/profile reads, blocks common external URL/network paths, and can auto-wipe this container on exit.")
            } else {
                Text("Strict Test Mode requires TweakLoader injection. Disable Don't Inject TweakLoader in App Settings to use this.")
            }
        }
    }

    @ViewBuilder
    private var spoofProfileSection: some View {
        Section {
            Toggle("Block Device Info Reads", isOn: $container.blockDeviceInfoReads)
                .disabled(container.strictTestMode || !tweakLoaderDependentControlsEnabled)
                .onChange(of: container.blockDeviceInfoReads) { _, _ in
                    saveContainer()
                }

            Toggle("Advanced Spoof Profile", isOn: $container.spoofProfileEnabled)
                .disabled(!tweakLoaderDependentControlsEnabled)
                .onChange(of: container.spoofProfileEnabled) { _, _ in
                    if container.spoofProfileEnabled && !hasConfiguredSpoofTemplate() {
                        applyRandomDeviceProfileValues()
                    }
                    _ = saveSpoofProfile()
                }

            LCProfileLeakInspectorCard(
                report: LCProfileLeakAnalyzer.analyze(
                    container: container,
                    dontInjectTweakLoader: !tweakLoaderDependentControlsEnabled
                ),
                onAutoFix: {
                    LCProfileLeakAnalyzer.autoFixCoherence(for: container)
                    syncDraftStateFromContainer()
                    _ = saveSpoofProfile()
                    successInfo = "Aligned hardware, OS, kernel, Metal GPU, and anti-leak flags."
                    successShow = true
                }
            )
            .disabled(!tweakLoaderDependentControlsEnabled)

            if container.spoofProfileEnabled {
                spoofProfileControlsGroup
            }
        } header: {
            Text("Spoof Profile")
        } footer: {
            if tweakLoaderDependentControlsEnabled {
                Text("Each category has an independent kill switch. Rotate Profile Every Launch generates a coherent ephemeral hardware/geo profile in memory without overwriting your template.")
            } else {
                Text("Spoof controls require TweakLoader injection. Disable Don't Inject TweakLoader in App Settings to use this.")
            }
        }
    }

    @ViewBuilder
    private var spoofProfileControlsGroup: some View {
        Group {
            LCProfilePresetControlBar(
                onApplyPreset: { preset in
                    preset.apply(to: container)
                    syncDraftStateFromContainer()
                    saveContainer()
                    successInfo = "Applied '\(preset.name)' with fresh container identifiers."
                    successShow = true
                },
                onSaveAsPreset: { presetName in
                    _ = saveSpoofProfile()
                    let saved = LCProfilePresetStore.shared.saveCustomPreset(name: presetName, from: container)
                    successInfo = "Saved custom preset '\(saved.name)'."
                    successShow = true
                },
                onApplyCurrentDevice: {
                    applyCurrentDeviceProfileValues()
                    _ = saveSpoofProfile()
                },
                onRandomizeCoherent: {
                    applyRandomDeviceProfileValues()
                    _ = saveSpoofProfile()
                }
            )

            launchRotationGroup
            categoryKillSwitchesGroup
            deviceIdentityGroup
            systemAndDisplayGroup
            localeAndTimeZoneGroup
            batteryAndPowerGroup
            telephonyGroup
            networkHeadersGroup
            accessibilityGroup
            storageGroup
            networkEnvironmentGroup
            audioRoutesGroup
            graphicsAndMetalGroup
            webViewFingerprintGroup
            appAndAccountPrivacyGroup
            sensorsAndPermissionsGroup
        }
        .disabled(container.blockDeviceInfoReads)
    }

    // MARK: - Spoof Subgroups

    @ViewBuilder
    private var launchRotationGroup: some View {
        Toggle("Rotate Profile Every Launch", isOn: $container.rotateSpoofProfileOnLaunch)
            .onChange(of: container.rotateSpoofProfileOnLaunch) { _, _ in _ = saveSpoofProfile() }
        if container.rotateSpoofProfileOnLaunch {
            HStack {
                Text("OS Major Versions")
                TextField("26,27", text: $container.rotateOSMajorVersions)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            Toggle("Use Real Device Templates", isOn: $container.rotateUsesRealDeviceTemplates)
                .onChange(of: container.rotateUsesRealDeviceTemplates) { _, _ in _ = saveSpoofProfile() }
            Text("Enter comma-separated OS major versions. Real Device Templates rotate among verified 2026–2027 iPhone/iPad specs cleanly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var categoryKillSwitchesGroup: some View {
        DisclosureGroup("Category Kill Switches") {
            categoryToggle("Device Identity", isOn: $container.spoofIdentityCategoryEnabled)
            categoryToggle("System", isOn: $container.spoofSystemCategoryEnabled)
            categoryToggle("Display", isOn: $container.spoofDisplayCategoryEnabled)
            categoryToggle("Locale & Time Zone", isOn: $container.spoofLocaleCategoryEnabled)
            categoryToggle("Battery & Power", isOn: $container.spoofBatteryCategoryEnabled)
            categoryToggle("Telephony", isOn: $container.spoofTelephonyCategoryEnabled)
            categoryToggle("Network Headers", isOn: $container.spoofNetworkHeadersCategoryEnabled)
            categoryToggle("Accessibility", isOn: $container.spoofAccessibilityCategoryEnabled)
            categoryToggle("Storage", isOn: $container.spoofStorageCategoryEnabled)
            categoryToggle("Network Environment", isOn: $container.spoofNetworkEnvironmentCategoryEnabled)
            categoryToggle("Audio Routes", isOn: $container.spoofAudioCategoryEnabled)
            categoryToggle("Graphics & Metal", isOn: $container.spoofGraphicsCategoryEnabled)
            categoryToggle("WebView Fingerprint", isOn: $container.spoofWebViewCategoryEnabled)
            categoryToggle("App & Account Privacy", isOn: $container.spoofAppPrivacyCategoryEnabled)
            categoryToggle("Sensors & Permissions", isOn: $container.spoofSensorsAndUserDataCategoryEnabled)
        }
    }

    @ViewBuilder
    private var deviceIdentityGroup: some View {
        DisclosureGroup("Device Identity") {
            Toggle(isOn: $container.spoofIdentifierForVendor) {
                Text("lc.container.spoofIdentifierForVendor".loc)
            }
            .onChange(of: container.spoofIdentifierForVendor) { _, _ in _ = saveSpoofProfile() }

            if container.spoofIdentifierForVendor {
                HStack {
                    Text("Vendor ID (UUID)")
                    TextField("lc.common.auto".loc, text: $typingIDFV)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { _ = saveSpoofProfile() }
                }
            }

            HStack {
                Text("Device Name")
                TextField("iPhone", text: $typingSpoofDeviceName)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            HStack {
                Text("Device Model")
                TextField("iPhone", text: $typingSpoofDeviceModel)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
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
                syncDraftStateFromContainer()
                _ = saveSpoofProfile()
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
                            _ = saveSpoofProfile()
                        } else {
                            selectedCatalogVariantId = ""
                            container.spoofDeviceVariantId = ""
                            _ = saveSpoofProfile()
                        }
                    }
            }
        }
        .disabled(!container.spoofIdentityCategoryEnabled)
    }

    @ViewBuilder
    private var systemAndDisplayGroup: some View {
        DisclosureGroup("System & Display") {
            HStack {
                Text("System Name")
                TextField("iOS", text: $typingSpoofSystemName)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            HStack {
                Text("System Version")
                TextField("27.2", text: $typingSpoofSystemVersion)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            featureToggle("Report Low Data Mode Disabled", "system.lowDataMode")

            DisclosureGroup("Advanced Hardware & Display") {
                labeledTextRow("Host Name", placeholder: "iPhone-18-Pro-Max", text: $container.spoofHostName)
                labeledTextRow("Board Config (hw.model)", placeholder: "V64AP", text: $container.spoofBoardModel)
                labeledTextRow("Kernel Version", placeholder: "Darwin Kernel Version 26.2.0", text: $container.spoofKernelVersion)
                labeledInt64Row("Boot Time (Unix)", value: $container.spoofBootTime)
                labeledIntRow("CPU Type", value: $container.spoofCPUType)
                labeledIntRow("CPU Subtype", value: $container.spoofCPUSubtype)
                Stepper("Processor Cores: \(container.spoofProcessorCount)", value: $container.spoofProcessorCount, in: 1...16)
                    .onChange(of: container.spoofProcessorCount) { _, _ in _ = saveSpoofProfile() }
                Picker("Physical Memory", selection: $container.spoofPhysicalMemory) {
                    Text("2 GB").tag(Int64(2 * 1_073_741_824))
                    Text("3 GB").tag(Int64(3 * 1_073_741_824))
                    Text("4 GB").tag(Int64(4 * 1_073_741_824))
                    Text("6 GB").tag(Int64(6 * 1_073_741_824))
                    Text("8 GB").tag(Int64(8 * 1_073_741_824))
                    Text("12 GB").tag(Int64(12 * 1_073_741_824))
                    Text("16 GB").tag(Int64(16 * 1_073_741_824))
                }
                .onChange(of: container.spoofPhysicalMemory) { _, _ in _ = saveSpoofProfile() }

                Picker("Thermal State", selection: $container.spoofThermalState) {
                    Text("Nominal").tag(0)
                    Text("Fair").tag(1)
                    Text("Serious").tag(2)
                    Text("Critical").tag(3)
                }
                .onChange(of: container.spoofThermalState) { _, _ in _ = saveSpoofProfile() }

                displayGeometrySubgroup
                Button("Save System & Display") { _ = saveSpoofProfile() }
            }
        }
        .disabled(!container.spoofSystemCategoryEnabled && !container.spoofDisplayCategoryEnabled)
    }

    @ViewBuilder
    private var displayGeometrySubgroup: some View {
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
        labeledDoubleRow("Screen Scale", value: $container.spoofScreenScale)
        labeledDoubleRow("Native Scale", value: $container.spoofScreenNativeScale)
        Picker("Maximum FPS", selection: $container.spoofMaximumFramesPerSecond) {
            Text("60 Hz").tag(60)
            Text("120 Hz").tag(120)
        }
        .onChange(of: container.spoofMaximumFramesPerSecond) { _, _ in _ = saveSpoofProfile() }
        labeledDoubleRow("Brightness (0–1)", value: $container.spoofScreenBrightness)
        Picker("Appearance", selection: $container.spoofUserInterfaceStyle) {
            Text("Use System").tag(0)
            Text("Light Mode").tag(1)
            Text("Dark Mode").tag(2)
        }
        .onChange(of: container.spoofUserInterfaceStyle) { _, _ in _ = saveSpoofProfile() }
        Picker("Display Gamut", selection: $container.spoofDisplayGamut) {
            Text("Unspecified").tag(0)
            Text("sRGB").tag(1)
            Text("Display P3").tag(2)
        }
        .onChange(of: container.spoofDisplayGamut) { _, _ in _ = saveSpoofProfile() }
        Picker("Horizontal Size Class", selection: $container.spoofHorizontalSizeClass) {
            Text("Unspecified").tag(0)
            Text("Compact").tag(1)
            Text("Regular").tag(2)
        }
        .onChange(of: container.spoofHorizontalSizeClass) { _, _ in _ = saveSpoofProfile() }
        Picker("Vertical Size Class", selection: $container.spoofVerticalSizeClass) {
            Text("Unspecified").tag(0)
            Text("Compact").tag(1)
            Text("Regular").tag(2)
        }
        .onChange(of: container.spoofVerticalSizeClass) { _, _ in _ = saveSpoofProfile() }
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
        .onChange(of: container.spoofPreferredContentSizeCategory) { _, _ in _ = saveSpoofProfile() }
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

    @ViewBuilder
    private var localeAndTimeZoneGroup: some View {
        DisclosureGroup("Locale & Time Zone") {
            HStack {
                Text("Locale ID")
                TextField("en_US", text: $typingSpoofLocaleIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
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
                    .onSubmit { _ = saveSpoofProfile() }
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

            featureToggle("Hide Active Keyboard/Input Modes", "locale.inputModes")
            Button("Save Locale & Time Zone") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofLocaleCategoryEnabled)
    }

    @ViewBuilder
    private var batteryAndPowerGroup: some View {
        DisclosureGroup("Battery & Power") {
            HStack {
                Text("Battery Level (0–1)")
                TextField("0.84", text: $typingSpoofBatteryLevel)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            Picker("Battery State", selection: $spoofBatteryStateSelection) {
                Text("Unknown").tag(UIDevice.BatteryState.unknown.rawValue)
                Text("Unplugged").tag(UIDevice.BatteryState.unplugged.rawValue)
                Text("Charging").tag(UIDevice.BatteryState.charging.rawValue)
                Text("Full").tag(UIDevice.BatteryState.full.rawValue)
            }
            .onChange(of: spoofBatteryStateSelection) { _, _ in _ = saveSpoofProfile() }
            Toggle("Low Power Mode", isOn: $spoofLowPowerModeEnabled)
                .onChange(of: spoofLowPowerModeEnabled) { _, _ in _ = saveSpoofProfile() }
            Button("Save Battery") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofBatteryCategoryEnabled)
    }

    @ViewBuilder
    private var telephonyGroup: some View {
        DisclosureGroup("Telephony") {
            HStack {
                Text("Subscriber ID")
                TextField("UUID", text: $typingSpoofSubscriberIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            HStack {
                Text("Carrier Token (Base64)")
                TextField("Optional", text: $typingSpoofSubscriberCarrierTokenBase64)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { _ = saveSpoofProfile() }
            }
            Toggle("Spoof SIM Inserted", isOn: $spoofSubscriberSIMInsertedEnabled)
                .onChange(of: spoofSubscriberSIMInsertedEnabled) { _, _ in _ = saveSpoofProfile() }
            if spoofSubscriberSIMInsertedEnabled {
                Toggle("SIM Inserted", isOn: $spoofSubscriberSIMInserted)
                    .onChange(of: spoofSubscriberSIMInserted) { _, _ in _ = saveSpoofProfile() }
            }
            Picker("Radio Tech", selection: $typingSpoofRadioAccessTechnology) {
                Text("None (Use Host)").tag("")
                ForEach(availableRadioAccessTechnologies(), id: \.self) { tech in
                    Text(tech).tag(tech)
                }
            }
            .onChange(of: typingSpoofRadioAccessTechnology) { _, _ in _ = saveSpoofProfile() }
            Button("Save Telephony") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofTelephonyCategoryEnabled)
    }

    @ViewBuilder
    private var networkHeadersGroup: some View {
        DisclosureGroup("Network Headers") {
            featureToggle("Rewrite User-Agent Headers", "networkHeaders.userAgent")
            labeledTextRow("Custom User-Agent", placeholder: "Empty = synthesized", text: $container.spoofCustomUserAgent)
            Button("Save Network Headers") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofNetworkHeadersCategoryEnabled)
    }

    @ViewBuilder
    private var accessibilityGroup: some View {
        DisclosureGroup("Accessibility") {
            Picker("Contrast", selection: $container.spoofAccessibilityContrast) {
                Text("Normal").tag(0)
                Text("High").tag(1)
            }
            .onChange(of: container.spoofAccessibilityContrast) { _, _ in _ = saveSpoofProfile() }
            DisclosureGroup("Accessibility Features Reported Off") {
                featureToggle("VoiceOver", "accessibility.voiceOver")
                featureToggle("Switch Control", "accessibility.switchControl")
                featureToggle("Guided Access", "accessibility.guidedAccess")
                featureToggle("Grayscale", "accessibility.grayscale")
                featureToggle("Invert Colors", "accessibility.invertColors")
                featureToggle("Reduce Motion", "accessibility.reduceMotion")
                featureToggle("Reduce Transparency", "accessibility.reduceTransparency")
                featureToggle("AssistiveTouch", "accessibility.assistiveTouch")
                featureToggle("Shake to Undo", "accessibility.shakeToUndo")
                featureToggle("Bold Text", "accessibility.boldText")
                featureToggle("Button Shapes", "accessibility.buttonShapes")
                featureToggle("Darker System Colors", "accessibility.darkerColors")
                featureToggle("Mono Audio", "accessibility.monoAudio")
                featureToggle("Speak Screen", "accessibility.speakScreen")
                featureToggle("Speak Selection", "accessibility.speakSelection")
                featureToggle("Closed Captions", "accessibility.closedCaptions")
                featureToggle("Video Autoplay", "accessibility.videoAutoplay")
                featureToggle("Differentiate Without Color", "accessibility.differentiateWithoutColor")
                featureToggle("On/Off Switch Labels", "accessibility.onOffLabels")
            }
        }
        .disabled(!container.spoofAccessibilityCategoryEnabled)
    }

    @ViewBuilder
    private var storageGroup: some View {
        DisclosureGroup("Storage") {
            featureToggle("Override Capacity", "storage.capacity")
            labeledInt64Row("Total Capacity (Bytes)", value: $container.spoofStorageTotalCapacity)
            labeledInt64Row("Available Capacity (Bytes)", value: $container.spoofStorageAvailableCapacity)
            featureToggle("Override Volume Identity", "storage.identity")
            labeledTextRow("Volume Name", placeholder: "Data", text: $container.spoofStorageVolumeName)
            labeledTextRow("Volume UUID", placeholder: "UUID", text: $container.spoofStorageVolumeUUID)
            featureToggle("Override Creation Dates", "storage.creationDates")
            labeledInt64Row("File Creation (Unix)", value: $container.spoofStorageFileCreationTime)
            labeledInt64Row("Volume Creation (Unix)", value: $container.spoofStorageVolumeCreationTime)
            Button("Save Storage") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofStorageCategoryEnabled)
    }

    @ViewBuilder
    private var networkEnvironmentGroup: some View {
        DisclosureGroup("Network Environment") {
            featureToggle("Override Host Name", "network.hostName")
            featureToggle("Hide Network Interfaces", "network.interfaces")
            featureToggle("Stop Path Monitoring (Off by Default)", "network.pathMonitor")
            featureToggle("Block Bonjour / Service Discovery", "network.serviceDiscovery")
            featureToggle("Hide Proxy and VPN Settings", "network.proxy")
        }
        .disabled(!container.spoofNetworkEnvironmentCategoryEnabled)
    }

    @ViewBuilder
    private var audioRoutesGroup: some View {
        DisclosureGroup("Audio Routes") {
            featureToggle("Hide Available Inputs", "audio.availableInputs")
            featureToggle("Hide Current Route Inputs/Outputs", "audio.routes")
            featureToggle("Override Output Volume", "audio.outputVolume")
            labeledDoubleRow("Output Volume (0–1)", value: $container.spoofAudioOutputVolume)
            featureToggle("Override Sample Rate", "audio.sampleRate")
            labeledDoubleRow("Sample Rate (Hz)", value: $container.spoofAudioSampleRate)
            featureToggle("Override Output Latency", "audio.outputLatency")
            labeledDoubleRow("Output Latency (s)", value: $container.spoofAudioOutputLatency)
            featureToggle("Override Input Latency", "audio.inputLatency")
            labeledDoubleRow("Input Latency (s)", value: $container.spoofAudioInputLatency)
            featureToggle("Override Other Audio Playing", "audio.otherPlaying")
            Toggle("Other Audio Playing", isOn: $container.spoofAudioOtherPlaying)
                .onChange(of: container.spoofAudioOtherPlaying) { _, _ in _ = saveSpoofProfile() }
            featureToggle("Override Channel Counts", "audio.channels")
            Stepper("Output Channels: \(container.spoofAudioOutputChannels)", value: $container.spoofAudioOutputChannels, in: 0...32)
                .onChange(of: container.spoofAudioOutputChannels) { _, _ in _ = saveSpoofProfile() }
            Stepper("Input Channels: \(container.spoofAudioInputChannels)", value: $container.spoofAudioInputChannels, in: 0...32)
                .onChange(of: container.spoofAudioInputChannels) { _, _ in _ = saveSpoofProfile() }
            Button("Save Audio") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofAudioCategoryEnabled)
    }

    @ViewBuilder
    private var graphicsAndMetalGroup: some View {
        DisclosureGroup("Graphics & Metal") {
            featureToggle("Override GPU Name", "graphics.name")
            labeledTextRow("GPU Name", placeholder: "Apple A20 Pro GPU", text: $container.spoofGPUName)
            featureToggle("Override Recommended Working Set", "graphics.workingSet")
            labeledInt64Row("Working Set (Bytes)", value: $container.spoofGPUWorkingSetSize)
            featureToggle("Report Ray Tracing Support", "graphics.rayTracing")
            Toggle("Ray Tracing Result", isOn: $container.spoofGraphicsSupportsRayTracing)
                .onChange(of: container.spoofGraphicsSupportsRayTracing) { _, _ in _ = saveSpoofProfile() }
            featureToggle("Report All Metal Families", "graphics.allFamilies")
            Toggle("Metal Families Result", isOn: $container.spoofGraphicsSupportsAllFamilies)
                .onChange(of: container.spoofGraphicsSupportsAllFamilies) { _, _ in _ = saveSpoofProfile() }
            Button("Save Graphics") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofGraphicsCategoryEnabled)
    }

    @ViewBuilder
    private var webViewFingerprintGroup: some View {
        DisclosureGroup("WebView Fingerprint") {
            featureToggle("Override Navigator and User-Agent", "web.navigator")
            featureToggle("Override Screen and Device Pixel Ratio", "web.screen")
            featureToggle("Override Time Zone", "web.timeZone")
            featureToggle("Override WebGL (WebGL1 + WebGL2)", "web.webGL")
            labeledTextRow("WebGL Vendor", placeholder: "Apple Inc.", text: $container.spoofWebGLVendor)
            labeledTextRow("WebGL Renderer", placeholder: "Apple GPU", text: $container.spoofWebGLRenderer)
            featureToggle("Override Canvas Output", "web.canvas")
            HStack {
                labeledTextRow("Canvas & Audio Farbling Seed", placeholder: "0xA53F91C2", text: $container.spoofWebCanvasSeed)
                Button {
                    container.spoofWebCanvasSeed = String(format: "0x%08X", UInt32.random(in: 1...UInt32.max))
                    _ = saveSpoofProfile()
                } label: {
                    Image(systemName: "die.face.5")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Randomize Canvas Farbling Seed")
            }
            Stepper("Color Depth: \(container.spoofWebColorDepth)", value: $container.spoofWebColorDepth, in: 1...64)
                .onChange(of: container.spoofWebColorDepth) { _, _ in _ = saveSpoofProfile() }
            Button("Save WebView") { _ = saveSpoofProfile() }
        }
        .disabled(!container.spoofWebViewCategoryEnabled)
    }

    @ViewBuilder
    private var appAndAccountPrivacyGroup: some View {
        DisclosureGroup("App & Account Privacy") {
            featureToggle("Hide URL-Scheme App Detection", "app.canOpenURL")
            featureToggle("Use Neutral Font Families", "app.fonts")
            featureToggle("Hide Installed Speech Voices", "app.voices")
            featureToggle("Hide iCloud Account Identity", "app.iCloud")
            featureToggle("Use Isolated General Pasteboard", "app.pasteboard")
        }
        .disabled(!container.spoofAppPrivacyCategoryEnabled)
    }

    @ViewBuilder
    private var sensorsAndPermissionsGroup: some View {
        DisclosureGroup("Sensors & Permissions (Deny/Hide)") {
            featureToggle("Accelerometer Unavailable", "sensors.accelerometer")
            featureToggle("Gyroscope Unavailable", "sensors.gyroscope")
            featureToggle("Magnetometer Unavailable", "sensors.magnetometer")
            featureToggle("Device Motion Unavailable", "sensors.deviceMotion")
            featureToggle("Pedometer Unavailable", "sensors.pedometer")
            featureToggle("Altimeter Unavailable", "sensors.altimeter")
            featureToggle("Deny Location Status", "permissions.location")
            featureToggle("Deny Camera & Microphone Status", "permissions.capture")
            featureToggle("Deny Photos Status", "permissions.photos")
            featureToggle("Deny Contacts Status", "permissions.contacts")
            featureToggle("Deny Calendars & Reminders Status", "permissions.events")
            featureToggle("Deny Media Library Status", "permissions.media")
            featureToggle("Deny Bluetooth Status", "permissions.bluetooth")
        }
        .disabled(!container.spoofSensorsAndUserDataCategoryEnabled)
    }

    // MARK: - Container Management & Unavailable Bookmark Sections

    @ViewBuilder
    private var managementActionsSection: some View {
        Section {
            if inUse {
                Text("lc.container.inUse".loc)
                    .foregroundStyle(.gray)
            } else {
                if !container.isShared || container.storageBookMark != nil {
                    Button { openDataFolder() } label: {
                        Text("lc.appBanner.openDataFolder".loc)
                    }
                    Button { unbindContainer() } label: {
                        Text("lc.container.unbind".loc)
                    }
                }
                Button(role: .destructive) {
                    Task { await deleteData() }
                } label: {
                    Text("lc.container.deleteData".loc)
                }
                Button(role: .destructive) {
                    Task { await cleanUpKeychain() }
                } label: {
                    Text("lc.settings.cleanKeychain".loc)
                }
                if container.storageBookMark == nil {
                    Button(role: .destructive) {
                        Task { await removeContainer() }
                    } label: {
                        Text("lc.container.removeContainer".loc)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var unavailableBookmarkSection: some View {
        Section {
            if container.bookmarkResolved {
                Text("lc.container.externalStorageUnavailable".loc)
            } else {
                Text("lc.container.bookmarkResolveInProgress".loc)
            }
        }
        Section {
            Button(role: .destructive) {
                Task { await removeContainer() }
            } label: {
                Text("lc.container.removeContainer".loc)
            }
        }
    }

    // MARK: - Field Helpers

    private func categoryToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, _ in _ = saveSpoofProfile() }
    }

    private func featureBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { container.isSpoofFeatureEnabled(key) },
            set: { value in
                var overrides = container.spoofFeatureOverrides
                overrides[key] = value
                container.spoofFeatureOverrides = overrides
                _ = saveSpoofProfile()
            }
        )
    }

    private func featureToggle(_ title: String, _ key: String) -> some View {
        Toggle(title, isOn: featureBinding(key))
    }

    private func labeledTextRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .onSubmit { _ = saveSpoofProfile() }
        }
    }

    private func labeledIntRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func labeledInt64Row(_ label: String, value: Binding<Int64>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func labeledDoubleRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            TextField(label, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Lifecycle, Persistence & Presets

    private func handleAppear() {
        container.loadName()
        if container.strictTestMode {
            container.isolateAppGroup = true
            container.blockDeviceInfoReads = true
        }
        syncDraftStateFromContainer()
        settingsBundle = delegate.getSettingsBundle()
        runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName)
        inUse = runningLC != nil
    }

    private func syncDraftStateFromContainer() {
        typingContainerName = container.name
        typingIDFV = container.spoofedIdentifier ?? ""
        typingSpoofDeviceName = container.spoofDeviceName
        typingSpoofDeviceModel = container.spoofDeviceModel
        typingSpoofSystemName = container.spoofSystemName
        typingSpoofSystemVersion = container.spoofSystemVersion
        typingSpoofLocaleIdentifier = container.spoofLocaleIdentifier
        typingSpoofTimeZoneIdentifier = container.spoofTimeZoneIdentifier
        typingSpoofBatteryLevel = String(format: "%.2f", container.spoofBatteryLevel)
        spoofBatteryStateSelection = container.spoofBatteryState
        spoofLowPowerModeEnabled = container.spoofLowPowerModeEnabled
        typingSpoofSubscriberIdentifier = container.spoofSubscriberIdentifier
        typingSpoofSubscriberCarrierTokenBase64 = container.spoofSubscriberCarrierTokenBase64
        spoofSubscriberSIMInsertedEnabled = container.spoofSubscriberSIMInsertedEnabled
        spoofSubscriberSIMInserted = container.spoofSubscriberSIMInserted
        typingSpoofRadioAccessTechnology = container.spoofRadioAccessTechnology
        typingSpoofHardwareModel = container.spoofHardwareModel
        selectedCatalogVariantId = LCDeviceModelSpec.find(
            variantId: container.spoofDeviceVariantId,
            hwMachine: container.spoofHardwareModel
        )?.variantId ?? ""
    }

    private func commitContainerNameIfChanged() {
        let trimmed = typingContainerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != container.name {
            container.name = trimmed
        }
    }

    @discardableResult
    func saveSpoofProfile() -> Bool {
        if container.rotateSpoofProfileOnLaunch && parsedRotationOSMajors() == nil {
            errorInfo = "OS Major Versions must be a comma-separated list of numbers, for example 26,27."
            errorShow = true
            return false
        }
        let rawIDFV = typingIDFV.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.spoofIdentityCategoryEnabled && container.spoofIdentifierForVendor {
            if rawIDFV.isEmpty {
                let generatedIDFV = UUID().uuidString
                typingIDFV = generatedIDFV
                container.spoofedIdentifier = generatedIDFV
            } else if let normalizedIDFV = UUID(uuidString: rawIDFV) {
                let normalizedValue = normalizedIDFV.uuidString
                typingIDFV = normalizedValue
                container.spoofedIdentifier = normalizedValue
            } else {
                errorInfo = "lc.container.invalidIDFV".loc
                errorShow = true
                return false
            }
        } else if container.spoofIdentityCategoryEnabled {
            container.spoofedIdentifier = nil
        }

        let normalizedSystemVersion = typingSpoofSystemVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.spoofSystemCategoryEnabled && !normalizedSystemVersion.isEmpty && !isValidSystemVersion(normalizedSystemVersion) {
            errorInfo = "System Version must use numbers like 27 or 27.2 or 27.2.1."
            errorShow = true
            return false
        }

        let rawLocale = typingSpoofLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocale: String
        if rawLocale.isEmpty {
            normalizedLocale = ""
        } else if !container.spoofLocaleCategoryEnabled {
            normalizedLocale = rawLocale
        } else if let localeIdentifier = normalizedLocaleIdentifier(rawLocale) {
            normalizedLocale = localeIdentifier
        } else {
            errorInfo = "Locale ID is invalid. Example: en_US or en-US."
            errorShow = true
            return false
        }

        let rawTimeZone = typingSpoofTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTimeZone: String
        if rawTimeZone.isEmpty {
            normalizedTimeZone = ""
        } else if !container.spoofLocaleCategoryEnabled {
            normalizedTimeZone = rawTimeZone
        } else if let zoneIdentifier = normalizedTimeZoneIdentifier(rawTimeZone) {
            normalizedTimeZone = zoneIdentifier
        } else {
            errorInfo = "Time Zone is invalid. Example: America/New_York."
            errorShow = true
            return false
        }

        let normalizedBattery = typingSpoofBatteryLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.spoofBatteryCategoryEnabled && Double(normalizedBattery) == nil {
            errorInfo = "Battery Level must be a number."
            errorShow = true
            return false
        }
        let batteryLevel = Double(normalizedBattery) ?? container.spoofBatteryLevel
        if container.spoofBatteryCategoryEnabled && !(0.0...1.0).contains(batteryLevel) {
            errorInfo = "Battery Level must be between 0.0 and 1.0."
            errorShow = true
            return false
        }

        let subscriberID = typingSpoofSubscriberIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscriberTokenBase64 = typingSpoofSubscriberCarrierTokenBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        if container.spoofTelephonyCategoryEnabled && !subscriberTokenBase64.isEmpty && Data(base64Encoded: subscriberTokenBase64) == nil {
            errorInfo = "Carrier Token must be valid Base64."
            errorShow = true
            return false
        }

        if container.spoofBootTime <= 0 {
            container.spoofBootTime = Int64(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)
        }
        let systemValuesValid = !container.spoofSystemCategoryEnabled || (
            container.spoofProcessorCount > 0 &&
            container.spoofPhysicalMemory > 0 &&
            !container.spoofKernelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            container.spoofBootTime > 0 && container.spoofCPUType > 0 && container.spoofCPUSubtype >= 0)
        let thermalValueValid = (!container.spoofBatteryCategoryEnabled && !container.spoofSystemCategoryEnabled) ||
            (0...3).contains(container.spoofThermalState)
        let displayValuesValid = !container.spoofDisplayCategoryEnabled || (
            container.spoofScreenWidth > 0 && container.spoofScreenHeight > 0 &&
            container.spoofScreenScale > 0 && container.spoofScreenNativeScale > 0 &&
            container.spoofMaximumFramesPerSecond > 0 &&
            (0.0...1.0).contains(container.spoofScreenBrightness) &&
            (0...2).contains(container.spoofUserInterfaceStyle) &&
            (0...2).contains(container.spoofDisplayGamut) &&
            (0...2).contains(container.spoofHorizontalSizeClass) &&
            (0...2).contains(container.spoofVerticalSizeClass) &&
            container.spoofSafeAreaTop >= 0 && container.spoofSafeAreaLeft >= 0 &&
            container.spoofSafeAreaBottom >= 0 && container.spoofSafeAreaRight >= 0)
        let extendedValuesValid = (!container.spoofStorageCategoryEnabled || (
            container.spoofStorageTotalCapacity > 0 && container.spoofStorageAvailableCapacity >= 0 &&
            container.spoofStorageAvailableCapacity <= container.spoofStorageTotalCapacity)) &&
            (!container.spoofAudioCategoryEnabled || (
                (0.0...1.0).contains(container.spoofAudioOutputVolume) && container.spoofAudioSampleRate > 0 &&
                container.spoofAudioOutputLatency >= 0 && container.spoofAudioInputLatency >= 0 &&
                container.spoofAudioOutputChannels >= 0 && container.spoofAudioInputChannels >= 0)) &&
            (!container.spoofGraphicsCategoryEnabled || container.spoofGPUWorkingSetSize > 0) &&
            (!container.spoofWebViewCategoryEnabled || (1...64).contains(container.spoofWebColorDepth))
        guard systemValuesValid && thermalValueValid && displayValuesValid && extendedValuesValid else {
            errorInfo = "Profile values are invalid. Capacities must be consistent, volume/brightness must be between 0 and 1, and enabled names cannot be empty."
            errorShow = true
            return false
        }

        container.spoofDeviceName = typingSpoofDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofDeviceModel = typingSpoofDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofSystemName = typingSpoofSystemName.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofSystemVersion = normalizedSystemVersion
        container.spoofLocaleIdentifier = normalizedLocale
        container.spoofTimeZoneIdentifier = normalizedTimeZone
        container.spoofBatteryLevel = batteryLevel
        container.spoofBatteryState = spoofBatteryStateSelection
        container.spoofLowPowerModeEnabled = spoofLowPowerModeEnabled
        container.spoofSubscriberIdentifier = subscriberID
        container.spoofSubscriberCarrierTokenBase64 = subscriberTokenBase64
        container.spoofSubscriberSIMInsertedEnabled = spoofSubscriberSIMInsertedEnabled
        container.spoofSubscriberSIMInserted = spoofSubscriberSIMInserted
        container.spoofRadioAccessTechnology = typingSpoofRadioAccessTechnology.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofHardwareModel = typingSpoofHardwareModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !container.spoofDeviceVariantId.isEmpty,
           let currentSpec = LCDeviceModelSpec.find(variantId: container.spoofDeviceVariantId),
           currentSpec.hwMachine != container.spoofHardwareModel {
            container.spoofDeviceVariantId = ""
        }
        container.spoofHostName = container.spoofHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofBoardModel = container.spoofBoardModel.trimmingCharacters(in: .whitespacesAndNewlines)
        container.spoofKernelVersion = container.spoofKernelVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        saveContainer()
        return true
    }

    private func saveSpoofProfileSilently() {
        commitContainerNameIfChanged()
        if container.spoofProfileEnabled {
            container.spoofDeviceName = typingSpoofDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofDeviceModel = typingSpoofDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofSystemName = typingSpoofSystemName.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawOS = typingSpoofSystemVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawOS.isEmpty || isValidSystemVersion(rawOS) {
                container.spoofSystemVersion = rawOS
            }
            let rawIDFV = typingIDFV.trimmingCharacters(in: .whitespacesAndNewlines)
            if let validIDFV = UUID(uuidString: rawIDFV) {
                container.spoofedIdentifier = validIDFV.uuidString
            }
            container.spoofHostName = container.spoofHostName.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofBoardModel = container.spoofBoardModel.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofKernelVersion = container.spoofKernelVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofHardwareModel = typingSpoofHardwareModel.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofRadioAccessTechnology = typingSpoofRadioAccessTechnology.trimmingCharacters(in: .whitespacesAndNewlines)
            container.spoofBatteryState = spoofBatteryStateSelection
            container.spoofLowPowerModeEnabled = spoofLowPowerModeEnabled
            if let batt = Double(typingSpoofBatteryLevel.trimmingCharacters(in: .whitespacesAndNewlines)),
               (0.0...1.0).contains(batt) {
                container.spoofBatteryLevel = batt
            }
            let rawLocale = typingSpoofLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawLocale.isEmpty || normalizedLocaleIdentifier(rawLocale) != nil {
                container.spoofLocaleIdentifier = rawLocale.isEmpty ? "" : (normalizedLocaleIdentifier(rawLocale) ?? rawLocale)
            }
            let rawTZ = typingSpoofTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawTZ.isEmpty || normalizedTimeZoneIdentifier(rawTZ) != nil {
                container.spoofTimeZoneIdentifier = rawTZ.isEmpty ? "" : (normalizedTimeZoneIdentifier(rawTZ) ?? rawTZ)
            }
        }
        if LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) == nil {
            delegate.saveContainer(container: container)
        }
    }

    func hasConfiguredSpoofTemplate() -> Bool {
        [
            typingSpoofDeviceName, typingSpoofDeviceModel, typingSpoofSystemName,
            typingSpoofSystemVersion, typingSpoofLocaleIdentifier,
            typingSpoofTimeZoneIdentifier, typingSpoofHardwareModel
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func applyCurrentDeviceProfileValues() {
        container.spoofIdentifierForVendor = true
        container.spoofedIdentifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        container.spoofDeviceName = UIDevice.current.name
        container.spoofDeviceModel = UIDevice.current.model
        container.spoofSystemName = UIDevice.current.systemName
        container.spoofSystemVersion = UIDevice.current.systemVersion
        container.spoofLocaleIdentifier = Locale.current.identifier
        container.spoofTimeZoneIdentifier = TimeZone.current.identifier
        container.spoofBatteryLevel = 0.85
        container.spoofBatteryState = UIDevice.BatteryState.charging.rawValue
        container.spoofLowPowerModeEnabled = false
        container.spoofSubscriberIdentifier = ""
        container.spoofSubscriberCarrierTokenBase64 = ""
        container.spoofSubscriberSIMInsertedEnabled = false
        container.spoofSubscriberSIMInserted = false
        container.spoofRadioAccessTechnology = ""
        let machine = LCProfileLeakAnalyzer.currentHostMachine()
        container.spoofHardwareModel = machine
        container.spoofDeviceVariantId = LCDeviceModelSpec.find(hwMachine: machine)?.variantId ?? ""
        container.spoofHostName = currentSysctlString("kern.hostname")
        container.spoofBoardModel = currentSysctlString("hw.model")
        container.spoofKernelVersion = currentSysctlString("kern.version")
        container.spoofBootTime = Int64(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)
        container.spoofCPUType = Int(currentSysctlInt64("hw.cputype"))
        container.spoofCPUSubtype = Int(currentSysctlInt64("hw.cpusubtype"))
        container.spoofProcessorCount = ProcessInfo.processInfo.processorCount
        container.spoofPhysicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        container.spoofThermalState = ProcessInfo.processInfo.thermalState.rawValue
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let screen = scene.screen
            container.spoofScreenWidth = screen.nativeBounds.width
            container.spoofScreenHeight = screen.nativeBounds.height
            container.spoofScreenScale = screen.scale
            container.spoofScreenNativeScale = screen.nativeScale
            container.spoofMaximumFramesPerSecond = screen.maximumFramesPerSecond
            container.spoofScreenBrightness = screen.brightness
            let traits = scene.traitCollection
            container.spoofUserInterfaceStyle = traits.userInterfaceStyle.rawValue
            container.spoofAccessibilityContrast = traits.accessibilityContrast.rawValue
            container.spoofDisplayGamut = traits.displayGamut.rawValue
            container.spoofHorizontalSizeClass = traits.horizontalSizeClass.rawValue
            container.spoofVerticalSizeClass = traits.verticalSizeClass.rawValue
            container.spoofPreferredContentSizeCategory = traits.preferredContentSizeCategory.rawValue
            if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
                container.spoofSafeAreaTop = window.safeAreaInsets.top
                container.spoofSafeAreaLeft = window.safeAreaInsets.left
                container.spoofSafeAreaBottom = window.safeAreaInsets.bottom
                container.spoofSafeAreaRight = window.safeAreaInsets.right
            }
        }
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            container.spoofStorageTotalCapacity = Int64(values.volumeTotalCapacity ?? Int(container.spoofStorageTotalCapacity))
            container.spoofStorageAvailableCapacity = Int64(values.volumeAvailableCapacity ?? Int(container.spoofStorageAvailableCapacity))
        }
        if let gpu = MTLCreateSystemDefaultDevice() {
            container.spoofGPUName = gpu.name
            container.spoofGPUWorkingSetSize = Int64(clamping: gpu.recommendedMaxWorkingSetSize)
        }
        let audio = AVAudioSession.sharedInstance()
        container.spoofAudioOutputVolume = Double(audio.outputVolume)
        container.spoofAudioSampleRate = audio.sampleRate
        container.spoofAudioOutputLatency = audio.outputLatency
        container.spoofAudioInputLatency = audio.inputLatency
        container.spoofAudioOtherPlaying = audio.isOtherAudioPlaying
        container.spoofAudioOutputChannels = audio.outputNumberOfChannels
        container.spoofAudioInputChannels = audio.inputNumberOfChannels
        syncDraftStateFromContainer()
    }

    /// Generates a physically coherent device, OS/kernel, Metal GPU, display, and geo profile.
    func applyRandomDeviceProfileValues() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let spec = LCDeviceModelSpec.random(isPad: isPad)
        let allowedMajors = (parsedRotationOSMajors() ?? [26, 27]).filter { $0 >= spec.minOSMajor }
        let chosenMajor = allowedMajors.randomElement() ?? max(27, spec.minOSMajor)
        let minorVersion = Int.random(in: 0...3)
        let patchVersion = Int.random(in: 0...2)
        let osVersion = patchVersion == 0
            ? "\(chosenMajor).\(minorVersion)"
            : "\(chosenMajor).\(minorVersion).\(patchVersion)"
        let geo = LCDeviceModelSpec.coherentGeoPair()
        let batteryLevel = Double.random(in: 0.25...0.96)
        let tokenBytes = (0..<24).map { _ in UInt8.random(in: 0...255) }

        container.spoofIdentifierForVendor = true
        container.spoofedIdentifier = UUID().uuidString
        container.spoofDeviceName = spec.marketingName
        container.applyHardwareSpec(spec, osVersionOverride: osVersion)
        container.spoofHostName = spec.marketingName
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        container.spoofBootTime = Int64(Date().timeIntervalSince1970) - Int64.random(in: 86_400...1_209_600)
        container.spoofLocaleIdentifier = geo.locale
        container.spoofTimeZoneIdentifier = geo.timeZone
        container.spoofBatteryLevel = batteryLevel
        container.spoofBatteryState = [
            UIDevice.BatteryState.unplugged.rawValue,
            UIDevice.BatteryState.charging.rawValue
        ].randomElement() ?? UIDevice.BatteryState.unplugged.rawValue
        container.spoofLowPowerModeEnabled = false
        container.spoofThermalState = 0
        container.spoofSubscriberIdentifier = UUID().uuidString.uppercased()
        container.spoofSubscriberCarrierTokenBase64 = Data(tokenBytes).base64EncodedString()
        container.spoofSubscriberSIMInsertedEnabled = true
        container.spoofSubscriberSIMInserted = true
        container.spoofRadioAccessTechnology = geo.radio

        let storageGB: Int64 = [128, 256, 512, 1024].randomElement() ?? 256
        container.spoofStorageTotalCapacity = storageGB * 1_073_741_824
        let maximumFreeGB = max(Int64(16), storageGB - 16)
        container.spoofStorageAvailableCapacity = Int64.random(in: 16...maximumFreeGB) * 1_073_741_824
        container.spoofStorageVolumeUUID = UUID().uuidString.uppercased()
        container.spoofAudioOutputVolume = Double.random(in: 0.2...0.85)
        container.spoofAudioSampleRate = [44_100.0, 48_000.0].randomElement() ?? 48_000.0
        container.spoofAudioOutputLatency = Double.random(in: 0.005...0.025)
        container.spoofAudioInputLatency = Double.random(in: 0.005...0.025)
        container.spoofAudioOtherPlaying = false
        container.spoofAudioOutputChannels = 2
        container.spoofAudioInputChannels = 1
        syncDraftStateFromContainer()
    }

    private func parsedRotationOSMajors() -> [Int]? {
        let values = container.rotateOSMajorVersions
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !values.isEmpty,
              values.allSatisfy({ value in
                  guard !value.isEmpty, let major = Int(value) else { return false }
                  return (1...99).contains(major)
              }) else {
            return nil
        }
        return Array(Set(values.compactMap(Int.init))).sorted()
    }

    func normalizedLocaleIdentifier(_ raw: String) -> String? {
        let bcp47Normalized = raw.replacingOccurrences(of: "-", with: "_")
        let canonical = Locale.identifier(.icu, from: bcp47Normalized)
        let components = NSLocale.components(fromLocaleIdentifier: canonical)
        if let languageCode = components[NSLocale.Key.languageCode.rawValue], !languageCode.isEmpty {
            return canonical
        }
        return nil
    }

    func normalizedTimeZoneIdentifier(_ raw: String) -> String? {
        if let zone = TimeZone(identifier: raw) {
            return zone.identifier
        }
        if let zone = TimeZone(abbreviation: raw.uppercased()) {
            return zone.identifier
        }
        return nil
    }

    func availableRadioAccessTechnologies() -> [String] {
        [
            "CTRadioAccessTechnologyNR",
            "CTRadioAccessTechnologyNRNSA",
            "CTRadioAccessTechnologyLTE",
            "CTRadioAccessTechnologyWCDMA",
            "CTRadioAccessTechnologyHSDPA",
            "CTRadioAccessTechnologyHSUPA",
            "CTRadioAccessTechnologyCDMAEVDORevA"
        ]
    }

    func currentSysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "" }
        return String(decoding: value.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    func currentSysctlInt64(_ name: String) -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var value32: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &value32, &size, nil, 0) == 0 { return Int64(value32) }
        return 0
    }

    func isValidSystemVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty && parts.count <= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    func saveContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        delegate.saveContainer(container: container)
    }

    func saveStrictModeSettings() {
        if container.strictTestMode {
            container.isolateAppGroup = true
            container.blockDeviceInfoReads = true
        }
        saveContainer()
    }

    func openDataFolder() {
        if let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(container.folderName)") {
            UIApplication.shared.open(url)
        }
    }

    func setAsDefault() {
        delegate.setDefaultContainer(container: container)
    }

    func removeContainer() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeContainerAlert.open(), ans else { return }
        do {
            try FileManager.default.removeItem(at: container.containerURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        dismiss()
        delegate.unbindContainer(container: container)
    }

    func unbindContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        dismiss()
        delegate.unbindContainer(container: container)
    }

    func cleanUpKeychain() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeKeychainAlert.open(), ans else { return }
        LCUtils.removeAppKeychain(dataUUID: container.folderName)
    }

    func deleteData() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await deleteDataAlert.open(), ans else { return }
        do {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: container.containerURL, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == "LCContainerInfo.plist" {
                    continue
                }
                try fm.removeItem(at: file)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}

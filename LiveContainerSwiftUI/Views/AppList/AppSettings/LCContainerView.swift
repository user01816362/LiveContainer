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

            LCContainerLaunchRotationSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerKillSwitchesSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerDeviceIdentitySection(
                container: container,
                typingIDFV: $typingIDFV,
                typingSpoofDeviceName: $typingSpoofDeviceName,
                typingSpoofDeviceModel: $typingSpoofDeviceModel,
                typingSpoofHardwareModel: $typingSpoofHardwareModel,
                selectedCatalogVariantId: $selectedCatalogVariantId,
                onSyncDraftState: { syncDraftStateFromContainer() },
                onSave: { saveSpoofProfile() }
            )
            LCContainerSystemAndDisplaySection(
                container: container,
                typingSpoofSystemName: $typingSpoofSystemName,
                typingSpoofSystemVersion: $typingSpoofSystemVersion,
                onSave: { saveSpoofProfile() }
            )
            LCContainerLocaleSection(
                container: container,
                typingSpoofLocaleIdentifier: $typingSpoofLocaleIdentifier,
                typingSpoofTimeZoneIdentifier: $typingSpoofTimeZoneIdentifier,
                showLocalePickerSheet: $showLocalePickerSheet,
                showTimeZonePickerSheet: $showTimeZonePickerSheet,
                onSave: { saveSpoofProfile() }
            )
            LCContainerBatterySection(
                container: container,
                typingSpoofBatteryLevel: $typingSpoofBatteryLevel,
                spoofBatteryStateSelection: $spoofBatteryStateSelection,
                spoofLowPowerModeEnabled: $spoofLowPowerModeEnabled,
                onSave: { saveSpoofProfile() }
            )
            LCContainerTelephonySection(
                container: container,
                typingSpoofSubscriberIdentifier: $typingSpoofSubscriberIdentifier,
                typingSpoofSubscriberCarrierTokenBase64: $typingSpoofSubscriberCarrierTokenBase64,
                spoofSubscriberSIMInsertedEnabled: $spoofSubscriberSIMInsertedEnabled,
                spoofSubscriberSIMInserted: $spoofSubscriberSIMInserted,
                typingSpoofRadioAccessTechnology: $typingSpoofRadioAccessTechnology,
                onSave: { saveSpoofProfile() }
            )
            LCContainerNetworkHeadersSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerAccessibilitySection(container: container, onSave: { saveSpoofProfile() })
            LCContainerStorageSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerNetworkEnvSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerAudioRoutesSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerGraphicsMetalSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerWebViewSection(container: container, onSave: { saveSpoofProfile() })
            LCContainerAppPrivacySection(container: container, onSave: { saveSpoofProfile() })
            LCContainerSensorsSection(container: container, onSave: { saveSpoofProfile() })
        }
        .disabled(container.blockDeviceInfoReads)
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

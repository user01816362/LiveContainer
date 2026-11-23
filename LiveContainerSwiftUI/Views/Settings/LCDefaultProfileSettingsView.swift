//
//  LCDefaultProfileSettingsView.swift
//  LiveContainerSwiftUI
//
//  Main Settings screen for configuring the automatic Default Profile Preset
//  applied whenever a new app container is created, managing custom presets,
//  and inspecting built-in 2026–2027 hardware templates.
//

import SwiftUI
import UIKit

/// Global privacy/device-spoof preset manager accessible from Main Settings.
struct LCDefaultProfileSettingsView: View {
    @ObservedObject private var presetStore = LCProfilePresetStore.shared
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var renamingPreset: LCProfilePreset?
    @State private var renameText = ""
    @State private var confirmBatchApply = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingPreset != nil },
            set: { if !$0 { renamingPreset = nil } }
        )
    }

    var body: some View {
        Form {
            globalPolicySection
            presetSelectionSection
            customPresetsSection
            builtInPresetsSection
            toolsSection
        }
        .navigationTitle("Default Container Profile")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Preset", isPresented: renameBinding) {
            TextField("Preset Name", text: $renameText)
            Button("Save") {
                if let preset = renamingPreset {
                    presetStore.renameCustomPreset(id: preset.id, newName: renameText)
                }
                renamingPreset = nil
            }
            Button("Cancel", role: .cancel) {
                renamingPreset = nil
            }
        }
        .confirmationDialog(
            "Apply Preset to All Idle Containers?",
            isPresented: $confirmBatchApply,
            titleVisibility: .visible
        ) {
            Button("Apply to Existing Containers", role: .destructive) {
                applyDefaultToExistingContainers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Applies the active global preset to every existing idle container while giving each container freshly minted IDFV and storage UUIDs.")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private var globalPolicySection: some View {
        Section {
            Picker("New Container Mode", selection: $presetStore.globalDefaultMode) {
                ForEach(LCGlobalDefaultProfileMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } header: {
            Text("Auto-Apply on Container Creation")
        } footer: {
            Text("\(presetStore.globalDefaultMode.subtitle) Covers fresh app installs, app cloning, first launch, and Create New Data Folder.")
        }
    }

    @ViewBuilder
    private var presetSelectionSection: some View {
        if presetStore.globalDefaultMode == .preset {
            Section {
                Picker("Default Preset", selection: $presetStore.globalDefaultPresetId) {
                    if !presetStore.customPresets.isEmpty {
                        Section("Custom Presets") {
                            ForEach(presetStore.customPresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                    }
                    Section("Built-in & Privacy Templates") {
                        ForEach(presetStore.builtInPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
                if let active = presetStore.selectedDefaultPreset {
                    presetSummaryRow(active)
                }
            } header: {
                Text("Selected Default Preset")
            }
        }
    }

    @ViewBuilder
    private var customPresetsSection: some View {
        Section {
            if presetStore.customPresets.isEmpty {
                Text("No custom presets yet. Open any container's Spoof Profile and tap 'Save Current as Preset' to create one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presetStore.customPresets) { preset in
                    presetRow(preset, isCustom: true)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                presetStore.deleteCustomPreset(id: preset.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = preset.name
                                renamingPreset = preset
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        } header: {
            Text("Custom Saved Presets")
        }
    }

    @ViewBuilder
    private var builtInPresetsSection: some View {
        Section {
            ForEach(presetStore.builtInPresets) { preset in
                presetRow(preset, isCustom: false)
            }
        } header: {
            Text("Built-in Apple Hardware & Privacy Presets")
        } footer: {
            Text("All built-in hardware presets pair verified hw.machine, board config, SoC core/memory limits, Metal GPU identifier, ProMotion refresh rate, and logical/native screen geometry.")
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        Section {
            if presetStore.globalDefaultMode != .off {
                Button {
                    confirmBatchApply = true
                } label: {
                    Label("Apply Policy to Existing Idle Containers", systemImage: "square.stack.3d.up.badge.a")
                }
            }

            if !presetStore.customPresets.isEmpty {
                Button {
                    copyCustomPresetsToClipboard()
                } label: {
                    Label("Copy Custom Presets JSON", systemImage: "doc.on.doc")
                }
            }

            Button {
                importCustomPresetsFromClipboard()
            } label: {
                Label("Import Presets JSON from Clipboard", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Batch & Backup")
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: LCProfilePreset, isCustom: Bool) -> some View {
        Button {
            presetStore.globalDefaultPresetId = preset.id
            presetStore.globalDefaultMode = .preset
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.iconSystemName)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if presetStore.globalDefaultMode == .preset && presetStore.globalDefaultPresetId == preset.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .contextMenu {
            Button {
                presetStore.globalDefaultPresetId = preset.id
                presetStore.globalDefaultMode = .preset
            } label: {
                Label("Set as Default for New Containers", systemImage: "checkmark.circle")
            }
            if isCustom {
                Button {
                    renameText = preset.name
                    renamingPreset = preset
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    presetStore.deleteCustomPreset(id: preset.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func presetSummaryRow(_ preset: LCProfilePreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preset.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if preset.payload.strictTestMode {
                    Label("Strict Ephemeral", systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if preset.payload.rotateSpoofProfileOnLaunch {
                    Label("Per-Launch Rotate", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Label(
                    preset.payload.isolateAppGroup ? "Isolated Group" : "Shared Group",
                    systemImage: "shippingbox"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func applyDefaultToExistingContainers() {
        var updatedCount = 0
        var skippedCount = 0
        let allApps = sharedModel.apps + sharedModel.hiddenApps
        for app in allApps {
            guard !app.appInfo.is32bit,
                  let bundleId = app.appInfo.bundleIdentifier(),
                  !bundleId.isEmpty else {
                continue
            }
            for container in app.uiContainers {
                let inMultitask = MultitaskManager.isUsing(container: container.folderName)
                let inOtherLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) != nil
                if inMultitask || inOtherLC {
                    skippedCount += 1
                    continue
                }
                LCProfilePresetStore.applyConfiguredDefault(to: container)
                let groupId = container.keychainGroupId >= 0
                    ? container.keychainGroupId
                    : LCContainer.allocateKeychainGroupId(excluding: app.uiContainers)
                container.makeLCContainerInfoPlist(appIdentifier: bundleId, keychainGroupId: groupId)
                updatedCount += 1
            }
            app.appInfo.containers = app.uiContainers
            app.appInfo.save()
        }
        alertTitle = "Batch Apply Finished"
        alertMessage = skippedCount > 0
            ? "Updated \(updatedCount) containers. Skipped \(skippedCount) currently running containers."
            : "Updated \(updatedCount) containers with fresh unique per-container identifiers."
        showAlert = true
    }

    private func copyCustomPresetsToClipboard() {
        guard let data = presetStore.exportCustomPresetsJSON(),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        UIPasteboard.general.string = text
        alertTitle = "Presets Copied"
        alertMessage = "Copied \(presetStore.customPresets.count) custom preset(s) to the clipboard as JSON."
        showAlert = true
    }

    private func importCustomPresetsFromClipboard() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8) else {
            alertTitle = "Import Failed"
            alertMessage = "Clipboard does not contain valid preset JSON."
            showAlert = true
            return
        }
        do {
            let count = try presetStore.importCustomPresetsJSON(data)
            alertTitle = "Presets Imported"
            alertMessage = "Imported \(count) custom preset(s)."
            showAlert = true
        } catch {
            alertTitle = "Import Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

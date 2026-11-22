//
//  LCAppMetadataEditorView.swift
//  LiveContainerSwiftUI
//
//  Interactive editor for an installed app's Display Name, Bundle Name,
//  Bundle Identifier (including extensions and localized strings), Version,
//  Build, and MinimumOSVersion, with backup/restore and optional re-signing.
//

import SwiftUI
import UIKit

struct LCAppMetadataEditorView: View {
    @ObservedObject var model: LCAppModel
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var displayName = ""
    @State private var bundleName = ""
    @State private var bundleIdentifier = ""
    @State private var shortVersion = ""
    @State private var buildVersion = ""
    @State private var minimumOSVersion = ""

    @State private var updateLocalizedNames = true
    @State private var updateExtensionBundleIds = true
    @State private var resignAfterSave = false
    @State private var didLoadInitialFields = false

    @State private var isSaving = false
    @State private var showRestoreConfirmation = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var copiedToast = false

    private var isSecondaryLC: Bool {
        sharedModel.multiLCStatus == 2
    }

    private var canResign: Bool {
        !model.uiDontSign &&
        !model.uiIs32bit &&
        LCUtils.certificateData() != nil &&
        LCSharedUtils.certificatePassword() != nil
    }

    private var extensionNames: [String] {
        model.appInfo.appExtensionNames()
    }

    private var hasOriginalBackup: Bool {
        _ = model.metadataRevision
        return model.appInfo.hasOriginalMetadataBackup()
    }

    private var originalBundleId: String? {
        model.appInfo.originalInfoPlistDictionary()?["CFBundleIdentifier"] as? String
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBundleName: String {
        bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBundleId: String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedShortVersion: String {
        shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBuildVersion: String {
        buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMinOS: String {
        minimumOSVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bundleIdValidationError: String? {
        if trimmedBundleId.isEmpty {
            return "Bundle Identifier cannot be empty."
        }
        if trimmedBundleId.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || trimmedBundleId.contains("/") {
            return "Bundle Identifier cannot contain spaces, newlines, or '/'."
        }
        return nil
    }

    private var hasValidInputs: Bool {
        let hasAnyName = !trimmedDisplayName.isEmpty || !trimmedBundleName.isEmpty
        return hasAnyName && bundleIdValidationError == nil
    }

    private var hasUnsavedChanges: Bool {
        let info = model.appInfo
        let currentDisplay = info.displayName() ?? ""
        let currentBundleName = info.bundleName() ?? ""
        let currentBundleId = info.bundleIdentifier() ?? ""
        let currentShortVersion = info.shortVersion() ?? ""
        let currentBuildVersion = info.buildVersion() ?? ""
        let currentMinOS = info.minimumOSVersion() ?? ""

        return trimmedDisplayName != currentDisplay ||
            trimmedBundleName != currentBundleName ||
            trimmedBundleId != currentBundleId ||
            trimmedShortVersion != currentShortVersion ||
            trimmedBuildVersion != currentBuildVersion ||
            trimmedMinOS != currentMinOS
    }

    private var previewDisplayName: String {
        if !trimmedDisplayName.isEmpty { return trimmedDisplayName }
        if !trimmedBundleName.isEmpty { return trimmedBundleName }
        return model.displayName
    }

    private var previewVersionSummary: String {
        let ver = trimmedShortVersion.isEmpty ? (trimmedBuildVersion.isEmpty ? "?" : trimmedBuildVersion) : trimmedShortVersion
        if !trimmedBuildVersion.isEmpty && trimmedBuildVersion != ver {
            return "\(ver) (\(trimmedBuildVersion))"
        }
        return ver
    }

    var body: some View {
        Form {
            headerSection

            if isSecondaryLC {
                Section {
                    Label("Secondary LiveContainer instances cannot edit app metadata.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
            }

            Section {
                TextField("Display Name", text: $displayName)
                    .textInputAutocapitalization(.words)
                    .disabled(isSecondaryLC || isSaving)

                TextField("Bundle Name (fallback)", text: $bundleName)
                    .textInputAutocapitalization(.words)
                    .disabled(isSecondaryLC || isSaving)

                Toggle("Update Localized Names", isOn: $updateLocalizedNames)
                    .disabled(isSecondaryLC || isSaving)
            } header: {
                Text("App Name")
            } footer: {
                Text("Updates CFBundleDisplayName and CFBundleName in Info.plist, and refreshes localized InfoPlist.strings display name entries when enabled.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("com.example.app", text: $bundleIdentifier)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .disabled(isSecondaryLC || isSaving)

                    if let validationError = bundleIdValidationError {
                        Text(validationError)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = trimmedBundleId
                        copiedToast = true
                    } label: {
                        Label(copiedToast ? "Copied" : "Copy", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Button {
                        if !trimmedBundleId.isEmpty && !trimmedBundleId.hasSuffix(".mod") {
                            bundleIdentifier = "\(trimmedBundleId).mod"
                        }
                    } label: {
                        Text("+ .mod")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isSecondaryLC || isSaving || trimmedBundleId.isEmpty)

                    if let originalBundleId, !originalBundleId.isEmpty, originalBundleId != trimmedBundleId {
                        Button("Original ID") {
                            bundleIdentifier = originalBundleId
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isSecondaryLC || isSaving)
                    }
                }

                if model.uiUseLCBundleId {
                    Label(
                        "Use LiveContainer Bundle ID is enabled: changes update LCOrignalBundleIdentifier while keeping LiveContainer's host bundle ID active in Info.plist.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }

                if !extensionNames.isEmpty {
                    Toggle("Update App Extensions (\(extensionNames.count))", isOn: $updateExtensionBundleIds)
                        .disabled(isSecondaryLC || isSaving)
                }
            } header: {
                Text("Bundle Identifier")
            } footer: {
                Text("Updates CFBundleIdentifier and keeps bound data containers synced. When Update App Extensions is enabled, PlugIns/*.appex identifiers sharing the old prefix are updated too.")
            }

            Section {
                LabeledContent("Version") {
                    TextField("CFBundleShortVersionString", text: $shortVersion)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSecondaryLC || isSaving)
                }

                LabeledContent("Build") {
                    TextField("CFBundleVersion", text: $buildVersion)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSecondaryLC || isSaving)
                }

                LabeledContent("Min iOS") {
                    TextField("Optional", text: $minimumOSVersion)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSecondaryLC || isSaving)
                }
            } header: {
                Text("Version & Compatibility")
            } footer: {
                Text("Controls CFBundleShortVersionString, CFBundleVersion, and MinimumOSVersion.")
            }

            Section {
                Toggle("Re-sign App After Saving", isOn: $resignAfterSave)
                    .disabled(!canResign || isSecondaryLC || isSaving)

                if !canResign {
                    Text(resignUnavailableReason)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Button {
                    Task { await saveMetadata(forceResign: resignAfterSave && canResign) }
                } label: {
                    HStack {
                        if isSaving || model.isSigningInProgress {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.isSigningInProgress ? "Re-signing App…" : "Saving…")
                        } else {
                            Image(systemName: (resignAfterSave && canResign) ? "signature" : "checkmark.circle.fill")
                            Text((resignAfterSave && canResign) ? "Save & Re-sign" : "Save Changes")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.body.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .disabled(isSecondaryLC || isSaving || model.isAppRunning || !hasValidInputs || !hasUnsavedChanges)

                if model.isSigningInProgress {
                    ProgressView(value: min(max(model.signProgress, 0), 1))
                        .progressViewStyle(.linear)
                }

                if canResign && !isSecondaryLC {
                    Button {
                        Task { await resignOnly() }
                    } label: {
                        Label("Re-sign App Bundle Now", systemImage: "signature")
                    }
                    .disabled(isSaving || model.isAppRunning || model.isSigningInProgress)
                }
            } header: {
                Text("Save & Signing")
            }

            Section {
                NavigationLink {
                    LCAppInfoPlistEditorView(model: model)
                } label: {
                    Label("Edit Full Info.plist", systemImage: "doc.badge.gearshape")
                }

                if hasOriginalBackup && !isSecondaryLC {
                    Button(role: .destructive) {
                        showRestoreConfirmation = true
                    } label: {
                        Label("Restore Original Metadata & Info.plist", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(isSaving || model.isAppRunning)
                }
            } header: {
                Text("Advanced & Backup")
            } footer: {
                Text("LiveContainer automatically stores a snapshot of the original Info.plist before your first edit so you can revert at any time.")
            }
        }
        .navigationTitle("App Metadata")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didLoadInitialFields {
                loadFromAppInfo()
                resignAfterSave = canResign
                didLoadInitialFields = true
            }
        }
        .onChange(of: model.metadataRevision) { _, _ in
            if !isSaving && !hasUnsavedChanges {
                loadFromAppInfo()
            }
        }
        .task(id: copiedToast) {
            guard copiedToast else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedToast = false
        }
        .confirmationDialog(
            "Restore Original Info.plist?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(canResign ? "Restore & Re-sign" : "Restore Original", role: .destructive) {
                Task { await restoreOriginal(forceResign: canResign) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("Reverts Info.plist, localized display names, and modified app extension IDs back to their pre-edit values.")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                if let icon = model.appInfo.iconIsDarkIcon(darkModeIcon) {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(previewDisplayName)
                            .font(.headline)
                            .lineLimit(1)
                        if hasOriginalBackup {
                            Text("Modified")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.14), in: .capsule)
                        }
                    }

                    Text(trimmedBundleId.isEmpty ? model.bundleIdentifier : trimmedBundleId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)

                    Text("v\(previewVersionSummary)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var resignUnavailableReason: String {
        if model.uiIs32bit {
            return "32-bit apps run under emulation and are not re-signed."
        }
        if model.uiDontSign {
            return "Signing is disabled in app settings (Don't Sign)."
        }
        return "Import a JIT-less certificate in Settings to enable automatic re-signing."
    }

    private func loadFromAppInfo() {
        let info = model.appInfo
        displayName = info.displayName() ?? ""
        bundleName = info.bundleName() ?? ""
        bundleIdentifier = info.bundleIdentifier() ?? ""
        shortVersion = info.shortVersion() ?? ""
        buildVersion = info.buildVersion() ?? ""
        minimumOSVersion = info.minimumOSVersion() ?? ""
    }

    private func saveMetadata(forceResign: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.applyCustomMetadata(
                displayName: trimmedDisplayName,
                bundleName: trimmedBundleName,
                bundleIdentifier: trimmedBundleId,
                shortVersion: trimmedShortVersion,
                buildVersion: trimmedBuildVersion,
                minimumOSVersion: trimmedMinOS,
                updateExtensionBundleIds: updateExtensionBundleIds,
                updateLocalizedNames: updateLocalizedNames,
                resignAfterSave: forceResign
            )
            loadFromAppInfo()
            alertTitle = "lc.common.success".loc
            alertMessage = forceResign
                ? "App metadata updated and bundle re-signed."
                : "App metadata updated."
            showAlert = true
        } catch {
            alertTitle = "lc.common.error".loc
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func resignOnly() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try model.validateCanModifyBundleMetadata()
            try await model.forceResign()
            model.metadataRevision &+= 1
            alertTitle = "lc.common.success".loc
            alertMessage = "App bundle and extensions re-signed successfully."
            showAlert = true
        } catch {
            alertTitle = "lc.common.error".loc
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func restoreOriginal(forceResign: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.resetMetadataToOriginal(resignAfterSave: forceResign)
            loadFromAppInfo()
            alertTitle = "lc.common.success".loc
            alertMessage = forceResign
                ? "Original metadata restored and bundle re-signed."
                : "Original metadata restored."
            showAlert = true
        } catch {
            alertTitle = "lc.common.error".loc
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

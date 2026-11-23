//
//  LCTweakImportReviewSheet.swift
//  LiveContainerSwiftUI
//
//  Interactive review & selection sheet shown when importing `.ipa` / `.tipa`
//  app archives, multi-payload `.deb` / `.zip` packages, duplicate collisions,
//  or binaries with architecture/platform/dependency compatibility warnings.
//

import SwiftUI

struct LCTweakImportReviewSheet: View {
    let session: LCTweakInspectionSession
    let destinationFolderName: String
    let onComplete: (LCTweakImportResult) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var conflictPolicy: LCTweakConflictPolicy = .overwrite
    @State private var destinationFolderURL: URL
    @State private var searchText = ""
    @State private var isInstalling = false
    @State private var progressFraction: Double = 0
    @State private var progressStatus = ""
    @State private var installError: String?

    init(
        session: LCTweakInspectionSession,
        destinationFolderURL: URL,
        destinationFolderName: String,
        onComplete: @escaping (LCTweakImportResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self._destinationFolderURL = State(initialValue: destinationFolderURL)
        self.destinationFolderName = destinationFolderName
        self.onComplete = onComplete
        self.onCancel = onCancel
        var initial = session.defaultSelectedIDs
        if initial.isEmpty {
            initial = Set(session.payloads.filter { !$0.isProtectedCollision && $0.role != .appFramework }.map(\.id))
        }
        _selectedIDs = State(initialValue: initial)
    }

    private var filteredPayloads: [LCTweakDiscoveredPayload] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return session.payloads
        }
        return session.payloads.filter { payload in
            payload.fileName.lowercased().contains(query)
                || payload.relativeSourcePath.lowercased().contains(query)
                || payload.filterBundleIdentifiers.contains { $0.lowercased().contains(query) }
        }
    }

    private func payloads(for role: LCTweakPayloadRole) -> [LCTweakDiscoveredPayload] {
        filteredPayloads.filter { $0.role == role }
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if !session.warnings.isEmpty {
                    Section("Notes & Warnings") {
                        ForEach(session.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if session.hasCollisions {
                    Section("Existing File Conflicts") {
                        Picker("When a file exists", selection: $conflictPolicy) {
                            ForEach(LCTweakConflictPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                ForEach(LCTweakPayloadRole.allCases, id: \.self) { role in
                    let items = payloads(for: role)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                payloadRow(item)
                            }
                        } header: {
                            Text("\(role.sectionTitle) (\(items.count))")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Filter payloads or bundle IDs")
            .navigationTitle("Review Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isInstalling)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        session.cleanup()
                        onCancel()
                    }
                    .disabled(isInstalling)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select Default Tweaks") {
                            selectedIDs = session.defaultSelectedIDs
                        }
                        Button("Select All Compatible") {
                            selectedIDs = Set(session.payloads.filter { !$0.isProtectedCollision }.map(\.id))
                        }
                        Button("Deselect All") {
                            selectedIDs.removeAll()
                        }
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .disabled(isInstalling)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import (\(selectedIDs.count))") {
                        Task { await performInstall() }
                    }
                    .disabled(isInstalling || selectedIDs.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if isInstalling {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView(value: progressFraction, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(width: 220)
                            Text(progressStatus.isEmpty ? "Installing tweaks…" : progressStatus)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 12)
                        .padding(24)
                    }
                }
            }
            .alert("lc.common.error".loc, isPresented: Binding(
                get: { installError != nil },
                set: { if !$0 { installError = nil } }
            )) {
                Button("lc.common.ok".loc) {
                    installError = nil
                }
            } message: {
                Text(installError ?? "")
            }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.sourceNames.joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(session.sourceFormats.map(\.displayLabel).uniquedSummary, systemImage: "shippingbox")
                    Spacer()
                    Text("→ \(destinationFolderName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if session.containsIPAHarvest {
                    Text("Detected an app bundle inside the archive. Likely injected tweaks are pre-selected while app & Swift runtime frameworks remain deselected unless you opt in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func payloadRow(_ item: LCTweakDiscoveredPayload) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            guard !item.isProtectedCollision else { return }
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.isProtectedCollision
                    ? "lock.fill"
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(item.isProtectedCollision ? AnyShapeStyle(.secondary) : (isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: item.kind.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.fileName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(item.formattedSize)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if !item.sourceArchiveChain.isEmpty {
                        Text((item.sourceArchiveChain + [item.relativeSourcePath]).joined(separator: " › "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    badgeStrip(for: item)

                    if !item.filterBundleIdentifiers.isEmpty {
                        Text("Targets: \(item.filterBundleIdentifiers.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let warnings = item.compatibility?.warnings, !warnings.isEmpty {
                        ForEach(warnings, id: \.self) { msg in
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    if item.isProtectedCollision {
                        Text("Protected LiveContainer file — skipped automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.isProtectedCollision || isInstalling)
    }

    @ViewBuilder
    private func badgeStrip(for item: LCTweakDiscoveredPayload) -> some View {
        let compat = item.compatibility
        HStack(spacing: 6) {
            if let compat {
                if !compat.architectures.isEmpty {
                    badgePill(compat.architectures.joined(separator: "/"), color: compat.hasArm64iOSSlice ? .green : .red)
                }
                if compat.isSimulatorOrMacOnly {
                    badgePill("Not iOS Device", color: .red)
                }
                if compat.needsSubstrate {
                    badgePill("Substrate / ElleKit", color: .blue)
                }
            } else if item.kind == .resourceBundle {
                badgePill("Resource Bundle", color: .indigo)
            }
            if item.existingCollisionName != nil && !item.isProtectedCollision {
                badgePill("Exists", color: .orange)
            }
        }
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    @MainActor
    private func performInstall() async {
        isInstalling = true
        progressFraction = 0.05
        progressStatus = "Preparing import…"

        do {
            let result = try await LCTweakInstallService.installSelectedPayloads(
                from: session,
                selectedIDs: selectedIDs,
                destinationFolder: destinationFolderURL,
                conflictPolicy: conflictPolicy,
                progressHandler: { prog in
                    Task { @MainActor in
                        self.progressFraction = prog.fraction
                        self.progressStatus = prog.status
                    }
                }
            )
            session.cleanup()
            isInstalling = false
            onComplete(result)
        } catch {
            isInstalling = false
            installError = error.localizedDescription
        }
    }
}

private extension Array where Element == String {
    var uniquedSummary: String {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

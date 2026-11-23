//
//  LCPackageEditorView.swift
//  LiveContainerSwiftUI
//

import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class LCPackageEditorStore {
    let session: LCPackageStagingSession

    var snapshot: LCPackageBundleSnapshot?
    var metadata: LCPackageMetadataDraft?
    var components: [LCPackageComponentItem] = []
    var queuedTweaks: [LCPackageQueuedTweak] = []

    var isLoading = true
    var isProcessing = false
    var progressValue: Double = 0
    var progressStage = ""
    var loadError: String?
    var actionError: String?
    var didHandOffSession = false

    private var didStartLoad = false

    init(session: LCPackageStagingSession) {
        self.session = session
    }

    var availableLiveContainerTweaksCount: Int {
        LCTweakDependencyResolver.discoverLiveContainerTweaks(appTweakFolder: session.appTweakFolder)
            .reduce(0) { $0 + $1.urls.count }
    }

    var activeAppTweaksCount: Int {
        guard let folder = session.appTweakFolder, !folder.isEmpty else { return 0 }
        return LCTweakDependencyResolver.discoverLiveContainerTweaks(appTweakFolder: folder)
            .filter { $0.title.contains(folder) }
            .reduce(0) { $0 + $1.urls.count }
    }

    var removedComponentsCount: Int {
        components.count(where: { !$0.isEnabled })
    }

    var hasRemainingExtensions: Bool {
        components.contains(where: { $0.kind == .appExtension && $0.isEnabled })
    }

    var willAutoEmbedElleKit: Bool {
        guard let snapshot, !snapshot.alreadyHasSubstrate else { return false }
        return queuedTweaks.contains(where: { $0.needsElleKit })
    }

    func loadIfNeeded() async {
        guard !didStartLoad else { return }
        didStartLoad = true
        isLoading = true
        loadError = nil

        do {
            let loaded = try await LCPackageStagingManager.inspectStagedBundle(
                at: session.stagedAppURL,
                mode: session.mode
            )
            self.snapshot = loaded
            self.metadata = loaded.metadata
            self.components = loaded.components
            self.isLoading = false
        } catch {
            self.loadError = error.localizedDescription
            self.isLoading = false
        }
    }

    func addTweaks(from urls: [URL], sourceLabel: String) async {
        for url in urls {
            let stdPath = url.standardizedFileURL.path
            if queuedTweaks.contains(where: { $0.sourceURL.standardizedFileURL.path == stdPath }) {
                continue
            }
            do {
                let inspected = try await LCTweakDependencyResolver.inspectTweakFile(at: url, sourceLabel: sourceLabel)
                queuedTweaks.append(inspected)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func addAppActiveTweaks() async {
        guard let folder = session.appTweakFolder, !folder.isEmpty else { return }
        let appSections = LCTweakDependencyResolver.discoverLiveContainerTweaks(appTweakFolder: folder)
            .filter { $0.title.contains(folder) }
        let urls = appSections.flatMap(\.urls)
        await addTweaks(from: urls, sourceLabel: "App Tweak")
    }

    func removeTweaks(at offsets: IndexSet) {
        queuedTweaks.remove(atOffsets: offsets)
    }

    func removeTweak(id: UUID) {
        queuedTweaks.removeAll { $0.id == id }
    }

    func removeAllExtensionsAndWatchApps() {
        for index in components.indices {
            if components[index].kind == .appExtension || components[index].kind == .watchApp {
                components[index].isEnabled = false
            }
        }
    }

    func resetAllComponents() {
        for index in components.indices {
            components[index].isEnabled = true
        }
    }

    func makeEditPlan() -> LCPackageEditPlan? {
        guard let metadata else { return nil }
        let removedIDs = Set(components.filter { !$0.isEnabled }.map(\.id))
        return LCPackageEditPlan(
            mode: session.mode,
            metadata: metadata,
            removedComponentIDs: removedIDs,
            allComponents: components,
            queuedTweaks: queuedTweaks
        )
    }

    func executePreInstall() async -> LCPackageStagingSession? {
        guard let plan = makeEditPlan(), !isProcessing else { return nil }
        isProcessing = true
        progressValue = 0.05
        progressStage = "Preparing package…"
        defer { isProcessing = false }

        do {
            try await LCPackagePatchPipeline.applyEdits(plan: plan, to: session.stagedAppURL) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.progressValue = update.fraction
                    self?.progressStage = update.stage
                }
            }
            didHandOffSession = true
            return session
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func executeStandaloneExport() async -> URL? {
        guard let plan = makeEditPlan(), !isProcessing else { return nil }
        isProcessing = true
        progressValue = 0.05
        progressStage = "Preparing standalone bundle…"
        defer { isProcessing = false }

        do {
            try await LCPackagePatchPipeline.applyEdits(plan: plan, to: session.stagedAppURL) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.progressValue = update.fraction * 0.85
                    self?.progressStage = update.stage
                }
            }

            progressValue = 0.90
            progressStage = "Packaging unsigned IPA…"

            let baseName = plan.metadata.displayName.isEmpty ? (snapshot?.executableName ?? "App") : plan.metadata.displayName
            let suffix = queuedTweaks.isEmpty ? "Standalone" : "Tweaked"
            let ipaURL = try await LCPackagePatchPipeline.packageStandaloneIPA(
                stagedAppURL: session.stagedAppURL,
                outputFileName: "\(baseName)-\(suffix).ipa"
            )
            progressValue = 1.0
            session.cleanup(deleteSourceIPA: false)
            didHandOffSession = true
            return ipaURL
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }
}

struct LCPackageEditorView: View {
    @State private var store: LCPackageEditorStore

    let onCancel: () -> Void
    let onPreInstallReady: ((LCPackageStagingSession) -> Void)?
    let onStandaloneExportReady: ((URL) -> Void)?

    @State private var showTweakFileImporter = false
    @State private var showLiveContainerTweaksPicker = false

    init(
        session: LCPackageStagingSession,
        onCancel: @escaping () -> Void,
        onPreInstallReady: ((LCPackageStagingSession) -> Void)? = nil,
        onStandaloneExportReady: ((URL) -> Void)? = nil
    ) {
        _store = State(initialValue: LCPackageEditorStore(session: session))
        self.onCancel = onCancel
        self.onPreInstallReady = onPreInstallReady
        self.onStandaloneExportReady = onStandaloneExportReady
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView("Inspecting package…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError = store.loadError {
                    ContentUnavailableView(
                        "Unable to Inspect IPA",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if let snapshot = store.snapshot, store.metadata != nil {
                    editorForm(snapshot: snapshot)
                }
            }
            .navigationTitle(store.session.mode == .standaloneExport ? "lc.packageEditor.title.export".loc : "lc.packageEditor.title.install".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        cancelAndDismiss()
                    }
                    .disabled(store.isProcessing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.session.mode.primaryActionTitle) {
                        Task { await runPrimaryAction() }
                    }
                    .fontWeight(.semibold)
                    .disabled(store.isLoading || store.loadError != nil || store.isProcessing)
                }
            }
            .interactiveDismissDisabled(store.isProcessing)
            .overlay {
                if store.isProcessing {
                    processingOverlay
                }
            }
            .alert("lc.common.error".loc, isPresented: Binding(
                get: { store.actionError != nil },
                set: { if !$0 { store.actionError = nil } }
            )) {
                Button("lc.common.ok".loc, role: .cancel) {
                    store.actionError = nil
                }
            } message: {
                Text(store.actionError ?? "")
            }
            .betterFileImporter(
                isPresented: $showTweakFileImporter,
                types: [.dylib, .deb, .lcFramework, .zipArchive],
                multiple: true,
                callback: { urls in
                    Task { await store.addTweaks(from: urls, sourceLabel: "Files") }
                },
                onDismiss: {
                    showTweakFileImporter = false
                }
            )
            .sheet(isPresented: $showLiveContainerTweaksPicker) {
                LCLiveContainerTweakPickerSheet(
                    appTweakFolder: store.session.appTweakFolder,
                    alreadySelectedURLs: Set(store.queuedTweaks.map { $0.sourceURL.standardizedFileURL.path }),
                    onSelect: { urls, sourceLabel in
                        Task { await store.addTweaks(from: urls, sourceLabel: sourceLabel) }
                    }
                )
            }
            .task {
                await store.loadIfNeeded()
            }
        }
        .onDisappear {
            if !store.didHandOffSession {
                store.session.cleanup()
            }
        }
    }

    private func editorForm(snapshot: LCPackageBundleSnapshot) -> some View {
        Form {
            Section {
                headerCard(snapshot: snapshot)
            }

            Section {
                NavigationLink {
                    LCPackageTweaksSectionView(
                        store: store,
                        onPickFromLiveContainer: { showLiveContainerTweaksPicker = true },
                        onPickFromFiles: { showTweakFileImporter = true }
                    )
                } label: {
                    LabeledContent {
                        Text(store.queuedTweaks.isEmpty ? "None" : "\(store.queuedTweaks.count)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Tweaks & Dylibs to Inject", systemImage: "syringe")
                    }
                }

                if store.session.mode == .standaloneExport && store.activeAppTweaksCount > 0 {
                    Button {
                        Task { await store.addAppActiveTweaks() }
                    } label: {
                        Label("Add App's Active Tweaks (\(store.activeAppTweaksCount))", systemImage: "wand.and.stars")
                    }
                }

                Button {
                    showLiveContainerTweaksPicker = true
                } label: {
                    Label("Add from LiveContainer Tweaks", systemImage: "folder.badge.plus")
                }

                Button {
                    showTweakFileImporter = true
                } label: {
                    Label("Import .dylib / .framework / .deb", systemImage: "doc.badge.plus")
                }

                if store.willAutoEmbedElleKit {
                    Label("ElleKit (CydiaSubstrate.framework) will be embedded automatically.", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Inject Tweaks")
            }

            Section {
                NavigationLink {
                    LCPackageComponentsView(
                        store: store,
                        stagedAppURL: snapshot.stagedAppURL,
                        hiddenSystemDylibCount: snapshot.hiddenSystemDylibCount
                    )
                } label: {
                    LabeledContent {
                        if store.removedComponentsCount > 0 {
                            Text("\(store.removedComponentsCount) removing")
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(store.components.count)")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Frameworks, Dylibs & PlugIns", systemImage: "shippingbox")
                    }
                }
            } header: {
                Text("Bundle Components")
            } footer: {
                Text("Disabling a framework or dylib removes both the binary and its Mach-O load command. Disabling PlugIns or Watch apps helps free-account sideloading.")
            }

            Section {
                NavigationLink {
                    LCPackageMetadataSectionView(metadata: Binding(
                        get: { store.metadata! },
                        set: { store.metadata = $0 }
                    ))
                } label: {
                    LabeledContent {
                        let count = store.metadata?.modifiedFieldCount ?? 0
                        Text(count > 0 ? "\(count) modified" : "Default")
                            .foregroundStyle(count > 0 ? Color.accentColor : Color.secondary)
                    } label: {
                        Label("Metadata & Bundle Options", systemImage: "slider.horizontal.3")
                    }
                }

                if let _ = store.metadata {
                    Toggle("Remove UISupportedDevices", isOn: Binding(
                        get: { store.metadata?.removeSupportedDevices ?? false },
                        set: { store.metadata?.removeSupportedDevices = $0 }
                    ))
                    Toggle("Enable Files App Sharing", isOn: Binding(
                        get: { store.metadata?.enableFileSharing ?? false },
                        set: { store.metadata?.enableFileSharing = $0 }
                    ))
                }
            } header: {
                Text("Packaging & Plist")
            } footer: {
                if store.session.mode == .standaloneExport {
                    Text("Outputs a clean, unsigned .ipa with LiveContainer patches, old signatures, and temp caches stripped — ready for AltStore, SideStore, Sideloadly, or TrollStore.")
                } else {
                    Text("Edits apply only to this installation inside LiveContainer.")
                }
            }
        }
    }

    private func headerCard(snapshot: LCPackageBundleSnapshot) -> some View {
        HStack(spacing: 14) {
            Group {
                if let data = snapshot.appIconData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.metadata?.displayName ?? snapshot.executableName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(store.session.mode.badgeTitle)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(.tint)
                }

                Text(store.metadata?.bundleIdentifier ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                let archText = snapshot.architectures.isEmpty ? "arm64" : snapshot.architectures.joined(separator: ", ")
                Text("v\(store.metadata?.shortVersion ?? "1.0") (\(store.metadata?.buildVersion ?? "1")) · \(archText) · \(snapshot.formattedBundleSize)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: store.progressValue)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(store.progressStage)
                    .font(.subheadline.weight(.medium))
                Text("\(Int((store.progressValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func cancelAndDismiss() {
        store.session.cleanup()
        store.didHandOffSession = true
        onCancel()
    }

    private func runPrimaryAction() async {
        switch store.session.mode {
        case .preInstall:
            if let readySession = await store.executePreInstall() {
                onPreInstallReady?(readySession)
            }
        case .standaloneExport:
            if let ipaURL = await store.executeStandaloneExport() {
                onStandaloneExportReady?(ipaURL)
            }
        }
    }
}

//
//  LCPackageTweaksSectionView.swift
//  LiveContainerSwiftUI
//

import SwiftUI

struct LCPackageTweaksSectionView: View {
    @Bindable var store: LCPackageEditorStore
    let onPickFromLiveContainer: () -> Void
    let onPickFromFiles: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: onPickFromLiveContainer) {
                    Label("Add from LiveContainer Tweaks", systemImage: "folder.badge.plus")
                }
                Button(action: onPickFromFiles) {
                    Label("Import .dylib / .framework / .deb / .zip", systemImage: "doc.badge.plus")
                }
                if store.session.mode == .standaloneExport && store.activeAppTweaksCount > 0 {
                    Button {
                        Task { await store.addAppActiveTweaks() }
                    } label: {
                        Label("Add App's Active Tweaks (\(store.activeAppTweaksCount))", systemImage: "wand.and.stars")
                    }
                }
            }

            if store.queuedTweaks.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Tweaks Queued",
                        systemImage: "syringe",
                        description: Text("Add .dylib, .framework, or .deb packages to inject them via @rpath into Frameworks/.")
                    )
                }
            } else {
                Section {
                    ForEach($store.queuedTweaks) { $tweak in
                        tweakRow(tweak: $tweak)
                    }
                    .onDelete { offsets in
                        store.removeTweaks(at: offsets)
                    }
                } header: {
                    Text("Queued Payloads (\(store.queuedTweaks.count))")
                } footer: {
                    Text("All tweaks are embedded safely inside Frameworks/ with @rpath install names and automatic Substrate/ElleKit remapping. Original tweak files are never modified.")
                }
            }
        }
        .navigationTitle("Tweaks to Inject")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tweakRow(tweak: Binding<LCPackageQueuedTweak>) -> some View {
        let item = tweak.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(item.kind.badgeText)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Text("\(item.sourceLabel) · \(item.payloadCount) binary · \(item.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    store.removeTweak(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }

            if !item.hasValidArm64Slice {
                Label("Missing arm64/arm64e slice — may fail on device.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if item.needsElleKit {
                Label("Requires Substrate -> will link embedded ElleKit", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if !item.unresolvedDependencies.isEmpty {
                Label("Unbundled external libs: \(item.unresolvedDependencies.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Weak Link (LC_LOAD_WEAK_DYLIB)", isOn: tweak.weakLink)
                .font(.caption)

            if store.hasRemainingExtensions {
                Toggle("Also Inject into App Extensions (.appex)", isOn: tweak.injectIntoExtensions)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LCLiveContainerTweakPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let appTweakFolder: String?
    let alreadySelectedURLs: Set<String>
    let onSelect: ([URL], String) -> Void

    @State private var sections: [LCLiveContainerTweakSection] = []
    @State private var selectedPaths: Set<String> = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var filteredSections: [LCLiveContainerTweakSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(query) {
                return section
            }
            let matchingURLs = section.urls.filter {
                LCTweakFormatDetector.strippedDisabledSuffix($0.lastPathComponent)
                    .localizedCaseInsensitiveContains(query)
            }
            guard !matchingURLs.isEmpty else { return nil }
            return LCLiveContainerTweakSection(
                folderPath: section.folderPath,
                title: section.title,
                isAppFolder: section.isAppFolder,
                urls: matchingURLs
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Scanning LiveContainer Tweaks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sections.isEmpty {
                    ContentUnavailableView(
                        "No LiveContainer Tweaks Found",
                        systemImage: "folder",
                        description: Text("Import .dylib, .framework, or .deb files in Tweaks Management or pick directly from Files.")
                    )
                } else if filteredSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(filteredSections) { section in
                            Section(section.title) {
                                ForEach(section.urls, id: \.path) { url in
                                    let stdPath = url.standardizedFileURL.path
                                    let isAlreadyQueued = alreadySelectedURLs.contains(stdPath)
                                    let isSelected = selectedPaths.contains(stdPath)
                                    let rawName = url.lastPathComponent
                                    let isDisabledInLC = rawName.lowercased().hasSuffix(".disabled")
                                    let cleanName = LCTweakFormatDetector.strippedDisabledSuffix(rawName)

                                    Button {
                                        if isAlreadyQueued { return }
                                        if isSelected {
                                            selectedPaths.remove(stdPath)
                                        } else {
                                            selectedPaths.insert(stdPath)
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: (isAlreadyQueued || isSelected) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isAlreadyQueued ? AnyShapeStyle(.secondary) : (isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)))
                                            Text(cleanName)
                                                .foregroundStyle(isAlreadyQueued ? .secondary : .primary)
                                            Spacer()
                                            if isDisabledInLC {
                                                Text("Disabled")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.14), in: Capsule())
                                                    .foregroundStyle(.orange)
                                            }
                                            if isAlreadyQueued {
                                                Text("Added")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .disabled(isAlreadyQueued)
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Filter tweaks or folders")
                }
            }
            .navigationTitle("LiveContainer Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedPaths.count))") {
                        let chosen = sections.flatMap(\.urls).filter { selectedPaths.contains($0.standardizedFileURL.path) }
                        if !chosen.isEmpty {
                            onSelect(chosen, "LiveContainer Tweaks")
                        }
                        dismiss()
                    }
                    .disabled(selectedPaths.isEmpty)
                }
            }
            .task {
                isLoading = true
                let folder = appTweakFolder
                sections = (try? await lcRunOffMain {
                    LCTweakDependencyResolver.discoverLiveContainerTweaks(appTweakFolder: folder)
                }) ?? []
                isLoading = false
            }
        }
    }
}

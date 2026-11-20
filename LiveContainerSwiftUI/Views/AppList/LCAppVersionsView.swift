//
//  LCAppVersionsView.swift
//  LiveContainerSwiftUI
//
//  Multi-source version history, release notes, mirror selection,
//  and safe downgrade UI built for Swift 6 / iOS 27.
//

import SwiftUI
import UIKit

struct LCVersionHistoryTarget: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let fallbackDisplayName: String
    let fallbackIconURL: URL?
    let targetRelativeBundlePath: String?
    let preferredSourceURL: URL?

    init(app: LCAppModel) {
        let relPath = app.appInfo.relativeBundlePath
        let bundleId = app.appInfo.bundleIdentifier() ?? app.bundleIdentifier
        self.id = relPath ?? bundleId
        self.bundleIdentifier = bundleId
        self.fallbackDisplayName = app.displayName
        self.fallbackIconURL = nil
        self.targetRelativeBundlePath = relPath
        self.preferredSourceURL = app.appInfo.sourceURL.flatMap(URL.init(string:))
    }

    init(sourceApp: AltStoreSourceApp, sourceURL: URL, installedApp: LCAppModel?) {
        self.id = "\(sourceURL.absoluteString)#\(sourceApp.bundleIdentifier)"
        self.bundleIdentifier = sourceApp.bundleIdentifier
        self.fallbackDisplayName = installedApp?.displayName ?? sourceApp.name
        self.fallbackIconURL = sourceApp.iconURL
        self.targetRelativeBundlePath = installedApp?.appInfo.relativeBundlePath
        self.preferredSourceURL = installedApp?.appInfo.sourceURL.flatMap(URL.init(string:)) ?? sourceURL
    }
}

private struct PendingDowngradeRequest: Equatable {
    let group: LCAppVersionGroup
    let offer: LCSourceVersionOffer
    let latestUpdateGroup: LCAppVersionGroup?
}

struct LCAppVersionsView: View {
    let target: LCVersionHistoryTarget
    let isPresentedAsSheet: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var downloadManager: LCDownloadManager
    @ObservedObject private var sourcesVM = AltStoreSourcesViewModel.shared

    @State private var pendingDowngrade: PendingDowngradeRequest?
    @State private var expandedNotesGroupIDs: Set<String> = []

    private var liveInstalledApp: LCAppModel? {
        let allApps = sharedModel.isHiddenAppUnlocked
            ? (sharedModel.apps + sharedModel.hiddenApps)
            : sharedModel.apps
        if let relPath = target.targetRelativeBundlePath,
           let byPath = allApps.first(where: { $0.appInfo.relativeBundlePath == relPath }) {
            return byPath
        }
        return allApps.first(where: {
            ($0.appInfo.bundleIdentifier() ?? "").caseInsensitiveCompare(target.bundleIdentifier) == .orderedSame
        })
    }

    private var displayName: String {
        liveInstalledApp?.displayName ?? target.fallbackDisplayName
    }

    private var isSecondaryLC: Bool {
        sharedModel.multiLCStatus == 2
    }

    private var versionGroups: [LCAppVersionGroup] {
        _ = sourcesVM.catalogRevision
        if let installed = liveInstalledApp {
            return sourcesVM.versionGroups(for: installed)
        }
        return sourcesVM.versionGroups(
            forBundleId: target.bundleIdentifier,
            preferredSourceURL: target.preferredSourceURL,
            installedApp: nil
        )
    }

    private var latestNewerGroup: LCAppVersionGroup? {
        versionGroups.first { $0.relation == .update }
    }

    private var currentInstalledDisplayVersion: String? {
        guard let installed = liveInstalledApp else { return nil }
        let marketing = installed.appInfo.installedSourceVersion
            ?? installed.appInfo.shortVersion()
            ?? installed.appInfo.version()
            ?? installed.version
        let build = LCVersionComparator.normalizeBuild(
            installed.appInfo.installedSourceBuildVersion ?? installed.appInfo.buildVersion()
        )
        if let build {
            return "\(marketing) (\(build))"
        }
        return marketing
    }

    private var activeAppDownload: LCDownloadTaskItem? {
        let targetId = liveInstalledApp?.appInfo.relativeBundlePath ?? target.targetRelativeBundlePath ?? target.bundleIdentifier
        return downloadManager.activeTask(forTargetId: targetId)
            ?? downloadManager.activeTask(forBundleId: target.bundleIdentifier)
    }

    var body: some View {
        Group {
            if isPresentedAsSheet {
                NavigationStack {
                    versionsContent
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("lc.common.close".loc) {
                                    dismiss()
                                }
                            }
                            refreshToolbarItem
                        }
                }
            } else {
                versionsContent
                    .toolbar {
                        refreshToolbarItem
                    }
            }
        }
        .onAppear {
            sourcesVM.loadSourcesIfNeeded()
        }
        .confirmationDialog(
            "Downgrade \(displayName)?",
            item: $pendingDowngrade,
            titleVisibility: .visible
        ) { request in
            Button("Downgrade to \(request.offer.displayVersion)", role: .destructive) {
                enqueue(offer: request.offer, ignoreUpdateKey: nil)
            }
            if let latest = request.latestUpdateGroup {
                Button("Downgrade & Ignore Updates for \(latest.version)") {
                    enqueue(offer: request.offer, ignoreUpdateKey: latest.updateKey)
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: { request in
            Text("LiveContainer preserves your Data Container and settings, but version \(request.offer.displayVersion) may not be compatible with data saved by a newer version. Export Data or use a separate container first if unsure.")
        }
    }

    @ToolbarContentBuilder
    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if sourcesVM.isRefreshingAll {
                ProgressView()
            } else {
                Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                    Task { await sourcesVM.refreshAllSources() }
                }
            }
        }
    }

    private var versionsContent: some View {
        List {
            Section {
                LCVersionHeaderCard(
                    displayName: displayName,
                    bundleIdentifier: target.bundleIdentifier,
                    installedApp: liveInstalledApp,
                    fallbackIconURL: target.fallbackIconURL ?? versionGroups.first?.primaryOffer.appIconURL,
                    installedVersionDisplay: currentInstalledDisplayVersion,
                    ignoredUpdateVersion: liveInstalledApp?.appInfo.ignoredUpdateVersion,
                    onUnignore: {
                        if let app = liveInstalledApp {
                            sourcesVM.unignoreUpdate(for: app)
                        }
                    }
                )
            }

            if isSecondaryLC {
                Section {
                    Label(
                        "Installing or switching app versions is only available in the primary LiveContainer.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if versionGroups.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Versions Found", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("No enabled AltStore sources currently list \(target.bundleIdentifier).")
                    } actions: {
                        Button("lc.sources.refreshAll".loc) {
                            Task { await sourcesVM.refreshAllSources() }
                        }
                        .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(versionGroups) { group in
                        LCVersionGroupRow(
                            group: group,
                            activeDownloadForURL: downloadManager.activeTask(forURL: group.primaryOffer.downloadURL),
                            activeDownloadForApp: activeAppDownload,
                            isInstallDisabled: isSecondaryLC,
                            isNotesExpanded: expandedNotesGroupIDs.contains(group.id),
                            onToggleNotes: {
                                if expandedNotesGroupIDs.contains(group.id) {
                                    expandedNotesGroupIDs.remove(group.id)
                                } else {
                                    expandedNotesGroupIDs.insert(group.id)
                                }
                            },
                            onSelectOffer: { offer in
                                handleSelection(group: group, offer: offer)
                            },
                            onCancelDownload: { task in
                                downloadManager.cancel(task)
                            }
                        )
                    }
                } header: {
                    Text("Available Versions (\(versionGroups.count))")
                } footer: {
                    if liveInstalledApp != nil {
                        Text("Selecting an older version downgrades the app bundle while keeping your LiveContainer data folders, tweaks, and settings intact.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Versions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleSelection(group: LCAppVersionGroup, offer: LCSourceVersionOffer) {
        guard !isSecondaryLC else { return }
        if group.relation == .downgrade, liveInstalledApp != nil {
            pendingDowngrade = PendingDowngradeRequest(
                group: group,
                offer: offer,
                latestUpdateGroup: latestNewerGroup ?? versionGroups.first(where: { $0.relation == .installed })
            )
        } else {
            enqueue(offer: offer, ignoreUpdateKey: nil)
        }
    }

    private func enqueue(offer: LCSourceVersionOffer, ignoreUpdateKey: String?) {
        sourcesVM.enqueueVersionInstall(
            offer,
            targetApp: liveInstalledApp,
            ignoreUpdateKeyAfterInstall: ignoreUpdateKey
        )
    }
}

private struct LCVersionHeaderCard: View {
    let displayName: String
    let bundleIdentifier: String
    let installedApp: LCAppModel?
    let fallbackIconURL: URL?
    let installedVersionDisplay: String?
    let ignoredUpdateVersion: String?
    let onUnignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                headerIcon
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let installedVersionDisplay {
                        Text("Installed: \(installedVersionDisplay)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let ignoredUpdateVersion, !ignoredUpdateVersion.isEmpty {
                let cleanIgnored = ignoredUpdateVersion.split(separator: "#").first.map(String.init) ?? ignoredUpdateVersion
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                        .foregroundStyle(.orange)
                    Text("Updates for \(cleanIgnored) are ignored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Unignore", action: onUnignore)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let appIcon = installedApp?.appInfo.icon() {
            Image(uiImage: appIcon)
                .resizable()
                .scaledToFill()
        } else if let fallbackIconURL {
            AsyncImage(url: fallbackIconURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image("DefaultIcon").resizable().scaledToFill()
                }
            }
        } else {
            Image("DefaultIcon")
                .resizable()
                .scaledToFill()
        }
    }
}

private struct LCVersionGroupRow: View {
    let group: LCAppVersionGroup
    let activeDownloadForURL: LCDownloadTaskItem?
    let activeDownloadForApp: LCDownloadTaskItem?
    let isInstallDisabled: Bool
    let isNotesExpanded: Bool
    let onToggleNotes: () -> Void
    let onSelectOffer: (LCSourceVersionOffer) -> Void
    let onCancelDownload: (LCDownloadTaskItem) -> Void

    private var matchingActiveTask: LCDownloadTaskItem? {
        if let direct = activeDownloadForURL {
            return direct
        }
        if let appTask = activeDownloadForApp,
           group.offers.contains(where: { $0.downloadURL == appTask.url }) {
            return appTask
        }
        return nil
    }

    private var isAnotherVersionDownloading: Bool {
        activeDownloadForApp != nil && matchingActiveTask == nil
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        if let date = group.bestReleaseDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let size = group.bestSize, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if group.offers.count == 1 {
            parts.append(group.primaryOffer.sourceName)
        } else {
            parts.append("\(group.offers.count) sources")
        }
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.displayVersion)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        LCVersionRelationBadge(
                            relation: group.relation,
                            isIgnoredUpdate: group.isIgnoredUpdate
                        )
                        if group.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange, in: .capsule)
                        }
                    }

                    if !metadataParts.isEmpty {
                        Text(metadataParts.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                actionControl
            }

            if let notes = group.bestReleaseNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isNotesExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)

                    if notes.count > 120 || notes.contains("\n") {
                        Button(isNotesExpanded ? "Show Less" : "Show More", action: onToggleNotes)
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionControl: some View {
        if let task = matchingActiveTask {
            Button {
                onCancelDownload(task)
            } label: {
                HStack(spacing: 5) {
                    ProgressView(value: min(max(task.progress, 0.05), 1))
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        } else if group.offers.count > 1 {
            Menu {
                ForEach(group.offers) { offer in
                    Button {
                        onSelectOffer(offer)
                    } label: {
                        if let size = offer.size, size > 0 {
                            Text("\(offer.sourceName) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
                        } else {
                            Text(offer.sourceName)
                        }
                    }
                }
            } label: {
                Text(actionTitle)
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(isInstallDisabled || isAnotherVersionDownloading)
        } else {
            if group.relation == .update {
                Button(actionTitle) {
                    onSelectOffer(group.primaryOffer)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isInstallDisabled || isAnotherVersionDownloading)
            } else {
                Button(actionTitle) {
                    onSelectOffer(group.primaryOffer)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isInstallDisabled || isAnotherVersionDownloading)
            }
        }
    }

    private var actionTitle: String {
        switch group.relation {
        case .update:
            return "lc.appBanner.update".loc
        case .installed:
            return "Reinstall"
        case .downgrade:
            return "Downgrade"
        case .available:
            return "lc.common.install".loc
        }
    }
}

private struct LCVersionRelationBadge: View {
    let relation: LCAppVersionRelation
    let isIgnoredUpdate: Bool

    var body: some View {
        switch relation {
        case .update:
            badge(isIgnoredUpdate ? "Ignored" : "Update", color: isIgnoredUpdate ? .gray : .blue)
        case .installed:
            badge("Installed", color: .green)
        case .downgrade:
            badge("Older", color: .orange)
        case .available:
            EmptyView()
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }
}

struct LCAppSettingsVersionRow: View {
    @ObservedObject var model: LCAppModel
    @ObservedObject private var sourcesVM = AltStoreSourcesViewModel.shared

    private var installedVersionText: String {
        let marketing = model.appInfo.installedSourceVersion
            ?? model.appInfo.shortVersion()
            ?? model.appInfo.version()
            ?? model.version
        if let build = LCVersionComparator.normalizeBuild(
            model.appInfo.installedSourceBuildVersion ?? model.appInfo.buildVersion()
        ) {
            return "\(marketing) (\(build))"
        }
        return marketing
    }

    var body: some View {
        let _ = sourcesVM.catalogRevision
        let updateCandidate = sourcesVM.updateCandidate(for: model)
        let versionCount = sourcesVM.availableVersionCount(forBundleId: model.bundleIdentifier)

        NavigationLink {
            LCAppVersionsView(
                target: LCVersionHistoryTarget(app: model),
                isPresentedAsSheet: false
            )
        } label: {
            HStack(spacing: 8) {
                Text("Versions & Updates")
                Spacer()
                if let updateCandidate {
                    Text("→ \(updateCandidate.latestVersion.version)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.blue, in: .capsule)
                } else {
                    Text(versionCount > 0 ? "\(installedVersionText) • \(versionCount)" : installedVersionText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

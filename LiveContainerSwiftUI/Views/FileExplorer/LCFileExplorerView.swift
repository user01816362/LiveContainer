//
//  LCFileExplorerView.swift
//  LiveContainerSwiftUI
//
//  Native iOS 27 Liquid Glass in-app File Explorer for navigating app bundles,
//  private/shared/external data containers, and tweaks folders without leaving
//  LiveContainer.
//

import SwiftUI
import UIKit

/// Recursive directory browser rooted at an ``LCFileExplorerRoot`` (app bundle,
/// data container, tweaks folder, or LiveContainer root).
struct LCFileExplorerView: View {
    let root: LCFileExplorerRoot
    let directoryURL: URL
    let navigationTitleText: String
    var onInspectBinary: ((URL) -> Void)? = nil

    @State private var entries: [LCFileEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchQuery = ""
    @State private var sortOrder: LCFileSortOrder = .name
    @State private var showHiddenFiles = true

    @State private var pendingDelete: LCFileEntry?
    @State private var pendingRename: LCFileEntry?
    @State private var renameText = ""
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var shareURL: URL?
    @State private var inspectedBinaryItem: LCInspectedBinaryItem?
    @State private var pathCopiedToast = false

    init(
        root: LCFileExplorerRoot,
        directoryURL: URL? = nil,
        title: String? = nil,
        onInspectBinary: ((URL) -> Void)? = nil
    ) {
        self.root = root
        self.directoryURL = directoryURL ?? root.rootURL
        self.navigationTitleText = title ?? (directoryURL?.lastPathComponent ?? root.title)
        self.onInspectBinary = onInspectBinary
    }

    private var relativePathDisplay: String {
        let rootPath = root.rootURL.standardizedFileURL.path
        let currentPath = directoryURL.standardizedFileURL.path
        if currentPath == rootPath {
            return "/"
        }
        if currentPath.hasPrefix(rootPath) {
            return String(currentPath.dropFirst(rootPath.count))
        }
        return currentPath
    }

    private var filteredEntries: [LCFileEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = entries.filter { entry in
            if !showHiddenFiles && entry.name.hasPrefix(".") {
                return false
            }
            guard !q.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(q)
        }
        return base.sorted { lhs, rhs in
            // Always keep directories before regular files for fast visual scanning
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch sortOrder {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified:
                let lDate = lhs.modifiedDate ?? .distantPast
                let rDate = rhs.modifiedDate ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .kind:
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        List {
            Section {
                LCFileExplorerPathHeader(
                    relativePath: relativePathDisplay,
                    fullPath: directoryURL.path,
                    itemCount: filteredEntries.count,
                    isReadOnly: root.isReadOnly,
                    readOnlyReason: root.readOnlyReason,
                    copied: pathCopiedToast,
                    onCopyPath: {
                        UIPasteboard.general.string = directoryURL.path
                        pathCopiedToast = true
                    }
                )
            }

            if isLoading && entries.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Reading directory…")
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            } else if let errorMessage {
                Section {
                    ContentUnavailableView(
                        "Cannot Read Directory",
                        systemImage: "folder.badge.questionmark",
                        description: Text(errorMessage)
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else if filteredEntries.isEmpty {
                Section {
                    ContentUnavailableView(
                        searchQuery.isEmpty ? "Empty Folder" : "No Matches",
                        systemImage: "folder",
                        description: Text(searchQuery.isEmpty ? "This directory contains no files." : "No items match \"\(searchQuery)\".")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredEntries) { entry in
                        row(for: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Filter files & folders")
        .refreshable {
            await reload()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(LCFileSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                    Divider()
                    if !root.isReadOnly {
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showNewFolderAlert = true
                        }
                    }
                    Button("Copy Full Path", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = directoryURL.path
                        pathCopiedToast = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                Task { await createFolder() }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        }
        .alert("Rename Item", item: $pendingRename) { item in
            TextField("New name", text: $renameText)
            Button("Rename") {
                Task { await performRename(item) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: { item in
            Text("Rename \"\(item.name)\"")
        }
        .confirmationDialog(
            "Delete Item?",
            item: $pendingDelete,
            titleVisibility: .visible
        ) { item in
            Button("Delete \"\(item.name)\"", role: .destructive) {
                Task { await performDelete(item) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: { item in
            Text("This permanently removes \"\(item.name)\" from disk.")
        }
        .sheet(item: Binding(
            get: { shareURL.map { LCShareURLWrapper(url: $0) } },
            set: { if $0 == nil { shareURL = nil } }
        )) { wrapper in
            ActivityViewController(activityItems: [wrapper.url])
        }
        .navigationDestination(item: $inspectedBinaryItem) { item in
            LCBinaryInspectorView(
                binaryURL: item.url,
                title: item.title,
                bundleRootURL: item.bundleURL,
                rootURL: root.rootURL,
                needsSecurityScope: root.needsSecurityScope
            )
        }
        .alert("Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .task(id: directoryURL) {
            await reload()
        }
        .task(id: pathCopiedToast) {
            guard pathCopiedToast else { return }
            try? await Task.sleep(for: .seconds(1.5))
            pathCopiedToast = false
        }
    }

    @ViewBuilder
    private func row(for entry: LCFileEntry) -> some View {
        Group {
            if entry.isDirectory {
                NavigationLink {
                    LCFileExplorerView(
                        root: root,
                        directoryURL: entry.url,
                        title: entry.name,
                        onInspectBinary: onInspectBinary
                    )
                } label: {
                    LCFileEntryRowLabel(entry: entry)
                }
            } else {
                NavigationLink {
                    LCFilePreviewView(
                        entry: entry,
                        rootURL: root.rootURL,
                        needsSecurityScope: root.needsSecurityScope,
                        isReadOnly: root.isReadOnly,
                        onInspectBinary: onInspectBinary
                    )
                } label: {
                    LCFileEntryRowLabel(entry: entry)
                }
            }
        }
        .contextMenu {
            if let machOURL = entry.machOExecutableURL {
                Button("Inspect & Dump Binary", systemImage: "cpu.fill") {
                    if let onInspectBinary {
                        onInspectBinary(machOURL)
                    } else {
                        inspectedBinaryItem = LCInspectedBinaryItem(
                            url: machOURL,
                            title: entry.name,
                            bundleURL: entry.isDirectory ? entry.url : nil
                        )
                    }
                }
            }
            Button("Copy Path", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.url.path
                pathCopiedToast = true
            }
            if !entry.isDirectory && entry.kind != .special {
                Button("Share / Export", systemImage: "square.and.arrow.up") {
                    Task { await prepareShare(for: entry.url) }
                }
            }
            if !root.isReadOnly {
                Divider()
                Button("lc.common.rename".loc, systemImage: "pencil") {
                    renameText = entry.name
                    pendingRename = entry
                }
                Button("lc.common.delete".loc, systemImage: "trash", role: .destructive) {
                    pendingDelete = entry
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        let targetDir = directoryURL
        let rootURL = root.rootURL
        let scope = root.needsSecurityScope
        do {
            let loaded = try await lcRunOffMain {
                try LCFileExplorerService.listDirectory(
                    at: targetDir,
                    rootURL: rootURL,
                    needsSecurityScope: scope
                )
            }
            if !Task.isCancelled {
                entries = loaded
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func createFolder() async {
        let name = newFolderName
        let dir = directoryURL
        let rootURL = root.rootURL
        let scope = root.needsSecurityScope
        do {
            try await lcRunOffMain {
                try LCFileExplorerService.createFolder(named: name, in: dir, rootURL: rootURL, needsSecurityScope: scope)
            }
            await reload()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func performRename(_ item: LCFileEntry) async {
        let targetName = renameText
        let itemURL = item.url
        let rootURL = root.rootURL
        let scope = root.needsSecurityScope
        do {
            try await lcRunOffMain {
                try LCFileExplorerService.renameItem(at: itemURL, to: targetName, rootURL: rootURL, needsSecurityScope: scope)
            }
            await reload()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func prepareShare(for url: URL) async {
        let rootURL = root.rootURL
        let scope = root.needsSecurityScope
        do {
            let shareableURL = try await lcRunOffMain {
                try LCFileExplorerService.stageFileForSharing(at: url, rootURL: rootURL, needsSecurityScope: scope)
            }
            shareURL = shareableURL
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func performDelete(_ item: LCFileEntry) async {
        let itemURL = item.url
        let rootURL = root.rootURL
        let scope = root.needsSecurityScope
        do {
            try await lcRunOffMain {
                try LCFileExplorerService.deleteItem(at: itemURL, rootURL: rootURL, needsSecurityScope: scope)
            }
            await reload()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

private struct LCShareURLWrapper: Identifiable {
    var id: String { url.path }
    let url: URL
}

private struct LCInspectedBinaryItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let bundleURL: URL?
}

private struct LCFileExplorerPathHeader: View {
    let relativePath: String
    let fullPath: String
    let itemCount: Int
    let isReadOnly: Bool
    let readOnlyReason: String?
    let copied: Bool
    let onCopyPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(relativePath)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                Button(action: onCopyPath) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isReadOnly {
                    Text(readOnlyReason ?? "Read-Only")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.14), in: .capsule)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LCFileEntryRowLabel: View {
    let entry: LCFileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.systemImage)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let badge = entry.kind.badgeTitle {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(iconColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(iconColor.opacity(0.15), in: .capsule)
                    }
                }

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory: return .blue
        case .bundle: return .indigo
        case .machOBinary: return .orange
        case .plist: return .teal
        case .json: return .mint
        case .sqlite: return .purple
        case .image: return .pink
        case .symlink: return .cyan
        case .special: return .red
        default: return .secondary
        }
    }

    private var subtitleText: String? {
        if let dest = entry.symlinkDestination {
            return "→ \(dest)"
        }
        var parts: [String] = []
        if !entry.isDirectory {
            parts.append(entry.formattedSize)
        }
        if let date = entry.modifiedDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

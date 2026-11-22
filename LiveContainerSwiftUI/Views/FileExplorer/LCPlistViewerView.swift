//
//  LCPlistViewerView.swift
//  LiveContainerSwiftUI
//
//  Searchable, collapsible Property List (.plist / .strings / .entitlements)
//  inspector supporting both binary and XML plists with raw XML copy/export.
//

import SwiftUI
import UIKit

/// Displays a decoded Property List as either an interactive collapsible tree
/// or formatted XML source text.
struct LCPlistViewerView: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    var isReadOnly: Bool = true

    @State private var document: LCPlistDocument?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showRawXML = false
    @State private var searchQuery = ""
    @State private var copiedToast = false
    @State private var showEditorSheet = false

    private var filteredNodes: [LCPlistNode] {
        guard let document else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return document.nodes }
        return Self.filterNodes(document.nodes, query: q)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading property list…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Open Plist",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if let document {
                if showRawXML {
                    ScrollView {
                        Text(document.rawText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                } else {
                    List {
                        Section {
                            LabeledContent("Format", value: document.formatLabel)
                            LabeledContent("Top-Level Keys", value: "\(document.nodes.count)")
                        }
                        Section {
                            if filteredNodes.isEmpty {
                                Text("No matching keys or values.")
                                    .foregroundStyle(.secondary)
                            } else {
                                OutlineGroup(filteredNodes, children: \.children) { node in
                                    LCPlistNodeRow(node: node)
                                }
                            }
                        } header: {
                            Text("Entries")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search keys or values")
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let document {
                    if canEditCurrentFile(document) {
                        Button("Edit") {
                            showEditorSheet = true
                        }
                    }
                    Button(showRawXML ? "Tree" : "XML") {
                        showRawXML.toggle()
                    }
                    Button {
                        UIPasteboard.general.string = document.rawText
                        copiedToast = true
                    } label: {
                        Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .sheet(isPresented: $showEditorSheet) {
            if let document {
                LCPlistRawEditorSheet(
                    fileURL: fileURL,
                    rootURL: rootURL,
                    needsSecurityScope: needsSecurityScope,
                    initialText: editorInitialXML(fallback: document.rawText),
                    writeFormatRaw: document.writeFormatRaw,
                    matchingApp: matchingInstalledApp()
                ) {
                    Task { await loadDocument() }
                }
            }
        }
        .task(id: fileURL) {
            await loadDocument()
        }
        .task(id: copiedToast) {
            guard copiedToast else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedToast = false
        }
    }

    private func canEditCurrentFile(_ document: LCPlistDocument) -> Bool {
        guard !isReadOnly, document.canEdit else {
            return false
        }
        if matchingInstalledApp() != nil && fileURL.lastPathComponent == "LCAppInfo.plist" {
            return false
        }
        return true
    }

    @MainActor
    private func matchingInstalledApp() -> LCAppModel? {
        let name = fileURL.lastPathComponent
        guard name == "Info.plist" || name == "LCAppInfo.plist" else {
            return nil
        }
        let targetBundlePath = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        for app in allApps {
            guard let bundlePath = app.appInfo.bundlePath() else { continue }
            let standardizedAppBundle = URL(fileURLWithPath: bundlePath, isDirectory: true).standardizedFileURL.path
            if standardizedAppBundle == targetBundlePath {
                return app
            }
        }
        return nil
    }

    @MainActor
    private func editorInitialXML(fallback: String) -> String {
        guard fileURL.lastPathComponent == "Info.plist",
              let app = matchingInstalledApp() else {
            return fallback
        }
        let dict = app.appInfo.editableInfoPlistDictionary()
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
           let xml = String(data: data, encoding: .utf8) {
            return xml
        }
        return fallback
    }

    private func loadDocument() async {
        isLoading = true
        errorMessage = nil
        let targetURL = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        do {
            let loaded = try await lcRunOffMain {
                try LCFileExplorerService.loadPlistDocument(
                    at: targetURL,
                    rootURL: root,
                    needsSecurityScope: scope
                )
            }
            if !Task.isCancelled {
                document = loaded
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private static func filterNodes(_ nodes: [LCPlistNode], query: String) -> [LCPlistNode] {
        var result: [LCPlistNode] = []
        for node in nodes {
            let selfMatches = node.key.localizedCaseInsensitiveContains(query)
                || node.valueSummary.localizedCaseInsensitiveContains(query)
            if let children = node.children {
                let matchingChildren = filterNodes(children, query: query)
                if selfMatches || !matchingChildren.isEmpty {
                    result.append(LCPlistNode(
                        id: node.id,
                        key: node.key,
                        typeLabel: node.typeLabel,
                        valueSummary: node.valueSummary,
                        children: matchingChildren.isEmpty ? (selfMatches ? children : nil) : matchingChildren
                    ))
                }
            } else if selfMatches {
                result.append(node)
            }
        }
        return result
    }
}

private struct LCPlistNodeRow: View {
    let node: LCPlistNode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(node.key)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(node.typeLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.14), in: .capsule)
            }
            Text(node.valueSummary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct LCPlistRawEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    let writeFormatRaw: UInt
    let matchingApp: LCAppModel?
    let onSaved: () -> Void

    @State private var text: String
    @State private var validationError: String?
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        fileURL: URL,
        rootURL: URL,
        needsSecurityScope: Bool,
        initialText: String,
        writeFormatRaw: UInt,
        matchingApp: LCAppModel?,
        onSaved: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.rootURL = rootURL
        self.needsSecurityScope = needsSecurityScope
        self.writeFormatRaw = writeFormatRaw
        self.matchingApp = matchingApp
        self.onSaved = onSaved
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: validationError == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(validationError == nil ? Color.green : Color.red)
                    Text(validationError ?? "Valid Property List XML")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(validationError == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Divider()

                TextEditor(text: Binding(
                    get: { text },
                    set: { newValue in
                        text = newValue
                        validate(newValue)
                    }
                ))
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
            }
            .navigationTitle("Edit \(fileURL.lastPathComponent)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(validationError != nil || isSaving)
                }
            }
            .alert("Save Failed", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("lc.common.ok".loc, role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func validate(_ content: String) {
        guard let data = content.data(using: .utf8) else {
            validationError = "Text must be valid UTF-8."
            return
        }
        do {
            let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            if matchingApp != nil {
                guard let dict = parsed as? [String: Any] else {
                    validationError = "App Info.plist must have a <dict> at the root."
                    return
                }
                guard let exec = dict["CFBundleExecutable"] as? String, !exec.isEmpty else {
                    validationError = "App Info.plist requires a non-empty CFBundleExecutable string."
                    return
                }
                guard let bundleId = dict["CFBundleIdentifier"] as? String,
                      !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    validationError = "App Info.plist requires a non-empty CFBundleIdentifier string."
                    return
                }
            }
            validationError = nil
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let matchingApp {
                guard let data = text.data(using: .utf8),
                      let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw LCFileExplorerError.invalidPlist("App Info.plist must be a valid dictionary.")
                }
                try await matchingApp.replaceInfoPlist(dict, resignAfterSave: false)
            } else {
                let content = text
                let targetURL = fileURL
                let root = rootURL
                let scope = needsSecurityScope
                let formatRaw = writeFormatRaw
                try await lcRunOffMain {
                    try LCFileExplorerService.savePlistXML(
                        content,
                        to: targetURL,
                        rootURL: root,
                        needsSecurityScope: scope,
                        writeFormatRaw: formatRaw
                    )
                }
            }
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

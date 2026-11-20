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

    @State private var document: LCPlistDocument?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showRawXML = false
    @State private var searchQuery = ""
    @State private var copiedToast = false

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
                    .searchable(text: $searchQuery, prompt: "Search keys or values")
                }
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if document != nil {
                    Button(showRawXML ? "Tree" : "XML") {
                        showRawXML.toggle()
                    }
                    Button {
                        if let raw = document?.rawText {
                            UIPasteboard.general.string = raw
                            copiedToast = true
                        }
                    } label: {
                        Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                    }
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

    private func loadDocument() async {
        isLoading = true
        errorMessage = nil
        let targetURL = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try LCFileExplorerService.loadPlistDocument(
                    at: targetURL,
                    rootURL: root,
                    needsSecurityScope: scope
                )
            }.value
            if !Task.isCancelled {
                document = loaded
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
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

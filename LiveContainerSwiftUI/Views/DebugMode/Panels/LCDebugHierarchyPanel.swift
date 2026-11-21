//
//  LCDebugHierarchyPanel.swift
//  LiveContainerSwiftUI
//
//  Interactive collapsible View Hierarchy Tree explorer for Debug Studio.
//

import SwiftUI

struct LCDebugHierarchyPanel: View {
    let inspectorStore: LCDebugInspectorStore
    let manager: LCDebugStudioManager
    let onCopyWithFeedback: (String, String) -> Void

    @State private var searchText = ""
    @State private var selectedWindowIndex = 0
    @State private var collapsedIDs: Set<String> = []
    @State private var inspectedNode: LCDebugHierarchyNode? = nil
    @State private var showRawJSON = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter UIView / VC / accessID…", text: $searchText)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))

                if inspectorStore.hierarchyWindows.count > 1 {
                    Menu {
                        ForEach(Array(inspectorStore.hierarchyWindows.enumerated()), id: \.element.id) { idx, win in
                            Button {
                                selectedWindowIndex = idx
                            } label: {
                                Text("\(win.windowClass)\(win.isKeyWindow ? " (Key)" : "")")
                            }
                        }
                    } label: {
                        Text("Win \(selectedWindowIndex + 1)/\(inspectorStore.hierarchyWindows.count)")
                            .font(.caption2.bold())
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }

                Button {
                    Task { await manager.loadHierarchy() }
                } label: {
                    if inspectorStore.isLoadingHierarchy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)

                Menu {
                    Button("View Raw JSON", systemImage: "curlybraces") {
                        showRawJSON = true
                    }
                    Button("Copy Hierarchy JSON", systemImage: "doc.on.doc") {
                        onCopyWithFeedback(inspectorStore.hierarchyText, "Copied View Hierarchy JSON")
                    }
                    Button("Expand All") { collapsedIDs.removeAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            if inspectorStore.hierarchyWindows.isEmpty {
                ScrollView {
                    Text(inspectorStore.hierarchyText.isEmpty ? "Tap refresh to snapshot the live view hierarchy." : inspectorStore.hierarchyText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            } else {
                let safeIdx = min(selectedWindowIndex, inspectorStore.hierarchyWindows.count - 1)
                let win = inspectorStore.hierarchyWindows[safeIdx]
                let flattened = flattenedNodes(from: win.rootNode)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(win.windowClass)
                                .font(.caption2.bold().monospaced())
                                .foregroundStyle(.cyan)
                            if win.isKeyWindow {
                                Text("KEY")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.18), in: .capsule)
                                    .foregroundStyle(.green)
                            }
                            if !win.rootViewController.isEmpty {
                                Text("root: \(win.rootViewController)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.bottom, 2)

                        ForEach(flattened) { row in
                            LCDebugHierarchyTreeRowView(
                                row: row,
                                isCollapsed: collapsedIDs.contains(row.node.id),
                                onToggleExpand: {
                                    if collapsedIDs.contains(row.node.id) {
                                        collapsedIDs.remove(row.node.id)
                                    } else {
                                        collapsedIDs.insert(row.node.id)
                                    }
                                },
                                onSelectNode: {
                                    inspectedNode = row.node
                                }
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $inspectedNode) { node in
            LCDebugHierarchyNodeDetailSheet(node: node) { text, msg in
                onCopyWithFeedback(text, msg)
            }
        }
        .sheet(isPresented: $showRawJSON) {
            NavigationStack {
                ScrollView {
                    Text(inspectorStore.hierarchyText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("Hierarchy JSON")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy") {
                            onCopyWithFeedback(inspectorStore.hierarchyText, "Copied Hierarchy JSON")
                        }
                    }
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("lc.common.done".loc) { showRawJSON = false }
                    }
                }
            }
        }
    }

    private func flattenedNodes(from root: LCDebugHierarchyNode?) -> [LCDebugFlatTreeRow] {
        guard let root else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [LCDebugFlatTreeRow] = []
        func walk(_ node: LCDebugHierarchyNode, depth: Int) {
            if q.isEmpty {
                out.append(LCDebugFlatTreeRow(node: node, depth: depth))
                if !collapsedIDs.contains(node.id) {
                    for child in node.children {
                        walk(child, depth: depth + 1)
                    }
                }
            } else {
                let matchesSelf = node.className.localizedCaseInsensitiveContains(q)
                    || (node.viewController?.localizedCaseInsensitiveContains(q) ?? false)
                    || (node.accessibilityId?.localizedCaseInsensitiveContains(q) ?? false)
                if matchesSelf {
                    out.append(LCDebugFlatTreeRow(node: node, depth: depth))
                }
                for child in node.children {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return out
    }
}

private struct LCDebugFlatTreeRow: Identifiable {
    var id: String { node.id }
    let node: LCDebugHierarchyNode
    let depth: Int
}

private struct LCDebugHierarchyTreeRowView: View {
    let row: LCDebugFlatTreeRow
    let isCollapsed: Bool
    let onToggleExpand: () -> Void
    let onSelectNode: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Color.clear
                .frame(width: CGFloat(min(row.depth, 10) * 10), height: 1)

            if !row.node.children.isEmpty {
                Button(action: onToggleExpand) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 1)
            }

            Button(action: onSelectNode) {
                HStack(spacing: 5) {
                    Text(row.node.className)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(row.node.isDimmed ? .secondary : .white)
                        .lineLimit(1)
                    if let vc = row.node.viewController, !vc.isEmpty {
                        Text(vc)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.14), in: .capsule)
                            .lineLimit(1)
                    }
                    if let accId = row.node.accessibilityId, !accId.isEmpty {
                        Text("#\(accId)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.mint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(row.node.frame)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
        .opacity(row.node.isDimmed ? 0.58 : 1.0)
        .padding(.vertical, 2)
    }
}

private struct LCDebugHierarchyNodeDetailSheet: View {
    let node: LCDebugHierarchyNode
    let onCopy: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Class", value: node.className)
                LabeledContent("Frame", value: node.frame)
                LabeledContent("Alpha", value: String(format: "%.2f", node.alpha))
                LabeledContent("Hidden", value: node.isHidden ? "Yes" : "No")
                if let vc = node.viewController, !vc.isEmpty {
                    LabeledContent("Owning VC", value: vc)
                }
                if let acc = node.accessibilityId, !acc.isEmpty {
                    LabeledContent("Accessibility ID", value: acc)
                }
                LabeledContent("Direct Subviews", value: "\(node.children.count)")
            }
            .navigationTitle(node.className)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy Class") {
                        onCopy(node.className, "Copied \(node.className)")
                    }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

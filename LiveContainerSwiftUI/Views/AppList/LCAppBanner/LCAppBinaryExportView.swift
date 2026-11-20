//
//  LCAppBinaryExportView.swift
//  LiveContainerSwiftUI
//

import SwiftUI

struct LCAppBinaryExportView: View {
    let items: [AppBinaryExportItem]
    let onCancel: () -> Void
    let onExport: ([AppBinaryExportItem]) -> Void
    let onCopyToTweaks: ([AppBinaryExportItem]) -> Void

    @State private var selectedItemIDs: Set<String>
    @State private var inspectingItem: AppBinaryExportItem?

    init(
        items: [AppBinaryExportItem],
        onCancel: @escaping () -> Void,
        onExport: @escaping ([AppBinaryExportItem]) -> Void,
        onCopyToTweaks: @escaping ([AppBinaryExportItem]) -> Void
    ) {
        self.items = items
        self.onCancel = onCancel
        self.onExport = onExport
        self.onCopyToTweaks = onCopyToTweaks
        _selectedItemIDs = State(initialValue: Set(items.map(\.id)))
    }

    private var selectedItems: [AppBinaryExportItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("No .dylib or .framework was found in this app bundle.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Button {
                                if selectedItemIDs.contains(item.id) {
                                    selectedItemIDs.remove(item.id)
                                } else {
                                    selectedItemIDs.insert(item.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.relativePath)
                                            .font(.system(.body, design: .monospaced))
                                        Text(item.kind.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                inspectingItem = item
                            } label: {
                                Image(systemName: "cpu")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Inspect \(item.relativePath)")
                        }
                    }
                }
            }
            .navigationTitle("Export Dylibs & Frameworks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !items.isEmpty {
                        Button(selectedItemIDs.count == items.count ? "Unselect All" : "Select All") {
                            if selectedItemIDs.count == items.count {
                                selectedItemIDs.removeAll()
                            } else {
                                selectedItemIDs = Set(items.map(\.id))
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(selectedItems)
                    }
                    .disabled(selectedItems.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Copy to Tweaks") {
                        onCopyToTweaks(selectedItems)
                    }
                    .disabled(selectedItems.isEmpty)
                }
            }
            .sheet(item: $inspectingItem) { item in
                NavigationStack {
                    LCAppBinaryExportInspectorSheet(item: item) {
                        inspectingItem = nil
                    }
                }
            }
        }
    }
}

private struct LCAppBinaryExportInspectorSheet: View {
    let item: AppBinaryExportItem
    let onClose: () -> Void

    var body: some View {
        Group {
            if item.kind == .framework {
                LCBinaryInspectorView(bundleURL: item.url, title: item.url.lastPathComponent)
            } else {
                LCBinaryInspectorView(binaryURL: item.url, title: item.url.lastPathComponent)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", action: onClose)
            }
        }
    }
}

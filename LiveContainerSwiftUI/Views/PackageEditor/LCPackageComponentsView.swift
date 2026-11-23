//
//  LCPackageComponentsView.swift
//  LiveContainerSwiftUI
//

import SwiftUI

struct LCPackageComponentsView: View {
    @Bindable var store: LCPackageEditorStore
    let stagedAppURL: URL
    let hiddenSystemDylibCount: Int

    @State private var searchText = ""
    @State private var inspectedItem: LCPackageComponentItem?

    private var hasAnyVisibleComponent: Bool {
        LCPackageComponentKind.allCases.contains { !matchingIndices(for: $0).isEmpty }
    }

    var body: some View {
        Group {
            if store.components.isEmpty {
                List {
                    Section {
                        ContentUnavailableView(
                            "No Frameworks or Extensions Found",
                            systemImage: "shippingbox",
                            description: Text("This bundle does not embed custom Frameworks, Dylibs, PlugIns, or Watch apps.")
                        )
                        .listRowBackground(Color.clear)
                    }
                    if hiddenSystemDylibCount > 0 {
                        Section {
                            Text("\(hiddenSystemDylibCount) required system libraries (/System/Library, /usr/lib) not shown.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !hasAnyVisibleComponent && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(LCPackageComponentKind.allCases, id: \.self) { kind in
                        let indices = matchingIndices(for: kind)
                        if !indices.isEmpty {
                            Section {
                                ForEach(indices, id: \.self) { idx in
                                    componentRow(item: $store.components[idx])
                                }
                            } header: {
                                Text("\(kind.sectionTitle) (\(indices.count))")
                            } footer: {
                                if kind == .linkedDylib && hiddenSystemDylibCount > 0 {
                                    Text("\(hiddenSystemDylibCount) required system libraries (/System/Library, /usr/lib) not shown.")
                                }
                            }
                        }
                    }

                    if hiddenSystemDylibCount > 0 && matchingIndices(for: .linkedDylib).isEmpty {
                        Section {
                            Text("\(hiddenSystemDylibCount) required system libraries (/System/Library, /usr/lib) not shown.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter frameworks, dylibs, plugins")
        .navigationTitle("Bundle Components")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $inspectedItem) { item in
            if let binaryURL = item.binaryURL {
                LCBinaryInspectorView(
                    binaryURL: binaryURL,
                    title: item.name,
                    bundleRootURL: stagedAppURL,
                    rootURL: stagedAppURL,
                    needsSecurityScope: false
                )
            } else {
                ContentUnavailableView(
                    "No Mach-O Binary",
                    systemImage: "doc.questionmark",
                    description: Text("\(item.name) does not have a local Mach-O binary inside the staged bundle.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Remove All PlugIns & Watch Apps", systemImage: "puzzlepiece.extension") {
                        store.removeAllExtensionsAndWatchApps()
                    }
                    Button("Keep All", systemImage: "arrow.uturn.backward") {
                        store.resetAllComponents()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func matchingIndices(for kind: LCPackageComponentKind) -> [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.components.indices.filter { idx in
            let item = store.components[idx]
            guard item.kind == kind else { return false }
            if query.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(query) ||
                item.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private func componentRow(item: Binding<LCPackageComponentItem>) -> some View {
        let val = item.wrappedValue
        return HStack(spacing: 10) {
            Toggle(isOn: item.isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(val.name)
                            .font(.subheadline.weight(.medium))
                            .strikethrough(!val.isEnabled)
                            .foregroundStyle(val.isEnabled ? .primary : .secondary)

                        if val.loadCommandPath != nil {
                            Text(val.isWeakLinked ? "Weak" : "Linked")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        } else if val.kind == .framework || val.kind == .linkedDylib {
                            Text("Unlinked")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }

                        if !val.formattedSize.isEmpty {
                            Text(val.formattedSize)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(val.subtitle)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !val.isEnabled && !val.dependentNames.isEmpty {
                        Text("Warning: linked by \(val.dependentNames.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if val.binaryURL != nil {
                Button {
                    inspectedItem = val
                } label: {
                    Image(systemName: "stethoscope")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Inspect \(val.name)")
            }
        }
    }
}

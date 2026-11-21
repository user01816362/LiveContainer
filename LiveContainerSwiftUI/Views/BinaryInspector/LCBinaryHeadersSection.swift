//
//  LCBinaryHeadersSection.swift
//  LiveContainerSwiftUI
//
//  Headers tab for LiveContainer's Binary Inspector: Objective-C Classes,
//  Protocols, Categories, Class Hierarchy tree, Swift nominal types/fields,
//  and syntax-clean `.h` header detail viewer with single-file export.
//

import SwiftUI
import UIKit

private enum LCBinaryHeadersSubtab: String, CaseIterable, Identifiable {
    case classes = "Classes"
    case protocols = "Protocols"
    case categories = "Categories"
    case swift = "Swift"
    case hierarchy = "Hierarchy"

    var id: String { rawValue }
}

/// Renders the Objective-C & Swift Headers tab with live search and detail drill-down.
struct LCBinaryHeadersSection: View {
    let binaryName: String
    let isEncrypted: Bool
    let objcDump: LCObjCDumpResult?
    let swiftMetadata: LCSwiftMetadataResult?
    let isLoading: Bool
    let errorMessage: String?
    let onReload: () -> Void
    let onShareHeaderFile: (URL) -> Void

    @State private var subtab: LCBinaryHeadersSubtab = .classes
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if isEncrypted {
                ContentUnavailableView(
                    "Encrypted Binary",
                    systemImage: "lock.shield.fill",
                    description: Text(LCMachOInspectorError.encryptedBinaryCannotDump.localizedDescription)
                )
            } else if isLoading && objcDump == nil && swiftMetadata == nil {
                ProgressView("Decoding ObjC & Swift runtime metadata…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Header Dump Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", action: onReload)
                        .buttonStyle(.glassProminent)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LCBinaryHeadersSubtab.allCases) { tab in
                            Button {
                                subtab = tab
                            } label: {
                                Text(badgeTitle(for: tab))
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.glass)
                            .tint(subtab == tab ? .accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }

                switch subtab {
                case .classes:
                    LCObjCClassesListView(
                        classes: filteredClasses,
                        allClasses: objcDump?.classes ?? [],
                        allProtocols: objcDump?.protocols ?? [],
                        onShareHeaderFile: onShareHeaderFile
                    )
                case .protocols:
                    LCObjCProtocolsListView(
                        protocols: filteredProtocols,
                        allClasses: objcDump?.classes ?? [],
                        allProtocols: objcDump?.protocols ?? [],
                        onShareHeaderFile: onShareHeaderFile
                    )
                case .categories:
                    LCObjCCategoriesListView(
                        categories: filteredCategories,
                        allClasses: objcDump?.classes ?? [],
                        allProtocols: objcDump?.protocols ?? [],
                        onShareHeaderFile: onShareHeaderFile
                    )
                case .swift:
                    LCSwiftTypesListView(types: filteredSwiftTypes)
                case .hierarchy:
                    LCObjCHierarchyListView(
                        classes: objcDump?.classes ?? [],
                        allProtocols: objcDump?.protocols ?? [],
                        searchQuery: searchQuery,
                        onShareHeaderFile: onShareHeaderFile
                    )
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search classes, methods, Swift types")
    }

    private func badgeTitle(for tab: LCBinaryHeadersSubtab) -> String {
        switch tab {
        case .classes: return "Classes (\(objcDump?.classes.count ?? 0))"
        case .protocols: return "Protocols (\(objcDump?.protocols.count ?? 0))"
        case .categories: return "Categories (\(objcDump?.categories.count ?? 0))"
        case .swift: return "Swift (\(swiftMetadata?.types.count ?? 0))"
        case .hierarchy: return "Hierarchy"
        }
    }

    private var filteredClasses: [LCObjCClassInfo] {
        let items = objcDump?.classes ?? []
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { cls in
            cls.name.localizedCaseInsensitiveContains(q)
                || (cls.superclassName?.localizedCaseInsensitiveContains(q) ?? false)
                || cls.instanceMethods.contains { $0.name.localizedCaseInsensitiveContains(q) }
                || cls.classMethods.contains { $0.name.localizedCaseInsensitiveContains(q) }
                || cls.properties.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filteredProtocols: [LCObjCProtocolInfo] {
        let items = objcDump?.protocols ?? []
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { proto in
            proto.name.localizedCaseInsensitiveContains(q)
                || proto.requiredInstanceMethods.contains { $0.name.localizedCaseInsensitiveContains(q) }
                || proto.optionalInstanceMethods.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filteredCategories: [LCObjCCategoryInfo] {
        let items = objcDump?.categories ?? []
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { cat in
            cat.name.localizedCaseInsensitiveContains(q)
                || cat.className.localizedCaseInsensitiveContains(q)
                || cat.instanceMethods.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filteredSwiftTypes: [LCSwiftTypeInfo] {
        let items = swiftMetadata?.types ?? []
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { type in
            type.name.localizedCaseInsensitiveContains(q)
                || type.fields.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }
}

// MARK: - Nominal Subviews for ObjC & Swift Lists

private struct LCObjCClassesListView: View {
    let classes: [LCObjCClassInfo]
    let allClasses: [LCObjCClassInfo]
    let allProtocols: [LCObjCProtocolInfo]
    let onShareHeaderFile: (URL) -> Void

    var body: some View {
        if classes.isEmpty {
            ContentUnavailableView(
                "No Objective-C Classes",
                systemImage: "doc.text",
                description: Text("No Objective-C classes matched in this slice.")
            )
        } else {
            List(classes) { cls in
                NavigationLink {
                    LCObjCHeaderDetailView(
                        title: "\(cls.name).h",
                        target: .objcClass(cls),
                        superclassName: cls.superclassName,
                        protocols: cls.protocols,
                        memberSummary: "\(cls.properties.count) props · \(cls.instanceMethods.count + cls.classMethods.count) methods · \(cls.ivars.count) ivars",
                        allClasses: allClasses,
                        allProtocols: allProtocols,
                        onShareHeaderFile: onShareHeaderFile
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(cls.name)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                            if cls.isSwiftClass {
                                Text("Swift")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.pink)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.pink.opacity(0.14), in: .capsule)
                            }
                        }
                        HStack(spacing: 8) {
                            if let sup = cls.superclassName {
                                Text(": \(sup)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text("\(cls.instanceMethods.count + cls.classMethods.count)m · \(cls.properties.count)p")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct LCObjCProtocolsListView: View {
    let protocols: [LCObjCProtocolInfo]
    let allClasses: [LCObjCClassInfo]
    let allProtocols: [LCObjCProtocolInfo]
    let onShareHeaderFile: (URL) -> Void

    var body: some View {
        if protocols.isEmpty {
            ContentUnavailableView("No Protocols", systemImage: "doc.text", description: Text("No Objective-C protocols found."))
        } else {
            List(protocols) { proto in
                NavigationLink {
                    let count = proto.requiredInstanceMethods.count + proto.requiredClassMethods.count
                        + proto.optionalInstanceMethods.count + proto.optionalClassMethods.count
                    LCObjCHeaderDetailView(
                        title: "\(proto.name)-Protocol.h",
                        target: .objcProtocol(proto),
                        superclassName: nil,
                        protocols: proto.adoptedProtocols,
                        memberSummary: "\(proto.properties.count) props · \(count) methods",
                        allClasses: allClasses,
                        allProtocols: allProtocols,
                        onShareHeaderFile: onShareHeaderFile
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(proto.name)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text("\(proto.requiredInstanceMethods.count + proto.optionalInstanceMethods.count) methods · \(proto.properties.count) props")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct LCObjCCategoriesListView: View {
    let categories: [LCObjCCategoryInfo]
    let allClasses: [LCObjCClassInfo]
    let allProtocols: [LCObjCProtocolInfo]
    let onShareHeaderFile: (URL) -> Void

    var body: some View {
        if categories.isEmpty {
            ContentUnavailableView("No Categories", systemImage: "doc.text", description: Text("No Objective-C categories found."))
        } else {
            List(categories) { cat in
                NavigationLink {
                    LCObjCHeaderDetailView(
                        title: "\(cat.className)+\(cat.name).h",
                        target: .objcCategory(cat),
                        superclassName: nil,
                        protocols: cat.protocols,
                        memberSummary: "\(cat.properties.count) props · \(cat.instanceMethods.count + cat.classMethods.count) methods",
                        allClasses: allClasses,
                        allProtocols: allProtocols,
                        onShareHeaderFile: onShareHeaderFile
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(cat.className) (\(cat.name))")
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text("\(cat.instanceMethods.count + cat.classMethods.count) methods · \(cat.properties.count) props")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct LCSwiftTypesListView: View {
    let types: [LCSwiftTypeInfo]

    var body: some View {
        if types.isEmpty {
            ContentUnavailableView("No Swift Metadata", systemImage: "swift", description: Text("No __swift5_types or __swift5_proto descriptors found in this binary."))
        } else {
            List(types) { type in
                NavigationLink {
                    LCSwiftTypeDetailView(type: type)
                } label: {
                    HStack(spacing: 8) {
                        Text(type.kind.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(kindColor(type.kind))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(kindColor(type.kind).opacity(0.14), in: .capsule)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.name)
                                .font(.system(.subheadline, design: .monospaced))
                                .lineLimit(1)
                            if !type.fields.isEmpty {
                                Text("\(type.fields.count) \(type.kind == .enumType ? "cases" : "fields")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func kindColor(_ kind: LCSwiftTypeKind) -> Color {
        switch kind {
        case .structType: return .blue
        case .classType: return .purple
        case .enumType: return .orange
        case .protocolType: return .teal
        }
    }
}

private struct LCObjCHierarchyRow: Identifiable {
    let id: String
    let cls: LCObjCClassInfo
    let depth: Int
}

private struct LCObjCHierarchyListView: View {
    let classes: [LCObjCClassInfo]
    let allProtocols: [LCObjCProtocolInfo]
    let searchQuery: String
    let onShareHeaderFile: (URL) -> Void

    private var flattenedRows: [LCObjCHierarchyRow] {
        let byName = Dictionary(classes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenMap: [String: [LCObjCClassInfo]] = [:]
        var roots: [LCObjCClassInfo] = []

        for cls in classes {
            if let sup = cls.superclassName, byName[sup] != nil {
                childrenMap[sup, default: []].append(cls)
            } else {
                roots.append(cls)
            }
        }

        var rows: [LCObjCHierarchyRow] = []
        var visited = Set<String>()

        func appendSubtree(_ cls: LCObjCClassInfo, depth: Int) {
            guard depth <= 12, visited.insert(cls.name).inserted else { return }
            rows.append(LCObjCHierarchyRow(id: "\(cls.id)#\(depth)", cls: cls, depth: depth))
            for child in (childrenMap[cls.name] ?? []).sorted(by: { $0.name < $1.name }) {
                appendSubtree(child, depth: depth + 1)
            }
        }

        for root in roots.sorted(by: { $0.name < $1.name }) {
            appendSubtree(root, depth: 0)
        }

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.cls.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let rows = flattenedRows
        if rows.isEmpty {
            ContentUnavailableView("No Class Hierarchy", systemImage: "list.bullet.indent", description: Text("No Objective-C classes available."))
        } else {
            List(rows) { row in
                NavigationLink {
                    LCObjCHeaderDetailView(
                        title: "\(row.cls.name).h",
                        target: .objcClass(row.cls),
                        superclassName: row.cls.superclassName,
                        protocols: row.cls.protocols,
                        memberSummary: "\(row.cls.properties.count) props · \(row.cls.instanceMethods.count + row.cls.classMethods.count) methods",
                        allClasses: classes,
                        allProtocols: allProtocols,
                        onShareHeaderFile: onShareHeaderFile
                    )
                } label: {
                    HStack(spacing: 6) {
                        if row.depth > 0 {
                            Text(String(repeating: "  ", count: row.depth) + "└")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.cls.name)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                            if row.depth == 0, let sup = row.cls.superclassName {
                                Text("inherits \(sup)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private enum LCObjCHeaderTarget: Sendable {
    case objcClass(LCObjCClassInfo)
    case objcProtocol(LCObjCProtocolInfo)
    case objcCategory(LCObjCCategoryInfo)

    nonisolated func render() -> String {
        switch self {
        case let .objcClass(cls):
            return LCMachOObjCDumper.renderHeader(for: cls)
        case let .objcProtocol(proto):
            return LCMachOObjCDumper.renderHeader(for: proto)
        case let .objcCategory(cat):
            return LCMachOObjCDumper.renderHeader(for: cat)
        }
    }
}

/// Objective-C `.h` header viewer with lazy rendering, copy, single-file export,
/// and superclass/protocol cross-navigation.
private struct LCObjCHeaderDetailView: View {
    let title: String
    let target: LCObjCHeaderTarget
    let superclassName: String?
    let protocols: [String]
    let memberSummary: String
    let allClasses: [LCObjCClassInfo]
    let allProtocols: [LCObjCProtocolInfo]
    let onShareHeaderFile: (URL) -> Void

    @State private var headerCode = ""
    @State private var copied = false
    @State private var exportError: String?

    private var superclassMatch: LCObjCClassInfo? {
        guard let superclassName else { return nil }
        return allClasses.first { $0.name == superclassName }
    }

    var body: some View {
        VStack(spacing: 0) {
            if superclassMatch != nil || !protocols.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let sup = superclassMatch {
                            NavigationLink {
                                LCObjCHeaderDetailView(
                                    title: "\(sup.name).h",
                                    target: .objcClass(sup),
                                    superclassName: sup.superclassName,
                                    protocols: sup.protocols,
                                    memberSummary: "\(sup.properties.count) props · \(sup.instanceMethods.count + sup.classMethods.count) methods",
                                    allClasses: allClasses,
                                    allProtocols: allProtocols,
                                    onShareHeaderFile: onShareHeaderFile
                                )
                            } label: {
                                Label("Super: \(sup.name)", systemImage: "arrow.up.right")
                                    .font(.caption2.monospaced().weight(.semibold))
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        ForEach(protocols, id: \.self) { protoName in
                            if let proto = allProtocols.first(where: { $0.name == protoName }) {
                                NavigationLink {
                                    LCObjCHeaderDetailView(
                                        title: "\(proto.name)-Protocol.h",
                                        target: .objcProtocol(proto),
                                        superclassName: nil,
                                        protocols: proto.adoptedProtocols,
                                        memberSummary: "\(proto.properties.count) props",
                                        allClasses: allClasses,
                                        allProtocols: allProtocols,
                                        onShareHeaderFile: onShareHeaderFile
                                    )
                                } label: {
                                    Text("<\(protoName)>")
                                        .font(.caption2.monospaced())
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            HStack {
                Text(memberSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            ScrollView([.vertical, .horizontal]) {
                Text(headerCode)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = headerCode
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }

                Button {
                    Task {
                        let stem = (title as NSString).deletingPathExtension
                        let code = headerCode
                        do {
                            let url = try await lcRunOffMain {
                                try LCMachOExportService.exportSingleHeader(name: stem, content: code)
                            }
                            onShareHeaderFile(url)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task(id: title) {
            if headerCode.isEmpty {
                let renderTarget = target
                headerCode = (try? await lcRunOffMain { renderTarget.render() }) ?? ""
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

private struct LCSwiftTypeDetailView: View {
    let type: LCSwiftTypeInfo
    @State private var copied = false

    private var declarationText: String {
        var lines = ["\(type.kind.rawValue) \(type.name) {"]
        for field in type.fields {
            if type.kind == .enumType {
                let ind = field.isIndirect ? "indirect " : ""
                lines.append(field.typeName == "Any" ? "    \(ind)case \(field.name)" : "    \(ind)case \(field.name)(\(field.typeName))")
            } else {
                lines.append("    \(field.isMutable ? "var" : "let") \(field.name): \(field.typeName)")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(declarationText)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(type.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = declarationText
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

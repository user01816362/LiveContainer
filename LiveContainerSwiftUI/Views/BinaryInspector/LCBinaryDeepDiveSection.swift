//
//  LCBinaryDeepDiveSection.swift
//  LiveContainerSwiftUI
//
//  Deep Dive tab for LiveContainer's Binary Inspector: Demangled Symbols &
//  Exports Trie, Categorized C-Strings Extractor, and paginated 4 KiB Hex Viewer.
//

import SwiftUI
import UIKit

/// Renders the Deep Dive tab (`Symbols`, `Strings`, and `Hex`).
struct LCBinaryDeepDiveSection: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    @Binding var subtab: LCBinaryDeepDiveSubtab
    @Binding var hexJumpOffset: UInt64

    let symbolsResult: LCMachOSymbolsResult?
    let isLoadingSymbols: Bool
    let symbolsError: String?

    let stringsResult: LCMachOStringsResult?
    let isLoadingStrings: Bool
    let stringsError: String?

    let onEnsureSymbols: () -> Void
    let onEnsureStrings: () -> Void

    @State private var searchQuery = ""
    @State private var selectedScope: LCMachOSymbolScope? = nil
    @State private var swiftOnlySymbols = false
    @State private var selectedStringCategory: LCMachOStringCategory = .all

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(LCBinaryDeepDiveSubtab.allCases) { tab in
                    Button {
                        subtab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .tint(subtab == tab ? .accentColor : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            switch subtab {
            case .symbols:
                LCBinarySymbolsSubView(
                    result: symbolsResult,
                    isLoading: isLoadingSymbols,
                    errorMessage: symbolsError,
                    searchQuery: searchQuery,
                    selectedScope: $selectedScope,
                    swiftOnly: $swiftOnlySymbols,
                    onRetry: onEnsureSymbols
                )
            case .strings:
                LCBinaryStringsSubView(
                    result: stringsResult,
                    isLoading: isLoadingStrings,
                    errorMessage: stringsError,
                    searchQuery: searchQuery,
                    selectedCategory: $selectedStringCategory,
                    onJumpToHex: { offset in
                        hexJumpOffset = offset
                        subtab = .hex
                    },
                    onRetry: onEnsureStrings
                )
            case .hex:
                LCHexPageViewer(
                    fileURL: fileURL,
                    rootURL: rootURL,
                    needsSecurityScope: needsSecurityScope,
                    initialOffset: hexJumpOffset
                )
                .id("\(fileURL.path)#\(hexJumpOffset)")
            }
        }
        .searchable(text: $searchQuery, prompt: subtab == .strings ? "Filter strings" : "Filter symbols")
    }
}

private struct LCBinarySymbolsSubView: View {
    let result: LCMachOSymbolsResult?
    let isLoading: Bool
    let errorMessage: String?
    let searchQuery: String
    @Binding var selectedScope: LCMachOSymbolScope?
    @Binding var swiftOnly: Bool
    let onRetry: () -> Void

    private var filteredSymbols: [LCMachOSymbolInfo] {
        guard let items = result?.symbols else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { sym in
            if let selectedScope, sym.scope != selectedScope { return false }
            if swiftOnly && !sym.isSwift { return false }
            guard !q.isEmpty else { return true }
            return sym.demangledName.localizedCaseInsensitiveContains(q)
                || sym.rawName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        if isLoading && result == nil {
            ProgressView("Loading exports trie & symbol table…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Symbol Load Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry", action: onRetry).buttonStyle(.glassProminent)
            }
        } else {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("All") { selectedScope = nil }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                            .tint(selectedScope == nil ? .accentColor : .secondary)

                        ForEach(LCMachOSymbolScope.allCases) { scope in
                            Button(scope.rawValue) { selectedScope = scope }
                                .buttonStyle(.glass)
                                .controlSize(.mini)
                                .tint(selectedScope == scope ? .accentColor : .secondary)
                        }

                        Button("Swift") { swiftOnly.toggle() }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                            .tint(swiftOnly ? .pink : .secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }

                let shown = Array(filteredSymbols.prefix(2000))
                if shown.isEmpty {
                    ContentUnavailableView("No Symbols", systemImage: "function", description: Text("No symbols match the current filter."))
                } else {
                    List {
                        Section {
                            ForEach(shown) { sym in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sym.demangledName)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .lineLimit(3)
                                    HStack(spacing: 8) {
                                        Text(sym.scope.rawValue)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(scopeColor(sym.scope))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(scopeColor(sym.scope).opacity(0.14), in: .capsule)
                                        if sym.address > 0 {
                                            Text(String(format: "0x%llX", sym.address))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                                .contextMenu {
                                    Button("Copy Demangled Name", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = sym.demangledName
                                    }
                                    if sym.rawName != sym.demangledName {
                                        Button("Copy Mangled Name", systemImage: "doc.on.doc.fill") {
                                            UIPasteboard.general.string = sym.rawName
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Showing \(shown.count) of \(filteredSymbols.count) matching symbols")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
    }

    private func scopeColor(_ scope: LCMachOSymbolScope) -> Color {
        switch scope {
        case .exported: return .green
        case .external: return .blue
        case .undefined: return .orange
        case .local: return .secondary
        }
    }
}

private struct LCBinaryStringsSubView: View {
    let result: LCMachOStringsResult?
    let isLoading: Bool
    let errorMessage: String?
    let searchQuery: String
    @Binding var selectedCategory: LCMachOStringCategory
    let onJumpToHex: (UInt64) -> Void
    let onRetry: () -> Void

    private var filteredEntries: [LCMachOStringEntry] {
        guard let items = result?.entries else { return [] }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { entry in
            if selectedCategory != .all && entry.category != selectedCategory { return false }
            guard !q.isEmpty else { return true }
            return entry.value.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        if isLoading && result == nil {
            ProgressView("Scanning string sections…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Strings Unavailable", systemImage: "text.magnifyingglass")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry", action: onRetry).buttonStyle(.glassProminent)
            }
        } else {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LCMachOStringCategory.allCases) { cat in
                            Button(cat.rawValue) { selectedCategory = cat }
                                .buttonStyle(.glass)
                                .controlSize(.mini)
                                .tint(selectedCategory == cat ? .accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }

                let shown = Array(filteredEntries.prefix(2000))
                if shown.isEmpty {
                    ContentUnavailableView("No Strings Found", systemImage: "text.magnifyingglass", description: Text("No strings match the current filter."))
                } else {
                    List {
                        Section {
                            ForEach(shown) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(3)
                                    HStack(spacing: 8) {
                                        Text(entry.category.rawValue)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.teal)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.teal.opacity(0.14), in: .capsule)
                                        Text(String(format: "off 0x%llX", entry.fileOffset))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contextMenu {
                                    Button("Copy String", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = entry.value
                                    }
                                    Button("View in Hex", systemImage: "number.square") {
                                        onJumpToHex(entry.fileOffset)
                                    }
                                }
                            }
                        } header: {
                            Text("Showing \(shown.count) of \(filteredEntries.count) strings")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
    }
}

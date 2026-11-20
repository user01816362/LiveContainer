//
//  LCSQLiteViewerView.swift
//  LiveContainerSwiftUI
//
//  Read-only, paginated SQLite database inspector for browsing app container
//  databases safely without mutating WAL files or exhausting memory.
//

import SwiftUI
import UIKit

/// Lists all tables and views inside a SQLite database opened strictly read-only.
struct LCSQLiteViewerView: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool

    @State private var tables: [LCSQLiteTableInfo] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var searchQuery = ""

    private var filteredTables: [LCSQLiteTableInfo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Opening database read-only…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Open Database",
                    systemImage: "cylinder.split.1x2",
                    description: Text(errorMessage)
                )
            } else if tables.isEmpty {
                ContentUnavailableView(
                    "No Tables Found",
                    systemImage: "cylinder",
                    description: Text("This SQLite database does not contain any tables or views.")
                )
            } else {
                List {
                    Section {
                        ForEach(filteredTables) { table in
                            NavigationLink {
                                LCSQLiteTableRowsView(
                                    fileURL: fileURL,
                                    rootURL: rootURL,
                                    needsSecurityScope: needsSecurityScope,
                                    table: table
                                )
                            } label: {
                                HStack {
                                    Label(table.name, systemImage: "tablecells")
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    if table.rowCount >= 0 {
                                        Text("\(table.rowCount) rows")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Tables & Views (\(filteredTables.count))")
                    } footer: {
                        Text("Opened strictly read-only (`SQLITE_OPEN_READONLY`). Database files are never modified.")
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchQuery, prompt: "Filter tables")
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: fileURL) {
            await loadTables()
        }
    }

    private func loadTables() async {
        isLoading = true
        errorMessage = nil
        let targetURL = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        do {
            let loaded = try await lcRunOffMain {
                try LCFileExplorerService.loadSQLiteTables(
                    at: targetURL,
                    rootURL: root,
                    needsSecurityScope: scope
                )
            }
            if !Task.isCancelled {
                tables = loaded
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

private struct LCSQLiteSelectedRow: Identifiable {
    let id: Int
    let rowNumber: Int
    let pairs: [(column: String, value: String)]
}

private struct LCSQLiteTableRowsView: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    let table: LCSQLiteTableInfo

    private let pageSize = 50
    @State private var offset = 0
    @State private var page: LCSQLitePageResult?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showSchema = false
    @State private var selectedRow: LCSQLiteSelectedRow?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && page == nil {
                ProgressView("Loading rows…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Query Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let page {
                List {
                    if showSchema && !table.createSQL.isEmpty {
                        Section("Schema") {
                            Text(table.createSQL)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    Section {
                        if page.rows.isEmpty {
                            Text("No rows on this page.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(page.rows.enumerated()), id: \.offset) { idx, row in
                                Button {
                                    let pairs = zip(page.columns, row).map { (column: $0, value: $1) }
                                    selectedRow = LCSQLiteSelectedRow(id: page.offset + idx, rowNumber: page.offset + idx + 1, pairs: pairs)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Row #\(page.offset + idx + 1)")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.secondary)
                                        ForEach(Array(zip(page.columns, row).prefix(4).enumerated()), id: \.offset) { _, pair in
                                            HStack(alignment: .top, spacing: 6) {
                                                Text(pair.0)
                                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                Text(pair.1)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        if page.columns.count > 4 {
                                            Text("+\(page.columns.count - 4) more column(s) — tap to inspect")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        let start = page.rows.isEmpty ? 0 : page.offset + 1
                        let end = page.offset + page.rows.count
                        Text("Rows \(start)–\(end) of \(max(page.totalRows, Int64(end)))")
                    }
                }
                .listStyle(.insetGrouped)

                paginationBar(page: page)
            }
        }
        .navigationTitle(table.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !table.createSQL.isEmpty {
                    Button(showSchema ? "Hide SQL" : "Schema") {
                        showSchema.toggle()
                    }
                }
            }
        }
        .sheet(item: $selectedRow) { row in
            NavigationStack {
                List {
                    ForEach(Array(row.pairs.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pair.column)
                                .font(.caption.weight(.bold).monospaced())
                                .foregroundStyle(.secondary)
                            Text(pair.value)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .navigationTitle("Row #\(row.rowNumber)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("lc.common.close".loc) { selectedRow = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Copy") {
                            let summary = row.pairs.map { "\($0.column): \($0.value)" }.joined(separator: "\n")
                            UIPasteboard.general.string = summary
                        }
                    }
                }
            }
        }
        .task(id: offset) {
            await loadPage()
        }
    }

    private func paginationBar(page: LCSQLitePageResult) -> some View {
        let hasPrev = page.offset > 0
        let hasNext = Int64(page.offset + page.rows.count) < page.totalRows
        return HStack {
            Button {
                offset = max(0, offset - pageSize)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!hasPrev || isLoading)

            Spacer()

            Text("Page \((page.offset / pageSize) + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                offset += pageSize
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!hasNext || isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func loadPage() async {
        isLoading = true
        errorMessage = nil
        let targetURL = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        let tableName = table.name
        let currentOffset = offset
        let limit = pageSize
        do {
            let loaded = try await lcRunOffMain {
                try LCFileExplorerService.loadSQLitePage(
                    at: targetURL,
                    rootURL: root,
                    needsSecurityScope: scope,
                    tableName: tableName,
                    offset: currentOffset,
                    limit: limit
                )
            }
            if !Task.isCancelled {
                page = loaded
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

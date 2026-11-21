//
//  LCDebugNetworkPanelView.swift
//  LiveContainerSwiftUI
//
//  Pro-grade HTTP, GraphQL, WebSocket, and WKWebView traffic inspector panel
//  with live in-flight state, multi-axis filters, swipe actions, and HAR export.
//

import SwiftUI

struct LCDebugNetworkPanelView: View {
    @Bindable var networkStore: LCDebugNetworkStore
    let manager: LCDebugStudioManager
    let onCopyWithFeedback: (String, String) -> Void

    @State private var shareFileItem: LCDebugShareFileURL? = nil
    @State private var isExportingHAR = false

    var body: some View {
        VStack(spacing: 6) {
            LCDebugNetworkToolbar(
                searchQuery: $networkStore.searchQuery,
                isPaused: networkStore.settings.paused,
                isExportingHAR: isExportingHAR,
                hasActiveFilters: hasActiveFilters,
                onTogglePause: {
                    Task { await manager.setNetworkPaused(!networkStore.settings.paused) }
                },
                onOpenSettings: {
                    Task { await manager.loadNetworkSettings() }
                    networkStore.showSettingsSheet = true
                },
                onExportHAR: { redact in
                    exportHAR(redact: redact)
                },
                onCopySummary: {
                    let lines = networkStore.filteredTransactions.map { tx in
                        "\(tx.method) [\(tx.statusBadgeText)] \(LCDebugFormatting.formatDuration(tx.durationMs)) · \(LCDebugFormatting.formatByteCount(tx.effectiveByteCount)) · \(tx.url)"
                    }.joined(separator: "\n")
                    onCopyWithFeedback(lines, "Copied Network Summary")
                },
                onClearFiltered: {
                    Task { await manager.clearNetwork(filteredOnly: true) }
                },
                onClearAll: {
                    Task { await manager.clearNetwork(filteredOnly: false) }
                }
            )

            LCDebugNetworkStatsStrip(
                shownCount: networkStore.filteredTransactions.count,
                totalCount: networkStore.totalCount,
                totalBytes: networkStore.totalBytes,
                errorCount: networkStore.errorCount,
                inFlightCount: networkStore.inFlightCount,
                averageDurationMs: networkStore.averageDurationMs,
                hasActiveFilters: hasActiveFilters,
                onResetFilters: { networkStore.resetFilters() }
            )

            LCDebugNetworkFilterBar(
                statusFilter: $networkStore.statusFilter,
                typeFilter: $networkStore.typeFilter,
                methodFilter: $networkStore.methodFilter,
                hostFilter: $networkStore.hostFilter,
                availableHosts: networkStore.availableHosts
            )

            LCDebugNetworkTransactionList(
                transactions: networkStore.filteredTransactions,
                isPaused: networkStore.settings.paused,
                onSelect: { entry in
                    networkStore.selectedTransaction = entry
                },
                onReplay: { entry in
                    manager.openReplayComposer(for: entry)
                },
                onCopyCurl: { entry in
                    onCopyWithFeedback(entry.curl, "Copied cURL Command")
                },
                onCopyURL: { entry in
                    onCopyWithFeedback(entry.url, "Copied URL")
                },
                onExcludeHost: { host in
                    Task { await manager.excludeHost(host) }
                }
            )
        }
        .sheet(item: $shareFileItem) { item in
            LCDebugActivityShareSheet(url: item.url)
        }
    }

    private var hasActiveFilters: Bool {
        !networkStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || networkStore.statusFilter != .all
            || networkStore.typeFilter != .all
            || networkStore.methodFilter != "ALL"
            || networkStore.hostFilter != "ALL"
    }

    private func exportHAR(redact: Bool) {
        guard !isExportingHAR else { return }
        isExportingHAR = true
        Task {
            defer { isExportingHAR = false }
            if let fileURL = await manager.exportHARFileURL(redact: redact) {
                shareFileItem = LCDebugShareFileURL(url: fileURL)
            }
        }
    }
}

private struct LCDebugShareFileURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LCDebugNetworkToolbar: View {
    @Binding var searchQuery: String
    let isPaused: Bool
    let isExportingHAR: Bool
    let hasActiveFilters: Bool
    let onTogglePause: () -> Void
    let onOpenSettings: () -> Void
    let onExportHAR: (Bool) -> Void
    let onCopySummary: () -> Void
    let onClearFiltered: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Filter URL, host, method, status…", text: $searchQuery)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
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

            Button {
                onTogglePause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .foregroundStyle(isPaused ? .orange : .green)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .accessibilityLabel(isPaused ? "Resume Network Capture" : "Pause Network Capture")

            Menu {
                Button("Export HAR (.har)", systemImage: "square.and.arrow.up") {
                    onExportHAR(false)
                }
                Button("Export Redacted HAR", systemImage: "eye.slash") {
                    onExportHAR(true)
                }
                Button("Copy Filtered Summary", systemImage: "doc.on.doc") {
                    onCopySummary()
                }
                Divider()
                if hasActiveFilters {
                    Button("Clear Filtered Requests", role: .destructive) {
                        onClearFiltered()
                    }
                }
                Button("Clear All Requests", systemImage: "trash", role: .destructive) {
                    onClearAll()
                }
            } label: {
                if isExportingHAR {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.mini)

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .accessibilityLabel("Network Settings")
        }
    }
}

private struct LCDebugNetworkStatsStrip: View {
    let shownCount: Int
    let totalCount: Int
    let totalBytes: Int
    let errorCount: Int
    let inFlightCount: Int
    let averageDurationMs: Int
    let hasActiveFilters: Bool
    let onResetFilters: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(hasActiveFilters ? "\(shownCount)/\(totalCount) reqs" : "\(totalCount) reqs")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(LCDebugFormatting.formatByteCount(totalBytes))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if inFlightCount > 0 {
                Text("· \(inFlightCount) live")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            if errorCount > 0 {
                Text("· \(errorCount) err")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if averageDurationMs > 0 {
                Text("· ~\(averageDurationMs)ms")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasActiveFilters {
                Button("Reset") {
                    onResetFilters()
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.cyan)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct LCDebugNetworkFilterBar: View {
    @Binding var statusFilter: LCDebugNetworkStatusFilter
    @Binding var typeFilter: LCDebugNetworkTypeFilter
    @Binding var methodFilter: String
    @Binding var hostFilter: String
    let availableHosts: [String]

    private static let methods = ["ALL", "GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(LCDebugNetworkStatusFilter.allCases) { item in
                    LCDebugFilterChipButton(
                        title: item.rawValue,
                        isSelected: statusFilter == item,
                        selectedColor: item == .errors ? .red : (item == .inFlight ? .orange : .blue)
                    ) {
                        statusFilter = item
                    }
                }

                Divider()
                    .frame(height: 14)

                ForEach(LCDebugNetworkTypeFilter.allCases) { item in
                    LCDebugFilterChipButton(
                        title: item == .all ? "All Types" : item.rawValue,
                        isSelected: typeFilter == item,
                        selectedColor: .cyan
                    ) {
                        typeFilter = item
                    }
                }

                Menu {
                    ForEach(Self.methods, id: \.self) { m in
                        Button {
                            methodFilter = m
                        } label: {
                            if methodFilter == m {
                                Label(m == "ALL" ? "All Methods" : m, systemImage: "checkmark")
                            } else {
                                Text(m == "ALL" ? "All Methods" : m)
                            }
                        }
                    }
                } label: {
                    LCDebugMenuChipLabel(title: methodFilter == "ALL" ? "Method" : methodFilter, isActive: methodFilter != "ALL")
                }

                if !availableHosts.isEmpty {
                    Menu {
                        Button("All Hosts") { hostFilter = "ALL" }
                        Divider()
                        ForEach(availableHosts, id: \.self) { h in
                            Button {
                                hostFilter = h
                            } label: {
                                if hostFilter == h {
                                    Label(h, systemImage: "checkmark")
                                } else {
                                    Text(h)
                                }
                            }
                        }
                    } label: {
                        LCDebugMenuChipLabel(
                            title: hostFilter == "ALL" ? "Host" : hostFilter,
                            isActive: hostFilter != "ALL"
                        )
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct LCDebugFilterChipButton: View {
    let title: String
    let isSelected: Bool
    let selectedColor: Color
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(isSelected ? selectedColor.opacity(0.68) : Color.white.opacity(0.08), in: .capsule)
            .foregroundStyle(.white)
            .buttonStyle(.plain)
    }
}

private struct LCDebugMenuChipLabel: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(isActive ? Color.purple.opacity(0.65) : Color.white.opacity(0.08), in: .capsule)
        .foregroundStyle(.white)
    }
}

private struct LCDebugNetworkTransactionList: View {
    let transactions: [LCDebugNetworkEntry]
    let isPaused: Bool
    let onSelect: (LCDebugNetworkEntry) -> Void
    let onReplay: (LCDebugNetworkEntry) -> Void
    let onCopyCurl: (LCDebugNetworkEntry) -> Void
    let onCopyURL: (LCDebugNetworkEntry) -> Void
    let onExcludeHost: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if transactions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: isPaused ? "pause.circle" : "network.slash")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(isPaused ? "Network capture is paused." : "No matching requests yet.")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(transactions) { entry in
                        LCDebugNetworkRow(
                            entry: entry,
                            onSelect: { onSelect(entry) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Replay", systemImage: "arrow.clockwise") {
                                onReplay(entry)
                            }
                            .tint(.blue)
                            Button("cURL", systemImage: "terminal") {
                                onCopyCurl(entry)
                            }
                            .tint(.teal)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !entry.resolvedHost.isEmpty {
                                Button("Exclude", systemImage: "eye.slash") {
                                    onExcludeHost(entry.resolvedHost)
                                }
                                .tint(.orange)
                            }
                        }
                        .contextMenu {
                            Button("Inspect Transaction", systemImage: "doc.text.magnifyingglass") {
                                onSelect(entry)
                            }
                            Button("Replay Request", systemImage: "arrow.clockwise") {
                                onReplay(entry)
                            }
                            Button("Copy cURL", systemImage: "terminal") {
                                onCopyCurl(entry)
                            }
                            Button("Copy URL", systemImage: "link") {
                                onCopyURL(entry)
                            }
                            if !entry.resolvedHost.isEmpty {
                                Divider()
                                Button("Exclude '\(entry.resolvedHost)'", systemImage: "eye.slash") {
                                    onExcludeHost(entry.resolvedHost)
                                }
                            }
                        }
                    }
                }
            }
        }
        .swipeActionsContainer()
    }
}

private struct LCDebugNetworkRow: View {
    let entry: LCDebugNetworkEntry
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .center, spacing: 3) {
                    Text(entry.method.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Text(entry.statusBadgeText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.16), in: .capsule)
                }
                .frame(width: 48)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.displayEndpoint)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(entry.isFailure ? .red : .white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !entry.shortMimeLabel.isEmpty {
                            Text(entry.shortMimeLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.08), in: .capsule)
                        }
                    }

                    HStack(spacing: 5) {
                        Text(entry.displayHostAndDir)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        if entry.isGraphQL == true, let op = entry.graphQLOperation, !op.isEmpty {
                            Text("· \(op)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.purple)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        let stamp = LCDebugFormatting.formatTimestamp(entry.timestamp)
                        if !stamp.isEmpty {
                            Text(stamp)
                                .foregroundStyle(.tertiary)
                        }
                        if entry.source == "webview" || entry.source == "websocket" || entry.source == "urlconnection" {
                            Text(entry.displaySource)
                                .foregroundStyle(.teal)
                        }
                        Text(LCDebugFormatting.formatByteCount(entry.effectiveByteCount))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(entry.isInFlight ? "Pending…" : LCDebugFormatting.formatDuration(entry.durationMs))
                            .foregroundStyle(durationColor)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if entry.isInFlight { return .yellow }
        if entry.isFailure { return .red }
        if (200...299).contains(entry.statusCode) { return .green }
        if entry.statusCode == 101 || (300...399).contains(entry.statusCode) { return .cyan }
        return .secondary
    }

    private var durationColor: Color {
        if entry.isInFlight { return .yellow }
        if entry.durationMs >= 1500 { return .red }
        if entry.durationMs >= 500 { return .orange }
        return .secondary
    }
}

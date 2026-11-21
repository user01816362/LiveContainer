//
//  LCDebugConsoleAndEventsPanels.swift
//  LiveContainerSwiftUI
//
//  Modular nominal SwiftUI 27 panels for Console Logs and UI/Runtime Events.
//

import SwiftUI

// MARK: - 1. Console Panel

struct LCDebugConsolePanel: View {
    @Bindable var consoleStore: LCDebugConsoleStore
    let isConnected: Bool
    let manager: LCDebugStudioManager
    let onCopyWithFeedback: (String, String) -> Void

    @State private var shareFile: LCDebugInspectorShareURL? = nil

    var body: some View {
        let items = consoleStore.filteredLogs
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter stdout / NSLog / OSLog / Web…", text: $consoleStore.searchQuery)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !consoleStore.searchQuery.isEmpty {
                        Button {
                            consoleStore.searchQuery = ""
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
                    consoleStore.isPaused.toggle()
                } label: {
                    Image(systemName: consoleStore.isPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(consoleStore.isPaused ? .orange : .green)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)

                Button {
                    consoleStore.autoScroll.toggle()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundStyle(consoleStore.autoScroll ? Color.cyan : Color.secondary)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)

                Menu {
                    Button("Refresh Snapshot", systemImage: "arrow.clockwise") {
                        Task { await manager.refreshStatusAndSnapshots() }
                    }
                    Button("Copy Filtered Logs", systemImage: "doc.on.doc") {
                        let text = items.map {
                            let stamp = LCDebugFormatting.formatTimestamp($0.timestamp)
                            let sub = ($0.subsystem?.isEmpty == false) ? ":\($0.subsystem!)" : ""
                            return "\(stamp.isEmpty ? "" : "[\(stamp)] ")[\($0.stream)\(sub)] \($0.text)"
                        }.joined(separator: "\n")
                        onCopyWithFeedback(text, "Copied Console Logs")
                    }
                    Button("Export .log File", systemImage: "square.and.arrow.up") {
                        if let url = manager.exportLogsFileURL() {
                            shareFile = LCDebugInspectorShareURL(url: url)
                        }
                    }
                    Divider()
                    Button("Clear Console", systemImage: "trash", role: .destructive) {
                        Task { await manager.clearLogs() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LCDebugLogStreamFilter.allCases) { filter in
                        Button(filter.rawValue) {
                            consoleStore.streamFilter = filter
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(consoleStore.streamFilter == filter ? Color.blue.opacity(0.75) : Color.white.opacity(0.08), in: .capsule)
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if items.isEmpty {
                            Text(isConnected ? "No matching logs yet. Output from print(), NSLog, OSLog, WKWebView, and crashes streams here live." : "Connecting to Debug Agent…")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        } else {
                            ForEach(items) { entry in
                                LCDebugLogRow(entry: entry) {
                                    consoleStore.selectedLog = entry
                                } onCopy: {
                                    onCopyWithFeedback(entry.text, "Copied Log Line")
                                }
                                .id(entry.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("lc-console-bottom")
                        }
                    }
                }
                .onChange(of: items.last?.id) { _, _ in
                    if consoleStore.autoScroll, !items.isEmpty {
                        proxy.scrollTo("lc-console-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .sheet(item: $consoleStore.selectedLog) { entry in
            LCDebugLogDetailSheet(entry: entry) {
                onCopyWithFeedback(entry.text, "Copied Log Entry")
            }
        }
        .sheet(item: $shareFile) { item in
            LCDebugActivityShareSheet(url: item.url)
        }
    }
}

private struct LCDebugInspectorShareURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LCDebugLogRow: View {
    let entry: LCDebugLogEntry
    let onTap: () -> Void
    let onCopy: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 6) {
                let stamp = LCDebugFormatting.formatTimestamp(entry.timestamp)
                if !stamp.isEmpty {
                    Text(stamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(entry.stream.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(streamColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(streamColor.opacity(0.14), in: .capsule)

                if let sub = entry.subsystem, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.isErrorLike ? .red : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Inspect Entry", systemImage: "doc.text.magnifyingglass", action: onTap)
            Button("Copy Line", systemImage: "doc.on.doc", action: onCopy)
        }
    }

    private var streamColor: Color {
        if entry.isErrorLike { return .red }
        switch entry.stream {
        case "nslog": return .yellow
        case "oslog": return .mint
        case "webview": return .purple
        case "debug": return .orange
        default: return .cyan
        }
    }
}

private struct LCDebugLogDetailSheet: View {
    let entry: LCDebugLogEntry
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Metadata") {
                    LabeledContent("Stream", value: entry.stream)
                    LabeledContent("Level", value: entry.effectiveLevel)
                    let stamp = LCDebugFormatting.formatTimestamp(entry.timestamp)
                    if !stamp.isEmpty {
                        LabeledContent("Time", value: stamp)
                    }
                    if let sub = entry.subsystem, !sub.isEmpty {
                        LabeledContent("Subsystem", value: sub)
                    }
                    if let cat = entry.category, !cat.isEmpty {
                        LabeledContent("Category", value: cat)
                    }
                }
                Section("Message") {
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Log Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { onCopy() }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 2. UI & Runtime Events Panel

struct LCDebugEventsPanel: View {
    @Bindable var inspectorStore: LCDebugInspectorStore
    let telemetryStore: LCDebugTelemetryStore
    let manager: LCDebugStudioManager

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter touches, actions, VCs, tabs…", text: $inspectorStore.eventSearch)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !inspectorStore.eventSearch.isEmpty {
                        Button {
                            inspectorStore.eventSearch = ""
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

                Button(telemetryStore.isNotificationMonitorEnabled ? "Notifs ON" : "Notifs") {
                    Task { await manager.toggleNotificationMonitor() }
                }
                .buttonStyle(.glassProminent)
                .tint(telemetryStore.isNotificationMonitorEnabled ? .blue : .secondary.opacity(0.35))
                .controlSize(.mini)

                Button("Clear") {
                    Task { await manager.clearUIEvents() }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(LCDebugUIEventKindFilter.allCases) { kind in
                        Button(kind.rawValue) {
                            inspectorStore.eventKindFilter = kind
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(inspectorStore.eventKindFilter == kind ? Color.cyan.opacity(0.68) : Color.white.opacity(0.08), in: .capsule)
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                    }
                }
            }

            List(inspectorStore.filteredUIEvents) { ev in
                Button {
                    inspectorStore.selectedEvent = ev
                } label: {
                    LCDebugEventRow(event: ev)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .sheet(item: $inspectorStore.selectedEvent) { ev in
            LCDebugEventDetailSheet(event: ev)
        }
    }
}

private struct LCDebugEventRow: View {
    let event: LCDebugUIEventEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.kind.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(kindColor.opacity(0.14), in: .capsule)
                Text(event.title)
                    .font(.caption.bold().monospaced())
                    .lineLimit(1)
                Spacer()
                let stamp = LCDebugFormatting.formatTimestamp(event.timestamp)
                if !stamp.isEmpty {
                    Text(stamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("\(event.detail)\(event.viewController.isEmpty ? "" : " · VC: \(event.viewController)")\(event.window.isEmpty ? "" : " · \(event.window)")")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var kindColor: Color {
        switch event.kind.lowercased() {
        case "touch": return .cyan
        case "action": return .teal
        case "tab": return .green
        case "nav": return .mint
        case "modal": return .orange
        case "window": return .yellow
        case "notification": return .purple
        default: return .blue
        }
    }
}

private struct LCDebugEventDetailSheet: View {
    let event: LCDebugUIEventEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Kind", value: event.kind.uppercased())
                LabeledContent("Title", value: event.title)
                if !event.detail.isEmpty {
                    LabeledContent("Detail", value: event.detail)
                }
                if !event.target.isEmpty {
                    LabeledContent("Target", value: event.target)
                }
                if !event.viewController.isEmpty {
                    LabeledContent("View Controller", value: event.viewController)
                }
                if !event.window.isEmpty {
                    LabeledContent("Window", value: event.window)
                }
            }
            .navigationTitle("Event Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

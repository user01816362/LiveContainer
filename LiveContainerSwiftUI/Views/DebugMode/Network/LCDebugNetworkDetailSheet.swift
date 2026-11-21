//
//  LCDebugNetworkDetailSheet.swift
//  LiveContainerSwiftUI
//
//  Full-featured transaction detail inspector (Overview & Waterfall, Request, Response
//  with off-main Pretty JSON / Image preview / Hex dump), Settings, and Request Replay.
//

import SwiftUI
import UIKit

private enum LCNetworkDetailSectionTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case request = "Request"
    case response = "Response"

    var id: String { rawValue }
}

private enum LCNetworkBodyViewMode: String, CaseIterable, Identifiable {
    case pretty = "Pretty"
    case raw = "Raw"
    case hex = "Hex"

    var id: String { rawValue }
}

struct LCDebugNetworkDetailSheet: View {
    let entry: LCDebugNetworkEntry
    let manager: LCDebugStudioManager

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: LCNetworkDetailSectionTab = .response
    @State private var redactSensitive = false
    @State private var reqBodyPayload: LCDebugNetworkBodyPayload? = nil
    @State private var respBodyPayload: LCDebugNetworkBodyPayload? = nil
    @State private var isLoadingBodies = false
    @State private var toastMessage: String? = nil
    @State private var localReplayTarget: LCDebugNetworkReplayTarget? = nil

    private var liveEntry: LCDebugNetworkEntry {
        if let current = manager.networkStore.selectedTransaction, current.id == entry.id {
            return current
        }
        return entry
    }

    var body: some View {
        let currentEntry = liveEntry
        NavigationStack {
            VStack(spacing: 0) {
                LCNetworkHeroHeader(
                    entry: currentEntry,
                    onCopyCurl: {
                        let cmd = respBodyPayload?.curl ?? reqBodyPayload?.curl ?? currentEntry.curl
                        copyWithToast(cmd, message: "Copied cURL")
                    },
                    onReplay: {
                        let initialBody = (reqBodyPayload?.text.isEmpty == false)
                            ? (reqBodyPayload?.text ?? "")
                            : currentEntry.requestBodyPreview
                        localReplayTarget = LCDebugNetworkReplayTarget(
                            id: UUID().uuidString,
                            transactionId: currentEntry.id,
                            method: currentEntry.method,
                            url: currentEntry.url,
                            headers: currentEntry.requestHeaders,
                            body: initialBody
                        )
                    }
                )
                .padding(.horizontal)
                .padding(.top, 8)

                Picker("Section", selection: $selectedSection) {
                    ForEach(LCNetworkDetailSectionTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedSection {
                        case .overview:
                            LCNetworkOverviewSection(entry: currentEntry, onCopy: copyWithToast)
                        case .request:
                            LCNetworkRequestSection(
                                entry: currentEntry,
                                bodyPayload: reqBodyPayload,
                                isLoading: isLoadingBodies,
                                redactSensitive: redactSensitive,
                                onCopy: copyWithToast
                            )
                        case .response:
                            LCNetworkResponseSection(
                                entry: currentEntry,
                                bodyPayload: respBodyPayload,
                                isLoading: isLoadingBodies,
                                redactSensitive: redactSensitive,
                                onCopy: copyWithToast
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarOverflowMenu {
                    Button {
                        redactSensitive.toggle()
                        Task { await loadFullBodies() }
                    } label: {
                        Label(
                            redactSensitive ? "Show Sensitive Headers" : "Redact Sensitive Headers",
                            systemImage: redactSensitive ? "eye" : "eye.slash"
                        )
                    }
                    Button {
                        copyWithToast(currentEntry.url, message: "Copied URL")
                    } label: {
                        Label("Copy Full URL", systemImage: "link")
                    }
                    if !currentEntry.resolvedHost.isEmpty {
                        Button {
                            Task {
                                await manager.excludeHost(currentEntry.resolvedHost)
                                showToast("Excluded \(currentEntry.resolvedHost)")
                            }
                        } label: {
                            Label("Exclude '\(currentEntry.resolvedHost)'", systemImage: "hand.raised")
                        }
                    }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .top) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                }
            }
            .task(id: "\(currentEntry.id)-\(currentEntry.state ?? "")-\(redactSensitive)") {
                await loadFullBodies()
            }
            .sheet(item: $localReplayTarget) { target in
                LCDebugNetworkReplaySheet(initialTarget: target, manager: manager)
            }
        }
    }

    private func loadFullBodies() async {
        isLoadingBodies = true
        defer { isLoadingBodies = false }
        let redact = redactSensitive
        async let reqFetch = manager.fetchNetworkBody(id: entry.id, part: "request", redact: redact)
        async let respFetch = manager.fetchNetworkBody(id: entry.id, part: "response", redact: redact)
        reqBodyPayload = await reqFetch
        respBodyPayload = await respFetch
    }

    private func copyWithToast(_ text: String, message: String) {
        UIPasteboard.general.string = text
        showToast(message)
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

private struct LCNetworkHeroHeader: View {
    let entry: LCDebugNetworkEntry
    let onCopyCurl: () -> Void
    let onReplay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.method.uppercased())
                    .font(.caption.bold().monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.18), in: .capsule)
                    .foregroundStyle(.cyan)

                Text(entry.statusBadgeText)
                    .font(.caption.bold().monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusTint.opacity(0.18), in: .capsule)
                    .foregroundStyle(statusTint)

                if let proto = entry.metrics?.protocolName, !proto.isEmpty {
                    Text(proto)
                        .font(.caption2.bold().monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("cURL", systemImage: "terminal", action: onCopyCurl)
                    .buttonStyle(.glass)
                    .controlSize(.mini)

                if entry.source != "websocket" {
                    Button("Replay", systemImage: "arrow.clockwise", action: onReplay)
                        .buttonStyle(.glassProminent)
                        .controlSize(.mini)
                }
            }

            Text(entry.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Text(entry.displaySource)
                Text("·")
                Text(LCDebugFormatting.formatDuration(entry.durationMs))
                if let lat = entry.latencyMs, lat > 0 {
                    Text("· TTFB \(lat)ms")
                }
                Text("·")
                Text(LCDebugFormatting.formatByteCount(entry.effectiveByteCount))
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 14))
    }

    private var statusTint: Color {
        if entry.isInFlight { return .yellow }
        if entry.isFailure { return .red }
        if (200...299).contains(entry.statusCode) { return .green }
        return .cyan
    }
}

private struct LCNetworkOverviewSection: View {
    let entry: LCDebugNetworkEntry
    let onCopy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !entry.error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Text(entry.error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 12))
            }

            LCNetworkKeyValueCard(title: "General", pairs: generalPairs, onCopy: onCopy)

            if let metrics = entry.metrics {
                LCNetworkTimingWaterfallView(metrics: metrics)
            }
        }
    }

    private var generalPairs: [LCDebugKeyValuePair] {
        var rows: [LCDebugKeyValuePair] = [
            LCDebugKeyValuePair(id: "g|method", key: "Method", value: entry.method),
            LCDebugKeyValuePair(id: "g|status", key: "Status", value: entry.statusBadgeText),
            LCDebugKeyValuePair(id: "g|source", key: "Source", value: entry.mechanism ?? entry.displaySource),
            LCDebugKeyValuePair(id: "g|mime", key: "MIME Type", value: entry.mimeType.isEmpty ? "—" : entry.mimeType),
            LCDebugKeyValuePair(id: "g|start", key: "Started", value: LCDebugFormatting.formatTimestamp(entry.timestamp)),
            LCDebugKeyValuePair(id: "g|dur", key: "Total Duration", value: LCDebugFormatting.formatDuration(entry.durationMs)),
            LCDebugKeyValuePair(id: "g|reqb", key: "Request Size", value: LCDebugFormatting.formatByteCount(entry.requestBytes ?? 0)),
            LCDebugKeyValuePair(id: "g|respb", key: "Response Size", value: LCDebugFormatting.formatByteCount(entry.responseBytes ?? entry.bytes))
        ]
        if let lat = entry.latencyMs, lat > 0 {
            rows.append(LCDebugKeyValuePair(id: "g|ttfb", key: "Latency (TTFB)", value: "\(lat) ms"))
        }
        return rows
    }
}

private struct LCNetworkTimingWaterfallView: View {
    let metrics: LCDebugNetworkMetrics

    private struct PhaseItem: Identifiable {
        let id: String
        let label: String
        let startMs: Int
        let ms: Int
        let color: Color
    }

    var body: some View {
        let phases = buildPhases()
        let totalPhaseSpan = max(1, phases.reduce(0) { $0 + $1.ms })

        VStack(alignment: .leading, spacing: 8) {
            Text("Connection & Timing Waterfall")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(phases) { phase in
                HStack(spacing: 8) {
                    Text(phase.label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 68, alignment: .leading)
                    GeometryReader { geo in
                        let startOffset = (CGFloat(phase.startMs) / CGFloat(totalPhaseSpan)) * geo.size.width
                        let width = phase.ms > 0 ? max(4, (CGFloat(phase.ms) / CGFloat(totalPhaseSpan)) * geo.size.width) : 2
                        RoundedRectangle(cornerRadius: 4)
                            .fill(phase.ms > 0 ? phase.color : Color.white.opacity(0.14))
                            .frame(width: min(width, max(2, geo.size.width - startOffset)), height: 8)
                            .offset(x: min(startOffset, max(0, geo.size.width - 4)))
                            .frame(maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: 14)
                    Text("\(phase.ms) ms")
                        .font(.caption2.monospaced())
                        .frame(width: 58, alignment: .trailing)
                }
            }

            Divider()

            HStack(spacing: 12) {
                if let addr = metrics.remoteAddress, !addr.isEmpty {
                    Label(addr, systemImage: "server.rack")
                }
                if metrics.reusedConnection == true {
                    Label("Reused", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.green)
                }
                if metrics.isCellular == true {
                    Label("Cellular", systemImage: "antenna.radiowaves.left.and.right")
                }
                if metrics.isProxy == true {
                    Label("Proxy", systemImage: "network")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12))
    }

    private func buildPhases() -> [PhaseItem] {
        let dns = max(0, metrics.dnsMs ?? 0)
        let tls = max(0, metrics.tlsMs ?? 0)
        let rawConnect = max(0, metrics.connectMs ?? 0)
        let tcpOnly = max(0, rawConnect >= tls ? (rawConnect - tls) : rawConnect)
        let send = max(0, metrics.requestMs ?? 0)
        let wait = max(0, metrics.waitMs ?? 0)
        let recv = max(0, metrics.responseMs ?? 0)

        let rawList: [(String, String, Int, Color)] = [
            ("dns", "DNS", dns, .cyan),
            ("tcp", "TCP", tcpOnly, .blue),
            ("tls", "TLS", tls, .purple),
            ("req", "Send", send, .yellow),
            ("wait", "Wait", wait, .orange),
            ("dl", "Receive", recv, .green)
        ]
        var cursor = 0
        return rawList.map { id, label, ms, color in
            let item = PhaseItem(id: id, label: label, startMs: cursor, ms: ms, color: color)
            cursor += ms
            return item
        }
    }
}

private struct LCNetworkRequestSection: View {
    let entry: LCDebugNetworkEntry
    let bodyPayload: LCDebugNetworkBodyPayload?
    let isLoading: Bool
    let redactSensitive: Bool
    let onCopy: (String, String) -> Void

    var body: some View {
        let queryPairs = LCDebugFormatting.parseQueryItems(from: entry.url)
        let headerDict = bodyPayload?.requestHeaders ?? entry.requestHeaders
        let headerPairs = LCDebugFormatting.sortedHeaderPairs(headerDict)
        let rawBody = (bodyPayload?.text.isEmpty == false) ? (bodyPayload?.text ?? "") : entry.requestBodyPreview

        VStack(alignment: .leading, spacing: 12) {
            if !queryPairs.isEmpty {
                LCNetworkKeyValueCard(title: "Query Parameters (\(queryPairs.count))", pairs: queryPairs, onCopy: onCopy)
            }

            if let gql = LCDebugFormatting.parseGraphQLBody(rawBody) {
                LCNetworkGraphQLCard(payload: gql, onCopy: onCopy)
            }

            let formPairs = LCDebugFormatting.parseFormURLEncoded(rawBody)
            if !formPairs.isEmpty {
                LCNetworkKeyValueCard(title: "Form Parameters (\(formPairs.count))", pairs: formPairs, onCopy: onCopy)
            }

            if !headerPairs.isEmpty {
                LCNetworkKeyValueCard(
                    title: redactSensitive ? "Request Headers (Redacted)" : "Request Headers (\(headerPairs.count))",
                    pairs: headerPairs,
                    onCopy: onCopy
                )
            }

            LCNetworkBodyViewerCard(
                title: "Request Body",
                payload: bodyPayload,
                fallbackPreview: entry.requestBodyPreview,
                isLoading: isLoading,
                onCopy: onCopy
            )
        }
    }
}

private struct LCNetworkResponseSection: View {
    let entry: LCDebugNetworkEntry
    let bodyPayload: LCDebugNetworkBodyPayload?
    let isLoading: Bool
    let redactSensitive: Bool
    let onCopy: (String, String) -> Void

    var body: some View {
        let headerDict = bodyPayload?.responseHeaders ?? entry.responseHeaders
        let headerPairs = LCDebugFormatting.sortedHeaderPairs(headerDict)

        VStack(alignment: .leading, spacing: 12) {
            if !headerPairs.isEmpty {
                LCNetworkKeyValueCard(
                    title: redactSensitive ? "Response Headers (Redacted)" : "Response Headers (\(headerPairs.count))",
                    pairs: headerPairs,
                    onCopy: onCopy
                )
            }

            LCNetworkBodyViewerCard(
                title: "Response Body",
                payload: bodyPayload,
                fallbackPreview: entry.responseBodyPreview,
                isLoading: isLoading,
                onCopy: onCopy
            )
        }
    }
}

private struct LCNetworkKeyValueCard: View {
    let title: String
    let pairs: [LCDebugKeyValuePair]
    let onCopy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(pairs) { pair in
                    Button {
                        onCopy("\(pair.key): \(pair.value)", "Copied \(pair.key)")
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(pair.key)
                                .font(.caption2.bold().monospaced())
                                .foregroundStyle(.cyan)
                                .frame(minWidth: 92, maxWidth: 130, alignment: .leading)
                            Text(pair.value)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 12))
        }
    }
}

private struct LCNetworkGraphQLCard: View {
    let payload: LCDebugGraphQLPayload
    let onCopy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GraphQL\(payload.operationName.isEmpty ? "" : ": \(payload.operationName)")", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
                Spacer()
                if !payload.query.isEmpty {
                    Button("Copy Query") {
                        onCopy(payload.query, "Copied GraphQL Query")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
            }
            if !payload.query.isEmpty {
                Text(payload.query)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: .rect(cornerRadius: 8))
            }
            if !payload.variablesPretty.isEmpty {
                Text("Variables:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(payload.variablesPretty)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.28), in: .rect(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.10), in: .rect(cornerRadius: 12))
    }
}

private struct LCNetworkBodyViewerCard: View {
    let title: String
    let payload: LCDebugNetworkBodyPayload?
    let fallbackPreview: String
    let isLoading: Bool
    let onCopy: (String, String) -> Void

    @State private var mode: LCNetworkBodyViewMode = .pretty
    @State private var bodySearch = ""
    @State private var formattedPrettyText: String? = nil
    @State private var decodedImage: UIImage? = nil

    var body: some View {
        let rawText = (payload?.text.isEmpty == false) ? (payload?.text ?? "") : fallbackPreview

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let byteCount = payload?.byteCount, byteCount > 0 {
                    Text(LCDebugFormatting.formatByteCount(byteCount))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
                let copyText = (mode == .hex ? (payload?.hexPreview ?? rawText) : (formattedPrettyText ?? rawText))
                if !copyText.isEmpty {
                    Button("Copy") {
                        onCopy(copyText, "Copied \(title)")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
            }

            Picker("View Mode", selection: $mode) {
                ForEach(LCNetworkBodyViewMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if let decodedImage, mode == .pretty {
                VStack(spacing: 6) {
                    Image(uiImage: decodedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(.rect(cornerRadius: 10))
                    Text("\(Int(decodedImage.size.width * decodedImage.scale)) × \(Int(decodedImage.size.height * decodedImage.scale)) px · \(payload?.mimeType ?? "image")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.black.opacity(0.30), in: .rect(cornerRadius: 12))
            } else {
                let activeText = displayBodyText(rawText: rawText)
                if !activeText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("Search body…", text: $bodySearch)
                            .font(.caption2.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !bodySearch.isEmpty {
                            Button {
                                bodySearch = ""
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
                    .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 8))

                    Text(filteredDisplayLines(activeText))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.32), in: .rect(cornerRadius: 12))
                } else if !isLoading {
                    Text("No body payload captured.")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                if payload?.truncated == true {
                    Text("Large payload truncated to keep memory bounded.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .task(id: "\(rawText)-\(payload?.base64 ?? "")") {
            let b64 = (payload?.isImage == true) ? (payload?.base64 ?? "") : ""
            if !b64.isEmpty {
                decodedImage = await Task.detached(priority: .utility) {
                    guard let data = Data(base64Encoded: b64) else { return nil }
                    return UIImage(data: data)
                }.value
            } else {
                decodedImage = nil
            }

            if rawText.isEmpty {
                formattedPrettyText = nil
                return
            }
            let textCopy = rawText
            let pretty = await Task.detached(priority: .utility) {
                LCDebugFormatting.prettyPrintedJSON(from: textCopy)
            }.value
            formattedPrettyText = pretty
        }
    }

    private func displayBodyText(rawText: String) -> String {
        switch mode {
        case .pretty:
            return formattedPrettyText ?? (rawText.isEmpty ? (payload?.hexPreview ?? "") : rawText)
        case .raw:
            return rawText.isEmpty ? (payload?.hexPreview ?? "") : rawText
        case .hex:
            if let hex = payload?.hexPreview, !hex.isEmpty {
                return hex
            }
            if let b64 = payload?.base64, !b64.isEmpty, let data = Data(base64Encoded: b64) {
                return LCDebugFormatting.formatHexDump(data: data)
            }
            if let data = rawText.data(using: .utf8) {
                return LCDebugFormatting.formatHexDump(data: data)
            }
            return ""
        }
    }

    private func filteredDisplayLines(_ text: String) -> String {
        let q = bodySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return text }
        let matched = text.components(separatedBy: .newlines).filter {
            $0.localizedCaseInsensitiveContains(q)
        }
        return matched.isEmpty ? "No lines matching \"\(q)\"" : matched.joined(separator: "\n")
    }
}


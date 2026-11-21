//
//  LCDebugStudioManager.swift
//  LiveContainerSwiftUI
//
//  Observable per-domain stores & localhost/LAN SSE client communicating with
//  LCDebugAgent inside the running guest app.
//

import Foundation
import Observation
import SwiftUI

// MARK: - Isolated Per-Domain Observable Stores

@MainActor
@Observable
final class LCDebugTelemetryStore {
    var pid: Int = 0
    var localPort: Int = 0
    var lanPort: Int = 0
    var isMacLANEnabled: Bool = UserDefaults.lcShared().bool(forKey: "LCDebugLANEnabled")
    var lanIP: String = ""
    var authToken: String = ""
    var cpuPercent: Double = 0
    var memoryMB: Double = 0
    var fps: Int = 0
    var threadCount: Int = 0
    var isJIT: Bool = false
    var isXRayEnabled: Bool = false
    var isTapInspectEnabled: Bool = false
    var isNotificationMonitorEnabled: Bool = false
    var networkPaused: Bool = false

    var macLANURLString: String? {
        guard isMacLANEnabled, !lanIP.isEmpty, lanPort > 0 else { return nil }
        if !authToken.isEmpty {
            return "http://\(lanIP):\(lanPort)?token=\(authToken)"
        }
        return "http://\(lanIP):\(lanPort)"
    }
}

@MainActor
@Observable
final class LCDebugConsoleStore {
    var logs: [LCDebugLogEntry] = []
    var filteredLogs: [LCDebugLogEntry] = []
    var searchQuery: String = "" {
        didSet { recomputeFilteredLogs() }
    }
    var streamFilter: LCDebugLogStreamFilter = .all {
        didSet { recomputeFilteredLogs() }
    }
    var isPaused: Bool = false
    var autoScroll: Bool = true
    var selectedLog: LCDebugLogEntry? = nil

    private(set) var totalCount: Int = 0
    private(set) var errorCount: Int = 0

    func replaceAll(_ entries: [LCDebugLogEntry]) {
        logs = entries
        recomputeAllDerived()
    }

    func appendBatch(_ incoming: [LCDebugLogEntry]) {
        guard !incoming.isEmpty, !isPaused else { return }
        logs.append(contentsOf: incoming)
        if logs.count > 2000 {
            logs.removeFirst(logs.count - 2000)
        }
        recomputeAllDerived()
    }

    func clear() {
        logs.removeAll()
        recomputeAllDerived()
    }

    private func recomputeAllDerived() {
        totalCount = logs.count
        var errs = 0
        for item in logs where item.isErrorLike { errs += 1 }
        errorCount = errs
        recomputeFilteredLogs()
    }

    private func recomputeFilteredLogs() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredLogs = logs.filter { entry in
            switch streamFilter {
            case .all: break
            case .stdio:
                guard entry.stream == "stdout" || entry.stream == "stderr" else { return false }
            case .nslog:
                guard entry.stream == "nslog" else { return false }
            case .oslog:
                guard entry.stream == "oslog" else { return false }
            case .webview:
                guard entry.stream == "webview" else { return false }
            case .errors:
                guard entry.isErrorLike else { return false }
            }
            guard !q.isEmpty else { return true }
            return entry.text.localizedCaseInsensitiveContains(q)
                || entry.stream.localizedCaseInsensitiveContains(q)
                || (entry.subsystem?.localizedCaseInsensitiveContains(q) ?? false)
                || (entry.category?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

@MainActor
@Observable
final class LCDebugNetworkStore {
    var transactions: [LCDebugNetworkEntry] = []
    var filteredTransactions: [LCDebugNetworkEntry] = []
    var availableHosts: [String] = []

    var searchQuery: String = "" {
        didSet { recomputeFiltered() }
    }
    var statusFilter: LCDebugNetworkStatusFilter = .all {
        didSet { recomputeFiltered() }
    }
    var typeFilter: LCDebugNetworkTypeFilter = .all {
        didSet { recomputeFiltered() }
    }
    var methodFilter: String = "ALL" {
        didSet { recomputeFiltered() }
    }
    var hostFilter: String = "ALL" {
        didSet { recomputeFiltered() }
    }

    var settings: LCDebugNetworkSettings = .default
    var selectedTransaction: LCDebugNetworkEntry? = nil
    var replayTarget: LCDebugNetworkReplayTarget? = nil
    var showSettingsSheet: Bool = false

    private(set) var totalCount: Int = 0
    private(set) var totalBytes: Int = 0
    private(set) var errorCount: Int = 0
    private(set) var inFlightCount: Int = 0
    private(set) var averageDurationMs: Int = 0

    func replaceAll(_ list: [LCDebugNetworkEntry]) {
        transactions = list
        recomputeAllDerived()
    }

    func applyUpserts(_ updates: [LCDebugNetworkEntry]) {
        guard !updates.isEmpty else { return }
        var indexById: [String: Int] = Dictionary(minimumCapacity: transactions.count)
        for (idx, item) in transactions.enumerated() {
            indexById[item.id] = idx
        }
        for tx in updates {
            if let existingIdx = indexById[tx.id] {
                transactions[existingIdx] = tx
            } else {
                transactions.insert(tx, at: 0)
                // Re-sync indices only when inserting at front
                indexById.removeAll(keepingCapacity: true)
                for (i, item) in transactions.enumerated() {
                    indexById[item.id] = i
                }
            }
        }
        let maxKeep = max(100, settings.maxTransactions)
        if transactions.count > maxKeep {
            transactions.removeLast(transactions.count - maxKeep)
        }
        if let currentSel = selectedTransaction,
           let refreshed = transactions.first(where: { $0.id == currentSel.id }) {
            selectedTransaction = refreshed
        }
        recomputeAllDerived()
    }

    func clearAll() {
        transactions.removeAll()
        selectedTransaction = nil
        recomputeAllDerived()
    }

    func clearFilteredOnly() {
        let removeIDs = Set(filteredTransactions.map(\.id))
        transactions.removeAll { removeIDs.contains($0.id) }
        if let sel = selectedTransaction, removeIDs.contains(sel.id) {
            selectedTransaction = nil
        }
        recomputeAllDerived()
    }

    func resetFilters() {
        searchQuery = ""
        statusFilter = .all
        typeFilter = .all
        methodFilter = "ALL"
        hostFilter = "ALL"
    }

    private func recomputeAllDerived() {
        var hosts = Set<String>()
        var bytesSum = 0
        var errSum = 0
        var liveSum = 0
        var durSum = 0
        var durCount = 0

        for tx in transactions {
            let h = tx.resolvedHost
            if !h.isEmpty { hosts.insert(h) }
            bytesSum += tx.effectiveByteCount
            if tx.isInFlight { liveSum += 1 }
            if tx.isFailure { errSum += 1 }
            if !tx.isInFlight && tx.durationMs > 0 {
                durSum += tx.durationMs
                durCount += 1
            }
        }

        totalCount = transactions.count
        availableHosts = hosts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        totalBytes = bytesSum
        errorCount = errSum
        inFlightCount = liveSum
        averageDurationMs = durCount > 0 ? (durSum / durCount) : 0
        if hostFilter != "ALL" && !hosts.contains(hostFilter) {
            hostFilter = "ALL"
        }
        recomputeFiltered()
    }

    private func recomputeFiltered() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredTransactions = transactions.filter { tx in
            switch statusFilter {
            case .all: break
            case .inFlight:
                guard tx.isInFlight else { return false }
            case .ok2xx:
                guard (200...299).contains(tx.statusCode) else { return false }
            case .redir3xx:
                guard (300...399).contains(tx.statusCode) else { return false }
            case .errors:
                guard tx.isFailure else { return false }
            }

            switch typeFilter {
            case .all: break
            case .urlsession:
                guard tx.source == nil || tx.source == "urlsession" || tx.source == "urlconnection" else { return false }
            case .graphql:
                guard tx.isGraphQL == true else { return false }
            case .webview:
                guard tx.source == "webview" else { return false }
            case .websocket:
                guard tx.source == "websocket" else { return false }
            case .json:
                guard tx.mimeType.localizedCaseInsensitiveContains("json") else { return false }
            case .media:
                let m = tx.mimeType.lowercased()
                guard m.hasPrefix("image/") || m.hasPrefix("audio/") || m.hasPrefix("video/") else { return false }
            }

            if methodFilter != "ALL" && tx.method.uppercased() != methodFilter {
                return false
            }
            if hostFilter != "ALL" && tx.resolvedHost != hostFilter {
                return false
            }

            guard !q.isEmpty else { return true }
            return tx.url.localizedCaseInsensitiveContains(q)
                || tx.method.localizedCaseInsensitiveContains(q)
                || tx.displaySource.localizedCaseInsensitiveContains(q)
                || tx.mimeType.localizedCaseInsensitiveContains(q)
                || (tx.graphQLOperation?.localizedCaseInsensitiveContains(q) ?? false)
                || "\(tx.statusCode)".contains(q)
        }
    }
}

@MainActor
@Observable
final class LCDebugInspectorStore {
    var uiEvents: [LCDebugUIEventEntry] = []
    var filteredUIEvents: [LCDebugUIEventEntry] = []
    var eventSearch: String = "" {
        didSet { recomputeFilteredEvents() }
    }
    var eventKindFilter: LCDebugUIEventKindFilter = .all {
        didSet { recomputeFilteredEvents() }
    }
    var selectedEvent: LCDebugUIEventEntry? = nil
    private(set) var totalEventCount: Int = 0

    var hierarchyWindows: [LCDebugHierarchyWindow] = []
    var hierarchyText: String = ""
    var isLoadingHierarchy: Bool = false

    var dylibs: [LCDebugDylibEntry] = []
    var objcClasses: [String] = []
    var selectedClassDetail: LCDebugClassDetail? = nil
    var sandboxSummary: LCDebugSandboxSummary? = nil
    var fridaInfo: LCDebugFridaInfo? = nil

    var selectedView: LCDebugSelectedView? = nil
    var showSelectedViewSheet: Bool = false

    func replaceEvents(_ list: [LCDebugUIEventEntry]) {
        uiEvents = list
        recomputeFilteredEvents()
    }

    func prependEvents(_ incoming: [LCDebugUIEventEntry]) {
        guard !incoming.isEmpty else { return }
        uiEvents.insert(contentsOf: incoming.reversed(), at: 0)
        if uiEvents.count > 500 {
            uiEvents.removeLast(uiEvents.count - 500)
        }
        recomputeFilteredEvents()
    }

    func clearEvents() {
        uiEvents.removeAll()
        recomputeFilteredEvents()
    }

    private func recomputeFilteredEvents() {
        totalEventCount = uiEvents.count
        let q = eventSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredUIEvents = uiEvents.filter { ev in
            if eventKindFilter != .all && ev.kind.lowercased() != eventKindFilter.rawValue.lowercased() {
                if !(eventKindFilter == .notification && ev.kind.lowercased() == "notification") {
                    return false
                }
            }
            guard !q.isEmpty else { return true }
            return ev.title.localizedCaseInsensitiveContains(q)
                || ev.detail.localizedCaseInsensitiveContains(q)
                || ev.kind.localizedCaseInsensitiveContains(q)
                || ev.viewController.localizedCaseInsensitiveContains(q)
        }
    }
}

// MARK: - Main Connection & Coordination Controller

private struct LCDebugSessionFilePayload: Decodable, Sendable {
    let pid: Int
    let localPort: Int
    let authToken: String?
}

private enum LCDecodedSSEMessage: Sendable {
    case telemetry(LCDebugStatusSnapshot)
    case log(LCDebugLogEntry)
    case network(LCDebugNetworkEntry)
    case uiEvent(LCDebugUIEventEntry)
    case tap(LCDebugSelectedView)
}

@MainActor
@Observable
final class LCDebugStudioManager {
    var telemetryStore = LCDebugTelemetryStore()
    var consoleStore = LCDebugConsoleStore()
    var networkStore = LCDebugNetworkStore()
    var inspectorStore = LCDebugInspectorStore()

    var isConnected: Bool = false
    var isConnecting: Bool = false
    var connectionError: String? = nil
    var jitStatusBanner: String? = nil

    @ObservationIgnored private var expectedPID: Int32 = 0
    @ObservationIgnored private var lastStatusSelectedView: LCDebugSelectedView? = nil
    @ObservationIgnored private nonisolated(unsafe) var connectionTask: Task<Void, Never>? = nil
    @ObservationIgnored private nonisolated(unsafe) var sseTask: Task<Void, Never>? = nil
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let decoder = JSONDecoder()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
    }

    private var baseURL: URL? {
        guard telemetryStore.localPort > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(telemetryStore.localPort)")
    }

    deinit {
        connectionTask?.cancel()
        sseTask?.cancel()
        session.invalidateAndCancel()
    }

    static func clearStaleSessionMetadata(forPID pid: Int32 = 0) {
        if let shared = UserDefaults.lcShared() {
            shared.removeObject(forKey: "LCDebugActiveSession")
            shared.removeObject(forKey: "LCDebugPendingBundleID")
            shared.removeObject(forKey: "LCDebugPendingRelativePath")
        }
        if pid > 0, let fileURL = sessionFileURL(forPID: Int(pid)) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func sessionFileURL(forPID pid: Int) -> URL? {
        guard pid > 0, let groupURL = LCSharedUtils.appGroupPath() else { return nil }
        return groupURL
            .appendingPathComponent("Library/Caches/LCDebugSessions", isDirectory: true)
            .appendingPathComponent("pid-\(pid).json")
    }

    private func discoverSession(expectedPID: Int32) -> (pid: Int, port: Int, token: String)? {
        if expectedPID > 0,
           let fileURL = Self.sessionFileURL(forPID: Int(expectedPID)),
           let data = try? Data(contentsOf: fileURL),
           let payload = try? decoder.decode(LCDebugSessionFilePayload.self, from: data),
           payload.pid == Int(expectedPID),
           payload.localPort > 0 {
            return (payload.pid, payload.localPort, payload.authToken ?? "")
        }

        if let info = UserDefaults.lcShared().dictionary(forKey: "LCDebugActiveSession"),
           let port = info["localPort"] as? Int, port > 0 {
            let sessionPID = info["pid"] as? Int ?? 0
            let token = info["authToken"] as? String ?? ""
            if expectedPID > 0 {
                if sessionPID == Int(expectedPID) {
                    return (sessionPID, port, token)
                }
            } else if sessionPID > 0 {
                return (sessionPID, port, token)
            }
        }
        return nil
    }

    func startConnecting(expectedPID: Int32) {
        disconnect(clearPersistedSession: false)
        self.expectedPID = expectedPID
        self.connectionError = nil
        self.isConnecting = true
        if expectedPID > 0 {
            telemetryStore.pid = Int(expectedPID)
        }

        connectionTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(25)
            while !Task.isCancelled && Date() < deadline {
                guard let self else { return }
                if let discovered = self.discoverSession(expectedPID: expectedPID) {
                    self.telemetryStore.localPort = discovered.port
                    self.telemetryStore.pid = discovered.pid
                    self.telemetryStore.authToken = discovered.token
                    if await self.bootstrapConnection() {
                        self.isConnecting = false
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled, !self.isConnected else { return }
            self.isConnecting = false
            self.connectionError = "Timed out connecting to Debug Agent (PID \(expectedPID)). Tap Reconnect to retry."
        }
    }

    func reconnect() {
        startConnecting(expectedPID: expectedPID)
    }

    func disconnect(clearPersistedSession: Bool = true) {
        connectionTask?.cancel()
        connectionTask = nil
        sseTask?.cancel()
        sseTask = nil
        isConnected = false
        isConnecting = false
        if clearPersistedSession {
            Self.clearStaleSessionMetadata(forPID: expectedPID > 0 ? expectedPID : Int32(telemetryStore.pid))
        }
    }

    private func bootstrapConnection() async -> Bool {
        guard let base = baseURL else { return false }
        guard let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) else {
            return false
        }
        if expectedPID > 0, let actualPID = status.pid, actualPID != Int(expectedPID) {
            return false
        }
        apply(status: status)
        isConnected = true
        connectionError = nil
        await fetchInitialCollections(base: base)
        await loadNetworkSettings()
        startSSEStream()
        return true
    }

    func refreshStatusAndSnapshots() async {
        guard let base = baseURL else { return }
        if let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) {
            apply(status: status)
            isConnected = true
            connectionError = nil
        }
        await fetchInitialCollections(base: base)
    }

    private func fetchInitialCollections(base: URL) async {
        async let logsFetch: [LCDebugLogEntry]? = fetchJSON(url: base.appendingPathComponent("api/logs"))
        async let netFetch: [LCDebugNetworkEntry]? = fetchJSON(url: base.appendingPathComponent("api/network"))
        async let evFetch: [LCDebugUIEventEntry]? = fetchJSON(url: base.appendingPathComponent("api/events"))

        if let initialLogs = await logsFetch {
            consoleStore.replaceAll(initialLogs)
        }
        if let initialNet = await netFetch {
            networkStore.replaceAll(initialNet)
        }
        if let initialEvents = await evFetch {
            inspectorStore.replaceEvents(initialEvents)
        }
    }

    private func startSSEStream() {
        sseTask?.cancel()
        let session = self.session

        sseTask = Task.detached(priority: .utility) { [weak self] in
            let bgDecoder = JSONDecoder()
            while !Task.isCancelled {
                guard let req = await self?.makeStreamRequest() else {
                    break
                }

                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw URLError(.badServerResponse)
                    }

                    await MainActor.run { [weak self] in
                        self?.isConnected = true
                        self?.connectionError = nil
                    }

                    var currentEvent = "message"
                    var dataLines: [String] = []
                    var lineBuffer: [UInt8] = []
                    lineBuffer.reserveCapacity(512)
                    var pendingBatch: [LCDecodedSSEMessage] = []
                    pendingBatch.reserveCapacity(32)
                    var lastFlushTime = CFAbsoluteTimeGetCurrent()

                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            if lineBuffer.last == 0x0D {
                                lineBuffer.removeLast()
                            }
                            let line = String(decoding: lineBuffer, as: UTF8.self)
                            lineBuffer.removeAll(keepingCapacity: true)

                            if line.isEmpty {
                                if !dataLines.isEmpty {
                                    let joined = dataLines.joined(separator: "\n")
                                    if let decoded = Self.decodeSSEEvent(name: currentEvent, jsonString: joined, decoder: bgDecoder) {
                                        pendingBatch.append(decoded)
                                    }
                                }
                                currentEvent = "message"
                                dataLines.removeAll(keepingCapacity: true)

                                let now = CFAbsoluteTimeGetCurrent()
                                let shouldFlushNow = pendingBatch.count >= 16 || (now - lastFlushTime) >= 0.05 || pendingBatch.last.map({
                                    if case .telemetry = $0 { return true }
                                    if case .tap = $0 { return true }
                                    return false
                                }) == true
                                if shouldFlushNow && !pendingBatch.isEmpty {
                                    let batchToApply = pendingBatch
                                    pendingBatch.removeAll(keepingCapacity: true)
                                    lastFlushTime = now
                                    await MainActor.run { [weak self] in
                                        self?.applySSEBatch(batchToApply)
                                    }
                                }
                            } else if line.hasPrefix("event:") {
                                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                var payload = String(line.dropFirst(5))
                                if payload.hasPrefix(" ") {
                                    payload.removeFirst()
                                }
                                dataLines.append(payload)
                            }
                        } else {
                            lineBuffer.append(byte)
                        }
                    }

                    if !pendingBatch.isEmpty {
                        let remaining = pendingBatch
                        await MainActor.run { [weak self] in
                            self?.applySSEBatch(remaining)
                        }
                    }

                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.isConnected = false
                            self?.connectionError = "Live stream closed. Reconnecting…"
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    await MainActor.run { [weak self] in
                        self?.isConnected = false
                        self?.connectionError = "Live stream disconnected. Reconnecting…"
                    }
                }

                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(1))
                let stillAlive = await self?.refreshForReconnect() ?? false
                if !stillAlive {
                    break
                }
            }
        }
    }

    private func makeStreamRequest() -> URLRequest? {
        guard let base = baseURL else { return nil }
        var req = authorizedRequest(url: base.appendingPathComponent("api/stream"))
        req.timeoutInterval = 3600
        return req
    }

    private func refreshForReconnect() async -> Bool {
        if expectedPID > 0 && kill(expectedPID, 0) != 0 && errno == ESRCH {
            isConnected = false
            connectionError = "Guest process (PID \(expectedPID)) exited."
            return false
        }
        await refreshStatusAndSnapshots()
        return baseURL != nil
    }

    private nonisolated static func decodeSSEEvent(name: String, jsonString: String, decoder: JSONDecoder) -> LCDecodedSSEMessage? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        switch name {
        case "telemetry":
            return (try? decoder.decode(LCDebugStatusSnapshot.self, from: data)).map(LCDecodedSSEMessage.telemetry)
        case "log":
            return (try? decoder.decode(LCDebugLogEntry.self, from: data)).map(LCDecodedSSEMessage.log)
        case "network":
            return (try? decoder.decode(LCDebugNetworkEntry.self, from: data)).map(LCDecodedSSEMessage.network)
        case "uievent":
            return (try? decoder.decode(LCDebugUIEventEntry.self, from: data)).map(LCDecodedSSEMessage.uiEvent)
        case "tap":
            return (try? decoder.decode(LCDebugSelectedView.self, from: data)).map(LCDecodedSSEMessage.tap)
        default:
            return nil
        }
    }

    private func applySSEBatch(_ batch: [LCDecodedSSEMessage]) {
        var newLogs: [LCDebugLogEntry] = []
        var newNets: [LCDebugNetworkEntry] = []
        var newEvents: [LCDebugUIEventEntry] = []

        for msg in batch {
            switch msg {
            case .telemetry(let status):
                apply(status: status)
            case .log(let entry):
                newLogs.append(entry)
            case .network(let entry):
                newNets.append(entry)
            case .uiEvent(let entry):
                newEvents.append(entry)
            case .tap(let view):
                lastStatusSelectedView = view
                inspectorStore.selectedView = view
            }
        }

        consoleStore.appendBatch(newLogs)
        networkStore.applyUpserts(newNets)
        inspectorStore.prependEvents(newEvents)
    }

    private func apply(status: LCDebugStatusSnapshot) {
        if let p = status.pid { telemetryStore.pid = p }
        if let lp = status.localPort { telemetryStore.localPort = lp }
        if let lanP = status.lanPort { telemetryStore.lanPort = lanP }
        if let lanEn = status.lanEnabled { telemetryStore.isMacLANEnabled = lanEn }
        if let ip = status.lanIP { telemetryStore.lanIP = ip }
        if let token = status.authToken, !token.isEmpty { telemetryStore.authToken = token }
        if let cpu = status.cpuPercent { telemetryStore.cpuPercent = cpu }
        if let mem = status.memoryMB { telemetryStore.memoryMB = mem }
        if let f = status.fps { telemetryStore.fps = f }
        if let tc = status.threadCount { telemetryStore.threadCount = tc }
        if let jit = status.isJIT { telemetryStore.isJIT = jit }
        if let xr = status.xrayEnabled { telemetryStore.isXRayEnabled = xr }
        if let ti = status.tapInspectEnabled { telemetryStore.isTapInspectEnabled = ti }
        if let nm = status.notificationMonitorEnabled { telemetryStore.isNotificationMonitorEnabled = nm }
        if let np = status.networkPaused {
            if telemetryStore.networkPaused != np {
                telemetryStore.networkPaused = np
            }
            if networkStore.settings.paused != np {
                networkStore.settings.paused = np
            }
        }
        if let nr = status.networkRedactSensitive, networkStore.settings.redactSensitive != nr {
            networkStore.settings.redactSensitive = nr
        }
        if let sv = status.selectedView, sv != lastStatusSelectedView {
            lastStatusSelectedView = sv
            inspectorStore.selectedView = sv
        }
    }

    // MARK: - Actions & Introspection API

    func setMacLAN(enabled: Bool) async {
        telemetryStore.isMacLANEnabled = enabled
        UserDefaults.lcShared().set(enabled, forKey: "LCDebugLANEnabled")
        await postAction(["action": "set_lan", "enabled": enabled])
        await refreshStatusOnly()
    }

    func toggleXRay() async {
        await postAction(["action": "toggle_xray"])
        await refreshStatusOnly()
    }

    func toggleTapInspect() async {
        await postAction(["action": "toggle_tap_inspect"])
        await refreshStatusOnly()
    }

    func toggleNotificationMonitor() async {
        await postAction(["action": "toggle_notifications"])
        await refreshStatusOnly()
    }

    func simulateMemoryWarning() async {
        await postAction(["action": "memory_warning"])
    }

    func clearLogs() async {
        consoleStore.clear()
        await postAction(["action": "clear_logs"])
    }

    func clearNetwork(filteredOnly: Bool = false) async {
        if filteredOnly {
            networkStore.clearFilteredOnly()
        } else {
            networkStore.clearAll()
            await postAction(["action": "clear_network"])
        }
    }

    func clearUIEvents() async {
        inspectorStore.clearEvents()
        await postAction(["action": "clear_events"])
    }

    func refreshStatusOnly() async {
        guard let base = baseURL else { return }
        if let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) {
            apply(status: status)
        }
    }

    func setNetworkPaused(_ paused: Bool) async {
        telemetryStore.networkPaused = paused
        networkStore.settings.paused = paused
        await postAction(["action": "set_network_paused", "paused": paused])
        await refreshStatusOnly()
    }

    func setNetworkRedactSensitive(_ redact: Bool) async {
        networkStore.settings.redactSensitive = redact
        await postAction([
            "action": "set_network_settings",
            "redactSensitive": redact,
            "redactExports": redact
        ])
        await refreshStatusOnly()
    }

    func loadNetworkSettings() async {
        guard let base = baseURL else { return }
        if let cfg: LCDebugNetworkSettings = await fetchJSON(url: base.appendingPathComponent("api/network/settings")) {
            networkStore.settings = cfg
            telemetryStore.networkPaused = cfg.paused
        }
    }

    func updateNetworkSettings(_ settings: LCDebugNetworkSettings) async {
        networkStore.settings = settings
        telemetryStore.networkPaused = settings.paused
        let dict: [String: Any] = [
            "action": "set_network_settings",
            "paused": settings.paused,
            "cacheMediaBodies": settings.cacheMediaBodies,
            "cacheLimitMB": settings.cacheLimitMB,
            "maxTransactions": settings.maxTransactions,
            "redactSensitive": settings.redactSensitive,
            "redactExports": settings.redactSensitive,
            "excludedHosts": settings.excludedHosts
        ]
        await postAction(dict)
        await loadNetworkSettings()
    }

    func excludeHost(_ host: String) async {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        await postAction(["action": "exclude_host", "host": trimmed])
        await loadNetworkSettings()
    }

    func removeExcludedHost(_ host: String) async {
        await postAction(["action": "remove_excluded_host", "host": host])
        await loadNetworkSettings()
    }

    func clearExcludedHosts() async {
        await postAction(["action": "clear_excluded_hosts"])
        await loadNetworkSettings()
    }

    func fetchNetworkBody(id: String, part: String, redact: Bool) async -> LCDebugNetworkBodyPayload? {
        guard let base = baseURL else { return nil }
        var comp = URLComponents(url: base.appendingPathComponent("api/network/body"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "part", value: part),
            URLQueryItem(name: "redact", value: redact ? "1" : "0")
        ]
        guard let url = comp?.url else { return nil }
        return await fetchJSON(url: url)
    }

    func exportHARFileURL(redact: Bool) async -> URL? {
        guard let base = baseURL else { return nil }
        var comp = URLComponents(url: base.appendingPathComponent("api/network/har"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "redact", value: redact ? "1" : "0")]
        guard let url = comp?.url else { return nil }
        do {
            let (data, response) = try await session.data(for: authorizedRequest(url: url))
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveContainer-Network-\(Int(Date().timeIntervalSince1970)).har")
            try data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    func exportLogsFileURL() -> URL? {
        let content = consoleStore.filteredLogs.map { entry in
            let stamp = LCDebugFormatting.formatTimestamp(entry.timestamp)
            let sub = (entry.subsystem?.isEmpty == false) ? ":\(entry.subsystem!)" : ""
            return "\(stamp.isEmpty ? "" : "[\(stamp)] ")[\(entry.stream.uppercased())\(sub)] \(entry.text)"
        }.joined(separator: "\n")
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveContainer-Logs-\(Int(Date().timeIntervalSince1970)).log")
        guard let data = content.data(using: .utf8) else { return nil }
        do {
            try data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    func replayTransaction(_ target: LCDebugNetworkReplayTarget) async -> LCDebugNetworkReplayResult {
        guard let base = baseURL else {
            return LCDebugNetworkReplayResult(ok: false, statusCode: nil, durationMs: nil, bytes: nil, error: "Not connected")
        }
        var payload: [String: Any] = [
            "method": target.method,
            "url": target.url,
            "headers": target.headers
        ]
        if let txId = target.transactionId {
            payload["transactionId"] = txId
        }
        if !target.body.isEmpty {
            payload["body"] = target.body
        }
        var req = authorizedRequest(url: base.appendingPathComponent("api/network/replay"))
        req.httpMethod = "POST"
        req.timeoutInterval = 35
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await session.data(for: req)
            return try decoder.decode(LCDebugNetworkReplayResult.self, from: data)
        } catch {
            return LCDebugNetworkReplayResult(ok: false, statusCode: nil, durationMs: nil, bytes: nil, error: error.localizedDescription)
        }
    }

    func openReplayComposer(for entry: LCDebugNetworkEntry) {
        Task {
            var initialBody = entry.requestBodyPreview
            if entry.hasRequestBody == true {
                if let full = await fetchNetworkBody(id: entry.id, part: "request", redact: false), !full.text.isEmpty {
                    initialBody = full.text
                }
            }
            networkStore.replayTarget = LCDebugNetworkReplayTarget(
                id: UUID().uuidString,
                transactionId: entry.id,
                method: entry.method,
                url: entry.url,
                headers: entry.requestHeaders,
                body: initialBody
            )
        }
    }

    func loadEvents() async {
        guard let base = baseURL else { return }
        if let list: [LCDebugUIEventEntry] = await fetchJSON(url: base.appendingPathComponent("api/events")) {
            inspectorStore.replaceEvents(list)
        }
    }

    func loadHierarchy() async {
        guard let base = baseURL else { return }
        inspectorStore.isLoadingHierarchy = true
        defer { inspectorStore.isLoadingHierarchy = false }
        do {
            let (data, _) = try await session.data(for: authorizedRequest(url: base.appendingPathComponent("api/hierarchy")))
            let parsed = await Task.detached(priority: .userInitiated) {
                LCDebugFormatting.parseHierarchyWindows(from: data)
            }.value
            inspectorStore.hierarchyWindows = parsed.windows
            inspectorStore.hierarchyText = parsed.prettyJSON
        } catch {
            inspectorStore.hierarchyText = "Failed to capture view hierarchy: \(error.localizedDescription)"
        }
    }

    func loadDylibs() async {
        guard let base = baseURL else { return }
        if let list: [LCDebugDylibEntry] = await fetchJSON(url: base.appendingPathComponent("api/dylibs")) {
            inspectorStore.dylibs = list
        }
    }

    func searchObjCClasses(query: String) async {
        guard let base = baseURL else { return }
        var comp = URLComponents(url: base.appendingPathComponent("api/classes"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comp?.url else { return }
        if let matches: [String] = await fetchJSON(url: url) {
            inspectorStore.objcClasses = matches
        }
    }

    func inspectObjCClass(_ className: String) async {
        guard let base = baseURL else { return }
        var comp = URLComponents(url: base.appendingPathComponent("api/classes"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "class", value: className)]
        guard let url = comp?.url else { return }
        if let detail: LCDebugClassDetail = await fetchJSON(url: url) {
            inspectorStore.selectedClassDetail = detail
        }
    }

    func loadSandbox() async {
        guard let base = baseURL else { return }
        if let summary: LCDebugSandboxSummary = await fetchJSON(url: base.appendingPathComponent("api/sandbox")) {
            inspectorStore.sandboxSummary = summary
        }
    }

    func loadFridaInfo() async {
        guard let base = baseURL else { return }
        if let info: LCDebugFridaInfo = await fetchJSON(url: base.appendingPathComponent("api/frida")) {
            inspectorStore.fridaInfo = info
        }
    }

    func attachJIT(for appModel: LCAppModel) async {
        guard telemetryStore.pid > 0 else {
            jitStatusBanner = "Waiting for guest process PID…"
            return
        }
        let pid = telemetryStore.pid
        let enabler = JITEnablerType(rawValue: UserDefaults.lcShared().integer(forKey: "LCJITEnablerType"))
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let script = appModel.jitLaunchScriptJs?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        if enabler == .StosDebug {
            let encoded = script.map { "&script=\($0)" } ?? ""
            let safeName = appModel.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appModel.displayName
            if let url = URL(string: "stosdebug://enableJIT?bundleId=\(bundleId)&appName=\(safeName)&pid=\(pid)&forcePID=true\(encoded)") {
                await UIApplication.shared.open(url)
                jitStatusBanner = "Requested optional JIT via StosDebug for PID \(pid)."
            }
            return
        }
        if enabler == .StikJIT {
            let encoded = script.map { "&script-data=\($0)" } ?? ""
            if let url = URL(string: "stikjit://enable-jit?bundle-id=\(bundleId)&pid=\(pid)\(encoded)") {
                await UIApplication.shared.open(url)
                jitStatusBanner = "Requested optional JIT via StikDebug for PID \(pid)."
            }
            return
        }
        _ = await LCUtils.askForJIT(withScript: appModel.jitLaunchScriptJs, appName: appModel.displayName, classicMode: 0) { [weak self] msg in
            self?.jitStatusBanner = msg
        }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if !telemetryStore.authToken.isEmpty {
            req.setValue("Bearer \(telemetryStore.authToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func fetchJSON<T: Decodable>(url: URL) async -> T? {
        do {
            let (data, response) = try await session.data(for: authorizedRequest(url: url))
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func postAction(_ body: [String: Any]) async {
        guard let base = baseURL else { return }
        var req = authorizedRequest(url: base.appendingPathComponent("api/action"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }
}

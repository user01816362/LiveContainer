//
//  LCDebugStudioManager.swift
//  LiveContainerSwiftUI
//
//  Connects over localhost (and mirrors Mac LAN state) to LCDebugAgent inside
//  the running guest app via HTTP + Server-Sent Events (SSE).
//

import Foundation
import SwiftUI
import Combine

struct LCDebugLogEntry: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let timestamp: Double?
    let stream: String
    let level: String?
    let subsystem: String?
    let category: String?
    let text: String

    var effectiveLevel: String {
        if let level, !level.isEmpty { return level }
        if stream == "stderr" || stream == "crash" { return "error" }
        return "info"
    }

    var isErrorLike: Bool {
        stream == "stderr" || stream == "crash" || effectiveLevel == "error" || effectiveLevel == "fault"
    }
}

struct LCDebugNetworkEntry: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let timestamp: Double?
    let source: String?
    let method: String
    let url: String
    let statusCode: Int
    let mimeType: String
    let durationMs: Int
    let bytes: Int
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBodyPreview: String
    let responseBodyPreview: String
    let curl: String
    let error: String

    var displaySource: String {
        switch source?.lowercased() {
        case "webview": return "WebView"
        case "websocket": return "WebSocket"
        default: return "URLSession"
        }
    }
}

struct LCDebugUIEventEntry: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let timestamp: Double?
    let kind: String
    let title: String
    let detail: String
    let target: String
    let viewController: String
    let window: String
}

struct LCDebugSelectedView: Decodable, Hashable, Sendable {
    let viewClass: String
    let viewController: String
    let windowClass: String?
    let frame: String
    let bounds: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let alpha: Double
    let hidden: Bool
    let tag: Int
    let backgroundColor: String
    let subviewCount: Int
    let constraintsCount: Int?
    let isSwiftUI: Bool?
    let responderChain: [String]?

    enum CodingKeys: String, CodingKey {
        case viewClass = "class"
        case viewController
        case windowClass
        case frame
        case bounds
        case accessibilityIdentifier
        case accessibilityLabel
        case alpha
        case hidden
        case tag
        case backgroundColor
        case subviewCount
        case constraintsCount
        case isSwiftUI
        case responderChain
    }
}

struct LCDebugStatusSnapshot: Decodable, Sendable {
    let pid: Int?
    let bundleId: String?
    let localPort: Int?
    let lanPort: Int?
    let lanEnabled: Bool?
    let lanIP: String?
    let authToken: String?
    let cpuPercent: Double?
    let memoryMB: Double?
    let fps: Int?
    let threadCount: Int?
    let isJIT: Bool?
    let xrayEnabled: Bool?
    let tapInspectEnabled: Bool?
    let notificationMonitorEnabled: Bool?
    let selectedView: LCDebugSelectedView?
}

struct LCDebugDylibEntry: Identifiable, Decodable, Hashable, Sendable {
    var id: String { "\(index)-\(base)" }
    let index: Int
    let base: String
    let path: String
    let name: String
    let isSystem: Bool
}

struct LCDebugClassDetail: Decodable, Hashable, Sendable {
    let className: String
    let superclassName: String
    let image: String
    let methods: [String]
    let properties: [String]
    let ivars: [String]

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case superclassName = "superclass"
        case image
        case methods
        case properties
        case ivars
    }
}

struct LCDebugSandboxFile: Identifiable, Decodable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let type: String
}

struct LCDebugKeychainItem: Identifiable, Decodable, Hashable, Sendable {
    let id = UUID()
    let account: String
    let service: String
    let accessGroup: String

    enum CodingKeys: String, CodingKey {
        case account, service, accessGroup
    }
}

struct LCDebugSandboxSummary: Decodable, Sendable {
    let home: String
    let files: [LCDebugSandboxFile]
    let userDefaults: [String: String]
    let keychainItems: [LCDebugKeychainItem]

    enum CodingKeys: String, CodingKey {
        case home, files, userDefaults, keychainItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = (try? container.decode(String.self, forKey: .home)) ?? ""
        files = (try? container.decode([LCDebugSandboxFile].self, forKey: .files)) ?? []
        keychainItems = (try? container.decode([LCDebugKeychainItem].self, forKey: .keychainItems)) ?? []

        if let rawDict = try? container.decode([String: LCDebugAnyCodable].self, forKey: .userDefaults) {
            var coerced: [String: String] = [:]
            for (k, v) in rawDict {
                coerced[k] = v.stringSummary
            }
            userDefaults = coerced
        } else {
            userDefaults = [:]
        }
    }
}

private enum LCDebugAnyCodable: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else {
            self = .other
        }
    }

    var stringSummary: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.rounded() == n {
                return String(Int64(n))
            }
            return String(n)
        case .other: return "<Collection / Object>"
        }
    }
}

struct LCDebugFridaInfo: Decodable, Sendable {
    let pid: Int
    let bundleId: String
    let executablePath: String
    let bundlePath: String
    let isJIT: Bool
    let fridaGadgetLoaded: Bool
    let flexLoaded: Bool
    let fridaAttachCmd: String
    let fridaGadgetTip: String
    let lldbCmd: String
}

enum LCDebugInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case console = "Console"
    case network = "Network"
    case events = "UI & Events"
    case hierarchy = "Hierarchy"
    case dylibs = "Dylibs & ObjC"
    case sandbox = "Sandbox & Keys"
    case frida = "Frida / LLDB"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .console: return "terminal.fill"
        case .network: return "network"
        case .events: return "cursorarrow.click.2"
        case .hierarchy: return "square.3.layers.3d"
        case .dylibs: return "shippingbox.fill"
        case .sandbox: return "folder.fill"
        case .frida: return "ant.fill"
        }
    }
}

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
final class LCDebugStudioManager: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectionError: String? = nil
    @Published var pid: Int = 0
    @Published var localPort: Int = 0
    @Published var lanPort: Int = 0
    @Published var isMacLANEnabled = false
    @Published var lanIP: String = ""
    @Published var authToken: String = ""
    @Published var cpuPercent: Double = 0
    @Published var memoryMB: Double = 0
    @Published var fps: Int = 0
    @Published var threadCount: Int = 0
    @Published var isJIT = false
    @Published var isXRayEnabled = false
    @Published var isTapInspectEnabled = false
    @Published var isNotificationMonitorEnabled = false
    @Published var selectedView: LCDebugSelectedView? = nil

    @Published var logs: [LCDebugLogEntry] = []
    @Published var networkEntries: [LCDebugNetworkEntry] = []
    @Published var uiEvents: [LCDebugUIEventEntry] = []
    @Published var hierarchyText: String = ""
    @Published var dylibs: [LCDebugDylibEntry] = []
    @Published var objcClasses: [String] = []
    @Published var selectedClassDetail: LCDebugClassDetail? = nil
    @Published var sandboxSummary: LCDebugSandboxSummary? = nil
    @Published var fridaInfo: LCDebugFridaInfo? = nil
    @Published var jitStatusBanner: String? = nil

    private var expectedPID: Int32 = 0
    private var connectionTask: Task<Void, Never>? = nil
    private var sseTask: Task<Void, Never>? = nil
    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
        self.isMacLANEnabled = UserDefaults.lcShared().bool(forKey: "LCDebugLANEnabled")
    }

    var macLANURLString: String? {
        guard isMacLANEnabled, !lanIP.isEmpty, lanPort > 0 else { return nil }
        if !authToken.isEmpty {
            return "http://\(lanIP):\(lanPort)?token=\(authToken)"
        }
        return "http://\(lanIP):\(lanPort)"
    }

    private var baseURL: URL? {
        guard localPort > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(localPort)")
    }

    deinit {
        connectionTask?.cancel()
        sseTask?.cancel()
        session.invalidateAndCancel()
    }

    static func clearStaleSessionMetadata(forPID pid: Int32 = 0) {
        let shared = UserDefaults.lcShared()
        shared.removeObject(forKey: "LCDebugActiveSession")
        shared.removeObject(forKey: "LCDebugPendingBundleID")
        shared.removeObject(forKey: "LCDebugPendingRelativePath")
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
            self.pid = Int(expectedPID)
        }

        connectionTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(25)
            while !Task.isCancelled && Date() < deadline {
                guard let self else { return }
                if let discovered = self.discoverSession(expectedPID: expectedPID) {
                    self.localPort = discovered.port
                    self.pid = discovered.pid
                    self.authToken = discovered.token
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
            Self.clearStaleSessionMetadata(forPID: expectedPID > 0 ? expectedPID : Int32(pid))
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
            self.logs = initialLogs
        }
        if let initialNet = await netFetch {
            self.networkEntries = initialNet
        }
        if let initialEvents = await evFetch {
            self.uiEvents = initialEvents
        }
    }

    private func startSSEStream() {
        sseTask?.cancel()
        let session = self.session

        // Run raw SSE byte reading + JSON decoding off MainActor and batch-flush updates
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

                    // Read raw bytes instead of `bytes.lines` because Swift's AsyncLineSequence
                    // strips blank lines (\n\n) that delimit SSE frames.
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A { // '\n'
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

                    // Clean EOF from server -> mark disconnected so reconnect triggers cleanly
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
                selectedView = view
            }
        }

        if !newLogs.isEmpty {
            logs.append(contentsOf: newLogs)
            if logs.count > 2000 {
                logs.removeFirst(logs.count - 2000)
            }
        }
        if !newNets.isEmpty {
            networkEntries.insert(contentsOf: newNets.reversed(), at: 0)
            if networkEntries.count > 500 {
                networkEntries.removeLast(networkEntries.count - 500)
            }
        }
        if !newEvents.isEmpty {
            uiEvents.insert(contentsOf: newEvents.reversed(), at: 0)
            if uiEvents.count > 500 {
                uiEvents.removeLast(uiEvents.count - 500)
            }
        }
    }

    private func apply(status: LCDebugStatusSnapshot) {
        if let p = status.pid { pid = p }
        if let lp = status.localPort { localPort = lp }
        if let lanP = status.lanPort { lanPort = lanP }
        if let lanEn = status.lanEnabled { isMacLANEnabled = lanEn }
        if let ip = status.lanIP { lanIP = ip }
        if let token = status.authToken, !token.isEmpty { authToken = token }
        if let cpu = status.cpuPercent { cpuPercent = cpu }
        if let mem = status.memoryMB { memoryMB = mem }
        if let f = status.fps { fps = f }
        if let tc = status.threadCount { threadCount = tc }
        if let jit = status.isJIT { isJIT = jit }
        if let xr = status.xrayEnabled { isXRayEnabled = xr }
        if let ti = status.tapInspectEnabled { isTapInspectEnabled = ti }
        if let nm = status.notificationMonitorEnabled { isNotificationMonitorEnabled = nm }
        if let sv = status.selectedView { selectedView = sv }
    }

    // MARK: - Actions & Introspection API

    func setMacLAN(enabled: Bool) async {
        isMacLANEnabled = enabled
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
        logs.removeAll()
        await postAction(["action": "clear_logs"])
    }

    func clearNetwork() async {
        networkEntries.removeAll()
        await postAction(["action": "clear_network"])
    }

    func clearUIEvents() async {
        uiEvents.removeAll()
        await postAction(["action": "clear_events"])
    }

    func refreshStatusOnly() async {
        guard let base = baseURL else { return }
        if let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) {
            apply(status: status)
        }
    }

    func loadEvents() async {
        guard let base = baseURL else { return }
        if let list: [LCDebugUIEventEntry] = await fetchJSON(url: base.appendingPathComponent("api/events")) {
            uiEvents = list
        }
    }

    func loadHierarchy() async {
        guard let base = baseURL else { return }
        do {
            let (data, _) = try await session.data(for: authorizedRequest(url: base.appendingPathComponent("api/hierarchy")))
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                hierarchyText = text
            }
        } catch {
            hierarchyText = "Failed to capture view hierarchy: \(error.localizedDescription)"
        }
    }

    func loadDylibs() async {
        guard let base = baseURL else { return }
        if let list: [LCDebugDylibEntry] = await fetchJSON(url: base.appendingPathComponent("api/dylibs")) {
            dylibs = list
        }
    }

    func searchObjCClasses(query: String) async {
        guard let base = baseURL else { return }
        var comp = URLComponents(url: base.appendingPathComponent("api/classes"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comp?.url else { return }
        if let matches: [String] = await fetchJSON(url: url) {
            objcClasses = matches
        }
    }

    func inspectObjCClass(_ className: String) async {
        guard let base = baseURL else { return }
        var comp = URLComponents(url: base.appendingPathComponent("api/classes"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "class", value: className)]
        guard let url = comp?.url else { return }
        if let detail: LCDebugClassDetail = await fetchJSON(url: url) {
            selectedClassDetail = detail
        }
    }

    func loadSandbox() async {
        guard let base = baseURL else { return }
        if let summary: LCDebugSandboxSummary = await fetchJSON(url: base.appendingPathComponent("api/sandbox")) {
            sandboxSummary = summary
        }
    }

    func loadFridaInfo() async {
        guard let base = baseURL else { return }
        if let info: LCDebugFridaInfo = await fetchJSON(url: base.appendingPathComponent("api/frida")) {
            fridaInfo = info
        }
    }

    func attachJIT(for appModel: LCAppModel) async {
        guard pid > 0 else {
            jitStatusBanner = "Waiting for guest process PID..."
            return
        }
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
        if !authToken.isEmpty {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
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

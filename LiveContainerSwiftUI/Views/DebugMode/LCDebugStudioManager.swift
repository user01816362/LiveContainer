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
    let text: String
}

struct LCDebugNetworkEntry: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let timestamp: Double?
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
}

struct LCDebugSelectedView: Decodable, Hashable, Sendable {
    let viewClass: String
    let viewController: String
    let frame: String
    let bounds: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let alpha: Double
    let hidden: Bool
    let tag: Int
    let backgroundColor: String
    let subviewCount: Int

    enum CodingKeys: String, CodingKey {
        case viewClass = "class"
        case viewController
        case frame
        case bounds
        case accessibilityIdentifier
        case accessibilityLabel
        case alpha
        case hidden
        case tag
        case backgroundColor
        case subviewCount
    }
}

struct LCDebugStatusSnapshot: Decodable, Sendable {
    let pid: Int?
    let bundleId: String?
    let localPort: Int?
    let lanPort: Int?
    let lanEnabled: Bool?
    let lanIP: String?
    let cpuPercent: Double?
    let memoryMB: Double?
    let fps: Int?
    let threadCount: Int?
    let isJIT: Bool?
    let xrayEnabled: Bool?
    let tapInspectEnabled: Bool?
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
    var id: String { "\(service)-\(account)-\(accessGroup)" }
    let account: String
    let service: String
    let accessGroup: String
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

        // Coerce arbitrary JSON values in userDefaults into readable strings.
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
    case hierarchy = "Hierarchy"
    case dylibs = "Dylibs & ObjC"
    case sandbox = "Sandbox & Keys"
    case frida = "Frida / LLDB"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .console: return "terminal.fill"
        case .network: return "network"
        case .hierarchy: return "square.3.layers.3d"
        case .dylibs: return "shippingbox.fill"
        case .sandbox: return "folder.fill"
        case .frida: return "ant.fill"
        }
    }
}

@MainActor
final class LCDebugStudioManager: ObservableObject {
    @Published var isConnected = false
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
    @Published var selectedView: LCDebugSelectedView? = nil

    @Published var logs: [LCDebugLogEntry] = []
    @Published var networkEntries: [LCDebugNetworkEntry] = []
    @Published var hierarchyText: String = ""
    @Published var dylibs: [LCDebugDylibEntry] = []
    @Published var objcClasses: [String] = []
    @Published var selectedClassDetail: LCDebugClassDetail? = nil
    @Published var sandboxSummary: LCDebugSandboxSummary? = nil
    @Published var fridaInfo: LCDebugFridaInfo? = nil
    @Published var jitStatusBanner: String? = nil

    private var connectionTask: Task<Void, Never>? = nil
    private var sseTask: Task<Void, Never>? = nil
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: config)
        self.isMacLANEnabled = LCUtils.appGroupUserDefault.bool(forKey: "LCDebugLANEnabled")
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
        session.invalidateAndCancel()
    }

    func startConnecting(expectedPID: Int32) {
        disconnect()
        connectionError = nil
        if expectedPID > 0 {
            self.pid = Int(expectedPID)
        }

        connectionTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled && Date() < deadline {
                if let info = UserDefaults.lcShared().dictionary(forKey: "LCDebugActiveSession"),
                   let port = info["localPort"] as? Int, port > 0 {
                    let sessionPID = info["pid"] as? Int ?? 0
                    if expectedPID <= 0 || sessionPID == Int(expectedPID) || sessionPID > 0 {
                        self.localPort = port
                        self.pid = sessionPID
                        self.authToken = info["authToken"] as? String ?? ""
                        await self.bootstrapConnection()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !Task.isCancelled && !self.isConnected {
                self.connectionError = "Timed out waiting for Debug Agent in guest process."
            }
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        sseTask?.cancel()
        sseTask = nil
        isConnected = false
    }

    private func bootstrapConnection() async {
        await refreshStatusAndSnapshots()
        isConnected = true
        startSSEStream()
    }

    func refreshStatusAndSnapshots() async {
        guard let base = baseURL else { return }
        if let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) {
            apply(status: status)
        }
        if let initialLogs: [LCDebugLogEntry] = await fetchJSON(url: base.appendingPathComponent("api/logs")) {
            self.logs = initialLogs
        }
        if let initialNet: [LCDebugNetworkEntry] = await fetchJSON(url: base.appendingPathComponent("api/network")) {
            self.networkEntries = initialNet
        }
    }

    private func startSSEStream() {
        sseTask?.cancel()
        guard let base = baseURL else { return }
        let streamURL = base.appendingPathComponent("api/stream")

        sseTask = Task { [weak self] in
            guard let self else { return }
            do {
                var req = authorizedRequest(url: streamURL)
                req.timeoutInterval = 3600
                let (bytes, _) = try await self.session.bytes(for: req)
                var currentEvent = "message"
                var dataLines: [String] = []

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.isEmpty {
                        if !dataLines.isEmpty {
                            let joined = dataLines.joined(separator: "\n")
                            self.handleSSEEvent(name: currentEvent, jsonString: joined)
                        }
                        currentEvent = "message"
                        dataLines.removeAll(keepingCapacity: true)
                    } else if line.hasPrefix("event:") {
                        currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.isConnected = false
                }
            }
        }
    }

    private func handleSSEEvent(name: String, jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        switch name {
        case "telemetry":
            if let status = try? decoder.decode(LCDebugStatusSnapshot.self, from: data) {
                apply(status: status)
            }
        case "log":
            if let entry = try? decoder.decode(LCDebugLogEntry.self, from: data) {
                logs.append(entry)
                if logs.count > 600 {
                    logs.removeFirst(logs.count - 600)
                }
            }
        case "network":
            if let entry = try? decoder.decode(LCDebugNetworkEntry.self, from: data) {
                networkEntries.insert(entry, at: 0)
                if networkEntries.count > 200 {
                    networkEntries.removeLast(networkEntries.count - 200)
                }
            }
        case "tap":
            if let view = try? decoder.decode(LCDebugSelectedView.self, from: data) {
                selectedView = view
            }
        default:
            break
        }
    }

    private func apply(status: LCDebugStatusSnapshot) {
        if let p = status.pid { pid = p }
        if let lp = status.localPort { localPort = lp }
        if let lanP = status.lanPort { lanPort = lanP }
        if let lanEn = status.lanEnabled { isMacLANEnabled = lanEn }
        if let ip = status.lanIP { lanIP = ip }
        if let cpu = status.cpuPercent { cpuPercent = cpu }
        if let mem = status.memoryMB { memoryMB = mem }
        if let f = status.fps { fps = f }
        if let tc = status.threadCount { threadCount = tc }
        if let jit = status.isJIT { isJIT = jit }
        if let xr = status.xrayEnabled { isXRayEnabled = xr }
        if let ti = status.tapInspectEnabled { isTapInspectEnabled = ti }
        if let sv = status.selectedView { selectedView = sv }
    }

    // MARK: - Actions & Introspection API

    func setMacLAN(enabled: Bool) async {
        isMacLANEnabled = enabled
        LCUtils.appGroupUserDefault.set(enabled, forKey: "LCDebugLANEnabled")
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

    func refreshStatusOnly() async {
        guard let base = baseURL else { return }
        if let status: LCDebugStatusSnapshot = await fetchJSON(url: base.appendingPathComponent("api/status")) {
            apply(status: status)
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
        let enabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType"))
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let script = appModel.jitLaunchScriptJs?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        if enabler == .StosDebug {
            let encoded = script.map { "&script=\($0)" } ?? ""
            let safeName = appModel.displayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appModel.displayName
            if let url = URL(string: "stosdebug://enableJIT?bundleId=\(bundleId)&appName=\(safeName)&pid=\(pid)&forcePID=true\(encoded)") {
                await UIApplication.shared.open(url)
                jitStatusBanner = "Requested JIT via StosDebug for PID \(pid)."
            }
            return
        }
        if enabler == .StikJIT {
            let encoded = script.map { "&script-data=\($0)" } ?? ""
            if let url = URL(string: "stikjit://enable-jit?bundle-id=\(bundleId)&pid=\(pid)\(encoded)") {
                await UIApplication.shared.open(url)
                jitStatusBanner = "Requested JIT via StikDebug for PID \(pid)."
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
            let (data, _) = try await session.data(for: authorizedRequest(url: url))
            return try JSONDecoder().decode(T.self, from: data)
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

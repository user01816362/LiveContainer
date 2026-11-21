//
//  LCDebugModels.swift
//  LiveContainerSwiftUI
//
//  Immutable Sendable/Equatable models and nonisolated formatting helpers for Debug Studio.
//

import Foundation

struct LCDebugLogEntry: Identifiable, Decodable, Hashable, Equatable, Sendable {
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

struct LCDebugNetworkMetrics: Decodable, Hashable, Equatable, Sendable {
    let dnsMs: Int?
    let connectMs: Int?
    let tlsMs: Int?
    let requestMs: Int?
    let waitMs: Int?
    let responseMs: Int?
    let totalMs: Int?
    let redirects: Int?
    let protocolName: String?
    let reusedConnection: Bool?
    let remoteAddress: String?
    let isCellular: Bool?
    let isProxy: Bool?
    let wireRequestBytes: Int?
    let wireResponseBytes: Int?
}

struct LCDebugNetworkEntry: Identifiable, Decodable, Hashable, Equatable, Sendable {
    let id: String
    let redirectFromId: String?
    let timestamp: Double?
    let state: String?
    let source: String?
    let mechanism: String?
    let method: String
    let url: String
    let host: String?
    let path: String?
    let statusCode: Int
    let mimeType: String
    let latencyMs: Int?
    let durationMs: Int
    let requestBytes: Int?
    let responseBytes: Int?
    let bytes: Int
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    let requestBodyPreview: String
    let responseBodyPreview: String
    let hasRequestBody: Bool?
    let hasResponseBody: Bool?
    let isGraphQL: Bool?
    let graphQLOperation: String?
    let metrics: LCDebugNetworkMetrics?
    let curl: String
    let error: String

    var resolvedHost: String {
        if let host, !host.isEmpty { return host }
        return URL(string: url)?.host ?? ""
    }

    var displayEndpoint: String {
        guard let parsed = URL(string: url) else {
            return url
        }
        var piece = parsed.path
        if piece.isEmpty { piece = "/" }
        if let query = parsed.query, !query.isEmpty {
            piece += "?\(query)"
        }
        return piece
    }

    var displayHostAndDir: String {
        guard let parsed = URL(string: url) else {
            return resolvedHost
        }
        let h = parsed.host ?? resolvedHost
        let parent = (parsed.path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "/" {
            return h
        }
        return "\(h)\(parent)"
    }

    var isInFlight: Bool {
        state == "pending" || state == "receiving"
    }

    var isFailure: Bool {
        state == "failed" || statusCode < 0 || statusCode >= 400 || !error.isEmpty
    }

    var statusBadgeText: String {
        if isInFlight {
            return statusCode > 0 ? "\(statusCode)…" : "LIVE"
        }
        if statusCode < 0 {
            return "ERR"
        }
        if statusCode == 0 {
            return "—"
        }
        return "\(statusCode)"
    }

    var displaySource: String {
        switch source?.lowercased() {
        case "webview": return "WebView"
        case "websocket": return "WebSocket"
        case "urlconnection": return "URLConnection"
        default: return "URLSession"
        }
    }

    var shortMimeLabel: String {
        let lower = mimeType.lowercased()
        if isGraphQL == true { return "GQL" }
        if lower.contains("json") { return "JSON" }
        if lower.hasPrefix("image/") { return lower.replacingOccurrences(of: "image/", with: "").uppercased() }
        if lower.contains("html") { return "HTML" }
        if lower.contains("xml") { return "XML" }
        if lower.contains("javascript") { return "JS" }
        if lower.contains("form-urlencoded") { return "FORM" }
        if lower == "websocket" { return "WS" }
        if lower.isEmpty { return "" }
        return String(lower.split(separator: "/").last ?? "").uppercased()
    }

    var effectiveByteCount: Int {
        max(bytes, max(responseBytes ?? 0, requestBytes ?? 0))
    }
}

struct LCDebugNetworkBodyPayload: Decodable, Equatable, Sendable {
    let id: String
    let part: String
    let byteCount: Int
    let mimeType: String
    let encoding: String
    let isBinary: Bool
    let isImage: Bool
    let text: String
    let base64: String
    let hexPreview: String
    let truncated: Bool
    let requestHeaders: [String: String]?
    let responseHeaders: [String: String]?
    let curl: String?
}

struct LCDebugNetworkSettings: Codable, Equatable, Sendable {
    var paused: Bool
    var cacheMediaBodies: Bool
    var cacheLimitMB: Int
    var maxTransactions: Int
    var redactSensitive: Bool
    var excludedHosts: [String]

    var redactExports: Bool {
        get { redactSensitive }
        set { redactSensitive = newValue }
    }

    var isCaptureEnabled: Bool {
        get { !paused }
        set { paused = !newValue }
    }

    var cacheLimitMBDouble: Double {
        get { Double(cacheLimitMB) }
        set { cacheLimitMB = Int(newValue.rounded()) }
    }

    enum CodingKeys: String, CodingKey {
        case paused
        case cacheMediaBodies
        case cacheLimitMB
        case maxTransactions
        case redactSensitive
        case redactExports
        case excludedHosts
    }

    init(
        paused: Bool,
        cacheMediaBodies: Bool,
        cacheLimitMB: Int,
        maxTransactions: Int,
        redactSensitive: Bool = false,
        excludedHosts: [String]
    ) {
        self.paused = paused
        self.cacheMediaBodies = cacheMediaBodies
        self.cacheLimitMB = cacheLimitMB
        self.maxTransactions = maxTransactions
        self.redactSensitive = redactSensitive
        self.excludedHosts = excludedHosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? false
        cacheMediaBodies = (try? c.decode(Bool.self, forKey: .cacheMediaBodies)) ?? true
        cacheLimitMB = (try? c.decode(Int.self, forKey: .cacheLimitMB)) ?? 16
        maxTransactions = (try? c.decode(Int.self, forKey: .maxTransactions)) ?? 500
        if let rs = try? c.decode(Bool.self, forKey: .redactSensitive) {
            redactSensitive = rs
        } else {
            redactSensitive = (try? c.decode(Bool.self, forKey: .redactExports)) ?? false
        }
        excludedHosts = (try? c.decode([String].self, forKey: .excludedHosts)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paused, forKey: .paused)
        try c.encode(cacheMediaBodies, forKey: .cacheMediaBodies)
        try c.encode(cacheLimitMB, forKey: .cacheLimitMB)
        try c.encode(maxTransactions, forKey: .maxTransactions)
        try c.encode(redactSensitive, forKey: .redactSensitive)
        try c.encode(redactSensitive, forKey: .redactExports)
        try c.encode(excludedHosts, forKey: .excludedHosts)
    }

    static let `default` = LCDebugNetworkSettings(
        paused: false,
        cacheMediaBodies: true,
        cacheLimitMB: 16,
        maxTransactions: 500,
        redactSensitive: false,
        excludedHosts: []
    )
}

struct LCDebugNetworkReplayResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let statusCode: Int?
    let durationMs: Int?
    let bytes: Int?
    let error: String?
}

struct LCDebugNetworkReplayTarget: Identifiable, Equatable, Sendable {
    let id: String
    let transactionId: String?
    var method: String
    var url: String
    var headers: [String: String]
    var body: String
}

struct LCDebugUIEventEntry: Identifiable, Decodable, Hashable, Equatable, Sendable {
    let id: String
    let timestamp: Double?
    let kind: String
    let title: String
    let detail: String
    let target: String
    let viewController: String
    let window: String
}

struct LCDebugSelectedView: Decodable, Hashable, Equatable, Sendable {
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
    let networkPaused: Bool?
    let networkRedactSensitive: Bool?
    let selectedView: LCDebugSelectedView?
}

struct LCDebugDylibEntry: Identifiable, Decodable, Hashable, Equatable, Sendable {
    var id: String { "\(index)-\(base)" }
    let index: Int
    let base: String
    let path: String
    let name: String
    let isSystem: Bool
}

struct LCDebugClassMemberItem: Identifiable, Hashable, Equatable, Sendable {
    let id: String
    let signature: String

    static func buildList(prefix: String, raw: [String]) -> [LCDebugClassMemberItem] {
        var counts: [String: Int] = [:]
        return raw.map { entry in
            let occ = counts[entry, default: 0]
            counts[entry] = occ + 1
            return LCDebugClassMemberItem(id: "\(prefix)|\(entry)#\(occ)", signature: entry)
        }
    }
}

struct LCDebugClassDetail: Identifiable, Decodable, Hashable, Equatable, Sendable {
    var id: String { className }
    let className: String
    let superclassName: String
    let image: String
    let methods: [String]
    let properties: [String]
    let ivars: [String]
    let methodItems: [LCDebugClassMemberItem]
    let propertyItems: [LCDebugClassMemberItem]
    let ivarItems: [LCDebugClassMemberItem]

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case superclassName = "superclass"
        case image
        case methods
        case properties
        case ivars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        className = (try? c.decode(String.self, forKey: .className)) ?? ""
        superclassName = (try? c.decode(String.self, forKey: .superclassName)) ?? ""
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        let m = (try? c.decode([String].self, forKey: .methods)) ?? []
        let p = (try? c.decode([String].self, forKey: .properties)) ?? []
        let i = (try? c.decode([String].self, forKey: .ivars)) ?? []
        methods = m
        properties = p
        ivars = i
        methodItems = LCDebugClassMemberItem.buildList(prefix: "m", raw: m)
        propertyItems = LCDebugClassMemberItem.buildList(prefix: "p", raw: p)
        ivarItems = LCDebugClassMemberItem.buildList(prefix: "i", raw: i)
    }
}

struct LCDebugSandboxFile: Identifiable, Decodable, Hashable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    let type: String
}

struct LCDebugKeychainItem: Identifiable, Hashable, Equatable, Sendable {
    let id: String
    let account: String
    let service: String
    let accessGroup: String
    let value: String
}

private struct LCRawKeychainItem: Decodable, Sendable {
    let account: String
    let service: String
    let accessGroup: String
    let value: String?
}

struct LCDebugSandboxSummary: Decodable, Equatable, Sendable {
    let home: String
    let files: [LCDebugSandboxFile]
    let userDefaults: [String: String]
    let keychainItems: [LCDebugKeychainItem]
    let sortedUserDefaultKeys: [String]

    enum CodingKeys: String, CodingKey {
        case home, files, userDefaults, keychainItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        home = (try? container.decode(String.self, forKey: .home)) ?? ""
        files = (try? container.decode([LCDebugSandboxFile].self, forKey: .files)) ?? []

        let rawKC = (try? container.decode([LCRawKeychainItem].self, forKey: .keychainItems)) ?? []
        var kcCounts: [String: Int] = [:]
        keychainItems = rawKC.map { raw in
            let base = "\(raw.service)|\(raw.account)|\(raw.accessGroup)"
            let occ = kcCounts[base, default: 0]
            kcCounts[base] = occ + 1
            return LCDebugKeychainItem(
                id: "\(base)#\(occ)",
                account: raw.account,
                service: raw.service,
                accessGroup: raw.accessGroup,
                value: raw.value ?? ""
            )
        }

        if let rawDict = try? container.decode([String: LCDebugAnyCodable].self, forKey: .userDefaults) {
            var coerced: [String: String] = [:]
            coerced.reserveCapacity(rawDict.count)
            for (k, v) in rawDict {
                coerced[k] = v.stringSummary
            }
            userDefaults = coerced
            sortedUserDefaultKeys = coerced.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            userDefaults = [:]
            sortedUserDefaultKeys = []
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
            if n.rounded() == n, n >= Double(Int64.min), n <= Double(Int64.max) {
                return String(Int64(n))
            }
            return String(n)
        case .other: return "<Collection / Object>"
        }
    }
}

struct LCDebugFridaInfo: Decodable, Equatable, Sendable {
    let pid: Int
    let bundleId: String
    let executablePath: String
    let bundlePath: String
    let isJIT: Bool
    let fridaGadgetLoaded: Bool
    let nativeAgentActive: Bool?
    let fridaAttachCmd: String
    let fridaGadgetTip: String
    let lldbCmd: String
}

// MARK: - View Hierarchy Parsed Tree

struct LCDebugHierarchyNode: Identifiable, Hashable, Equatable, Sendable {
    let id: String
    let className: String
    let frame: String
    let isHidden: Bool
    let alpha: Double
    let viewController: String?
    let accessibilityId: String?
    let children: [LCDebugHierarchyNode]

    var isDimmed: Bool {
        isHidden || alpha < 0.05
    }
}

struct LCDebugHierarchyWindow: Identifiable, Hashable, Equatable, Sendable {
    let id: String
    let windowClass: String
    let windowLevel: Double
    let isKeyWindow: Bool
    let frame: String
    let rootViewController: String
    let rootNode: LCDebugHierarchyNode?
}

struct LCDebugKeyValuePair: Identifiable, Hashable, Equatable, Sendable {
    let id: String
    let key: String
    let value: String
}

struct LCDebugGraphQLPayload: Equatable, Sendable {
    let operationName: String
    let query: String
    let variablesPretty: String
    let extensionsPretty: String
}

enum LCDebugInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case console = "Console"
    case network = "Network"
    case events = "Events"
    case hierarchy = "Hierarchy"
    case runtime = "Runtime"
    case sandbox = "Sandbox"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .console: return "terminal.fill"
        case .network: return "network"
        case .events: return "cursorarrow.click.2"
        case .hierarchy: return "square.3.layers.3d"
        case .runtime: return "shippingbox.fill"
        case .sandbox: return "folder.fill"
        }
    }
}

enum LCDebugDrawerDetent: String, CaseIterable, Sendable {
    case collapsed
    case docked
    case expanded
}

enum LCDebugNetworkStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case inFlight = "Live"
    case ok2xx = "2xx"
    case redir3xx = "3xx"
    case errors = "Errors"

    var id: String { rawValue }
}

enum LCDebugNetworkTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case urlsession = "URLSession"
    case graphql = "GraphQL"
    case webview = "WebView"
    case websocket = "WebSocket"
    case json = "JSON"
    case media = "Media"

    var id: String { rawValue }
}

enum LCDebugLogStreamFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case stdio = "Stdio"
    case nslog = "NSLog"
    case oslog = "OSLog"
    case webview = "Web"
    case errors = "Errors"

    var id: String { rawValue }
}

enum LCDebugUIEventKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case touch = "Touch"
    case action = "Action"
    case vc = "VC"
    case nav = "Nav"
    case modal = "Modal"
    case tab = "Tab"
    case window = "Window"
    case notification = "Notif"

    var id: String { rawValue }
}

// MARK: - Pure Nonisolated Formatting & Parsers (Swift 6 Safe for Background Tasks)

nonisolated enum LCDebugFormatting {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func formatTimestamp(_ cfAbsolute: Double?) -> String {
        guard let cfAbsolute, cfAbsolute > 0 else { return "" }
        let date = Date(timeIntervalSinceReferenceDate: cfAbsolute)
        return timeFormatter.string(from: date)
    }

    static func formatByteCount(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms <= 0 { return "0 ms" }
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.2f s", Double(ms) / 1000.0)
    }

    static func prettyPrintedJSON(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty
    }

    static func parseQueryItems(from urlString: String) -> [LCDebugKeyValuePair] {
        guard let items = URLComponents(string: urlString)?.queryItems, !items.isEmpty else {
            return []
        }
        var seen: [String: Int] = [:]
        return items.map { qi in
            let occ = seen[qi.name, default: 0]
            seen[qi.name] = occ + 1
            return LCDebugKeyValuePair(id: "\(qi.name)#\(occ)", key: qi.name, value: qi.value ?? "")
        }
    }

    static func parseFormURLEncoded(_ raw: String) -> [LCDebugKeyValuePair] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("="), !trimmed.hasPrefix("{"), !trimmed.hasPrefix("<") else {
            return []
        }
        var comp = URLComponents()
        comp.percentEncodedQuery = trimmed.replacingOccurrencesOfString("+", with: "%20")
        guard let items = comp.queryItems, !items.isEmpty else { return [] }
        var seen: [String: Int] = [:]
        return items.map { qi in
            let occ = seen[qi.name, default: 0]
            seen[qi.name] = occ + 1
            return LCDebugKeyValuePair(id: "form|\(qi.name)#\(occ)", key: qi.name, value: qi.value ?? "")
        }
    }

    static func parseGraphQLBody(_ raw: String) -> LCDebugGraphQLPayload? {
        guard let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let query = (dict["query"] as? String) ?? ""
        let op = (dict["operationName"] as? String) ?? ""
        let varsObj = dict["variables"]
        let extObj = dict["extensions"]
        if query.isEmpty && op.isEmpty && extObj == nil {
            return nil
        }
        let varsPretty = varsObj.flatMap { prettySerialized($0) } ?? ""
        let extPretty = extObj.flatMap { prettySerialized($0) } ?? ""
        return LCDebugGraphQLPayload(
            operationName: op,
            query: query,
            variablesPretty: varsPretty,
            extensionsPretty: extPretty
        )
    }

    private static func prettySerialized(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func sortedHeaderPairs(_ headers: [String: String]) -> [LCDebugKeyValuePair] {
        headers.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { LCDebugKeyValuePair(id: "hdr|\($0)", key: $0, value: headers[$0] ?? "") }
    }

    static func formatHexDump(data: Data, maxBytes: Int = 8192) -> String {
        let cap = min(data.count, maxBytes)
        if cap == 0 { return "" }
        var lines: [String] = []
        lines.reserveCapacity((cap / 16) + 2)
        for offset in stride(from: 0, to: cap, by: 16) {
            let end = min(offset + 16, cap)
            let chunk = data[offset..<end]
            let addr = String(format: "%06X  ", offset)
            var hexPart = ""
            var asciiPart = ""
            for i in 0..<16 {
                if offset + i < end {
                    let b = chunk[chunk.index(chunk.startIndex, offsetBy: i)]
                    hexPart += String(format: "%02X ", b)
                    asciiPart.append((b >= 0x20 && b < 0x7F) ? Character(UnicodeScalar(b)) : ".")
                } else {
                    hexPart += "   "
                }
                if i == 7 { hexPart += " " }
            }
            lines.append("\(addr)\(hexPart) |\(asciiPart)|")
        }
        if data.count > cap {
            lines.append("… (\(data.count) bytes total)")
        }
        return lines.joined(separator: "\n")
    }

    static func parseHierarchyWindows(from data: Data) -> (windows: [LCDebugHierarchyWindow], prettyJSON: String) {
        let pretty: String
        if let rawObj = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: rawObj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: prettyData, encoding: .utf8) {
            pretty = str
        } else {
            pretty = String(data: data, encoding: .utf8) ?? ""
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([], pretty)
        }

        if let rawWindows = root["windows"] as? [[String: Any]], !rawWindows.isEmpty {
            let windows = rawWindows.enumerated().map { idx, wDict in
                let tree = (wDict["tree"] as? [String: Any]).flatMap { parseNode($0, path: "w\(idx)") }
                return LCDebugHierarchyWindow(
                    id: "w\(idx)",
                    windowClass: (wDict["windowClass"] as? String) ?? "UIWindow",
                    windowLevel: (wDict["windowLevel"] as? Double) ?? 0,
                    isKeyWindow: (wDict["isKeyWindow"] as? Bool) ?? false,
                    frame: (wDict["frame"] as? String) ?? "",
                    rootViewController: (wDict["rootViewController"] as? String) ?? "",
                    rootNode: tree
                )
            }
            return (windows, pretty)
        }

        if let treeDict = root["tree"] as? [String: Any] {
            let win = LCDebugHierarchyWindow(
                id: "w0",
                windowClass: (root["windowClass"] as? String) ?? "UIWindow",
                windowLevel: 0,
                isKeyWindow: true,
                frame: "",
                rootViewController: (root["rootViewController"] as? String) ?? "",
                rootNode: parseNode(treeDict, path: "w0")
            )
            return ([win], pretty)
        }
        return ([], pretty)
    }

    private static func parseNode(_ dict: [String: Any], path: String) -> LCDebugHierarchyNode {
        let rawChildren = (dict["children"] as? [[String: Any]]) ?? []
        let children = rawChildren.enumerated().map { idx, child in
            parseNode(child, path: "\(path).\(idx)")
        }
        return LCDebugHierarchyNode(
            id: path,
            className: (dict["class"] as? String) ?? "UIView",
            frame: (dict["frame"] as? String) ?? "",
            isHidden: (dict["hidden"] as? Bool) ?? false,
            alpha: (dict["alpha"] as? Double) ?? 1.0,
            viewController: dict["viewController"] as? String,
            accessibilityId: dict["accessibilityId"] as? String,
            children: children
        )
    }
}

private extension String {
    func replacingOccurrencesOfString(_ target: String, with replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement)
    }
}

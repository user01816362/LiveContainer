//
//  LCFileExplorerService.swift
//  LiveContainerSwiftUI
//
//  Off-MainActor filesystem, Property List, read-only SQLite, text/JSON,
//  and bounded hex-page services for LiveContainer's native File Explorer.
//

import Foundation
import SQLite3

/// Runs synchronous throwing work off the MainActor while propagating Swift
/// structured task cancellation into the detached worker's `Task.isCancelled`.
nonisolated func lcRunOffMain<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) {
        try operation()
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Errors surfaced by ``LCFileExplorerService``.
enum LCFileExplorerError: LocalizedError, Sendable {
    case securityScopeDenied
    case fileTooLargeForViewer(actualBytes: UInt64, maxBytes: UInt64)
    case invalidPlist(String)
    case sqliteFailed(String)
    case specialFileUnsupported

    var errorDescription: String? {
        switch self {
        case .securityScopeDenied:
            return "Unable to access external storage container (security-scoped bookmark denied)."
        case let .fileTooLargeForViewer(actual, limit):
            let a = ByteCountFormatter.string(fromByteCount: Int64(min(actual, UInt64(Int64.max))), countStyle: .file)
            let l = ByteCountFormatter.string(fromByteCount: Int64(min(limit, UInt64(Int64.max))), countStyle: .file)
            return "File (\(a)) exceeds safe viewer limit (\(l)). Use Hex Peek or Share instead."
        case let .invalidPlist(reason):
            return "Unable to parse property list: \(reason)"
        case let .sqliteFailed(message):
            return "SQLite error: \(message)"
        case .specialFileUnsupported:
            return "Special filesystem entries (sockets, FIFOs, or device nodes) cannot be opened."
        }
    }
}

/// Pure nonisolated service performing all File Explorer I/O off the MainActor.
enum LCFileExplorerService {
    private static let maxPlistBytes: UInt64 = 4 * 1024 * 1024
    private static let maxTextPreviewBytes: Int = 512 * 1024
    private static let maxImageBytes: UInt64 = UInt64(LCBoundedFileReader.maxSingleReadBytes) // 16 MiB
    private static let maxStageShareBytes: UInt64 = 256 * 1024 * 1024
    private static let maxPlistDepth: Int = 32

    private static let bundleExtensions: Set<String> = ["app", "framework", "appex", "bundle", "xctest", "plugin"]
    private static let plistExtensions: Set<String> = ["plist", "strings", "stringsdict", "entitlements", "mobileprovision"]
    private static let jsonExtensions: Set<String> = ["json", "geojson", "webmanifest", "xcstrings"]
    private static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "storedata", "sqlitedb"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "ico"]
    private static let archiveExtensions: Set<String> = ["zip", "ipa", "tipa", "deb", "tar", "gz", "bz2", "xz", "7z"]
    private static let textExtensions: Set<String> = [
        "txt", "log", "xml", "md", "markdown", "h", "hpp", "c", "m", "mm", "cpp", "swift",
        "js", "ts", "css", "html", "htm", "yml", "yaml", "toml", "ini", "cfg", "conf",
        "sh", "zsh", "py", "rb", "csv", "tsv", "svg", "entitlements", "modulemap", "xcconfig", "metal"
    ]

    /// Runs `body` while holding security-scoped access on `rootURL` when needed.
    static func withSecurityScope<T>(
        rootURL: URL,
        needsSecurityScope: Bool,
        _ body: () throws -> T
    ) throws -> T {
        if needsSecurityScope {
            guard rootURL.startAccessingSecurityScopedResource() else {
                throw LCFileExplorerError.securityScopeDenied
            }
            defer { rootURL.stopAccessingSecurityScopedResource() }
            return try body()
        }
        return try body()
    }

    // MARK: - Directory Listing

    /// Lists a single directory level safely (no symlink traversal loops, no hanging on FIFOs/sockets).
    static func listDirectory(
        at directoryURL: URL,
        rootURL: URL,
        needsSecurityScope: Bool
    ) throws -> [LCFileEntry] {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileResourceTypeKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
            let urls = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: []
            )

            var entries: [LCFileEntry] = []
            entries.reserveCapacity(urls.count)

            for itemURL in urls {
                if Task.isCancelled { break }
                let values = try? itemURL.resourceValues(forKeys: Set(keys))
                let isSymlink = values?.isSymbolicLink ?? false
                let resourceType = values?.fileResourceType
                let isRegular = resourceType == .regular
                let isDir = (values?.isDirectory ?? false) && !isSymlink
                let name = itemURL.lastPathComponent
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate

                if isSymlink {
                    let dest = try? fm.destinationOfSymbolicLink(atPath: itemURL.path)
                    entries.append(LCFileEntry(
                        id: itemURL.path,
                        url: itemURL,
                        name: name,
                        kind: .symlink,
                        isDirectory: false,
                        isSymbolicLink: true,
                        symlinkDestination: dest,
                        size: size,
                        modifiedDate: modified,
                        machOExecutableURL: nil
                    ))
                    continue
                }

                if !isDir && !isRegular && resourceType != nil {
                    entries.append(LCFileEntry(
                        id: itemURL.path,
                        url: itemURL,
                        name: name,
                        kind: .special,
                        isDirectory: false,
                        isSymbolicLink: false,
                        symlinkDestination: nil,
                        size: 0,
                        modifiedDate: modified,
                        machOExecutableURL: nil
                    ))
                    continue
                }

                let normalizedExt = normalizedFileExtension(for: name)
                if isDir {
                    let isBundle = bundleExtensions.contains(normalizedExt)
                    let execURL = isBundle ? LCBoundedFileReader.resolveMachOExecutableURL(for: itemURL) : nil
                    entries.append(LCFileEntry(
                        id: itemURL.path,
                        url: itemURL,
                        name: name,
                        kind: isBundle ? .bundle : .directory,
                        isDirectory: true,
                        isSymbolicLink: false,
                        symlinkDestination: nil,
                        size: 0,
                        modifiedDate: modified,
                        machOExecutableURL: execURL
                    ))
                } else {
                    let (kind, machOURL) = classifyRegularFile(url: itemURL, ext: normalizedExt, size: size)
                    entries.append(LCFileEntry(
                        id: itemURL.path,
                        url: itemURL,
                        name: name,
                        kind: kind,
                        isDirectory: false,
                        isSymbolicLink: false,
                        symlinkDestination: nil,
                        size: size,
                        modifiedDate: modified,
                        machOExecutableURL: machOURL
                    ))
                }
            }

            return entries
        }
    }

    private static func normalizedFileExtension(for name: String) -> String {
        var working = name
        if working.hasSuffix(".disabled") {
            working = String(working.dropLast(".disabled".count))
        }
        return (working as NSString).pathExtension.lowercased()
    }

    private static func classifyRegularFile(url: URL, ext: String, size: Int64) -> (LCFileKind, URL?) {
        if ext == "dylib" || ext == "so" || ext == "o" {
            let isMachO = size >= 4 && LCBoundedFileReader.isMachOFile(at: url)
            return (isMachO ? .machOBinary : .binary, isMachO ? url : nil)
        }
        if plistExtensions.contains(ext) { return (.plist, nil) }
        if jsonExtensions.contains(ext) { return (.json, nil) }
        if sqliteExtensions.contains(ext) { return (.sqlite, nil) }
        if imageExtensions.contains(ext) { return (.image, nil) }
        if archiveExtensions.contains(ext) { return (.archive, nil) }
        if textExtensions.contains(ext) { return (.text, nil) }

        // Probe Mach-O magic for extensionless or uncommon-extension executables (e.g. `MyApp.prod`)
        if size >= 4, LCBoundedFileReader.isMachOFile(at: url) {
            return (.machOBinary, url)
        }
        // SQLite magic check for extensionless DB files ("SQLite format 3\0")
        if ext.isEmpty, size >= 16, isSQLiteMagic(at: url) {
            return (.sqlite, nil)
        }
        return (.binary, nil)
    }

    private static func isSQLiteMagic(at url: URL) -> Bool {
        guard let reader = try? LCBoundedFileReader(url: url),
              let header = try? reader.readUpTo(offset: 0, maxCount: 16),
              header.count == 16 else {
            return false
        }
        return String(decoding: header.prefix(15), as: UTF8.self) == "SQLite format 3"
    }

    // MARK: - Property List Viewer

    static func loadPlistDocument(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool
    ) throws -> LCPlistDocument {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: url)
            guard reader.fileSize <= maxPlistBytes else {
                throw LCFileExplorerError.fileTooLargeForViewer(actualBytes: reader.fileSize, maxBytes: maxPlistBytes)
            }
            let rawData = try reader.readData(offset: 0, count: Int(reader.fileSize))
            // Extract embedded XML plist from CMS-wrapped `.mobileprovision` files
            let data: Data
            if url.pathExtension.lowercased() == "mobileprovision",
               let startRange = rawData.range(of: Data("<plist".utf8)),
               let endRange = rawData.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<rawData.endIndex) {
                data = Data(rawData[startRange.lowerBound..<endRange.upperBound])
            } else {
                data = rawData
            }
            var format: PropertyListSerialization.PropertyListFormat = .xml
            let plistObj: Any
            do {
                plistObj = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            } catch {
                throw LCFileExplorerError.invalidPlist(error.localizedDescription)
            }

            let formatLabel: String
            if url.pathExtension.lowercased() == "mobileprovision" {
                formatLabel = "Provisioning Profile"
            } else {
                switch format {
                case .binary: formatLabel = "Binary Plist"
                case .xml: formatLabel = "XML Plist"
                case .openStep: formatLabel = "OpenStep Strings"
                @unknown default: formatLabel = "Plist"
                }
            }

            let nodes = buildPlistNodes(from: plistObj, pathPrefix: "root", depth: 0)
            let rawText: String
            if let xmlData = try? PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0),
               let xmlString = String(data: xmlData, encoding: .utf8) {
                rawText = xmlString
            } else {
                rawText = String(decoding: data, as: UTF8.self)
            }

            return LCPlistDocument(formatLabel: formatLabel, nodes: nodes, rawText: rawText)
        }
    }

    private static func buildPlistNodes(from object: Any, pathPrefix: String, depth: Int) -> [LCPlistNode] {
        guard depth < maxPlistDepth else {
            return [LCPlistNode(id: "\(pathPrefix).maxDepth", key: "…", typeLabel: "Info", valueSummary: "Maximum nesting depth reached", children: nil)]
        }
        if let dict = object as? [String: Any] {
            return dict.keys.sorted().map { key in
                let value = dict[key] as Any
                return makePlistNode(key: key, value: value, path: "\(pathPrefix).\(key)", depth: depth + 1)
            }
        }
        if let array = object as? [Any] {
            return array.enumerated().map { index, value in
                makePlistNode(key: "[\(index)]", value: value, path: "\(pathPrefix)[\(index)]", depth: depth + 1)
            }
        }
        return [makePlistNode(key: "Root", value: object, path: pathPrefix, depth: depth + 1)]
    }

    private static func makePlistNode(key: String, value: Any, path: String, depth: Int) -> LCPlistNode {
        if let dict = value as? [String: Any] {
            let children = buildPlistNodes(from: dict, pathPrefix: path, depth: depth)
            return LCPlistNode(
                id: path,
                key: key,
                typeLabel: "Dict",
                valueSummary: "\(dict.count) item\(dict.count == 1 ? "" : "s")",
                children: children.isEmpty ? nil : children
            )
        }
        if let array = value as? [Any] {
            let children = buildPlistNodes(from: array, pathPrefix: path, depth: depth)
            return LCPlistNode(
                id: path,
                key: key,
                typeLabel: "Array",
                valueSummary: "\(array.count) item\(array.count == 1 ? "" : "s")",
                children: children.isEmpty ? nil : children
            )
        }
        if let str = value as? String {
            return LCPlistNode(id: path, key: key, typeLabel: "String", valueSummary: str, children: nil)
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return LCPlistNode(id: path, key: key, typeLabel: "Bool", valueSummary: num.boolValue ? "true" : "false", children: nil)
            }
            return LCPlistNode(id: path, key: key, typeLabel: "Number", valueSummary: num.stringValue, children: nil)
        }
        if let date = value as? Date {
            return LCPlistNode(id: path, key: key, typeLabel: "Date", valueSummary: date.formatted(date: .abbreviated, time: .shortened), children: nil)
        }
        if let data = value as? Data {
            let hexPrefix = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            let suffix = data.count > 16 ? "…" : ""
            return LCPlistNode(
                id: path,
                key: key,
                typeLabel: "Data",
                valueSummary: "\(data.count) B (\(hexPrefix)\(suffix))",
                children: nil
            )
        }
        return LCPlistNode(id: path, key: key, typeLabel: "Value", valueSummary: String(describing: value), children: nil)
    }

    // MARK: - Text / JSON Preview

    static func loadTextPreview(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool,
        attemptPrettyJSON: Bool
    ) throws -> LCFileTextPreview {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: url)
            let data = try reader.readUpTo(offset: 0, maxCount: maxTextPreviewBytes)
            let isTruncated = UInt64(data.count) < reader.fileSize

            if attemptPrettyJSON, !isTruncated,
               let jsonObj = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]),
               let prettyText = String(data: prettyData, encoding: .utf8) {
                return LCFileTextPreview(
                    text: prettyText,
                    totalBytes: reader.fileSize,
                    displayedBytes: data.count,
                    isTruncated: false,
                    isPrettyJSON: true
                )
            }

            // Trim up to 3 trailing incomplete UTF-8 continuation bytes when truncated mid-character
            var decodable = data
            if isTruncated {
                for trim in 0...min(3, data.count) {
                    let candidate = trim == 0 ? data : data.dropLast(trim)
                    if String(data: candidate, encoding: .utf8) != nil {
                        decodable = Data(candidate)
                        break
                    }
                }
            }
            let decoded = String(data: decodable, encoding: .utf8)
                ?? String(data: decodable, encoding: .isoLatin1)
                ?? String(decoding: decodable, as: UTF8.self)
            return LCFileTextPreview(
                text: decoded,
                totalBytes: reader.fileSize,
                displayedBytes: data.count,
                isTruncated: isTruncated,
                isPrettyJSON: false
            )
        }
    }

    // MARK: - Bounded Image Loader

    static func loadImageData(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool
    ) throws -> Data {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: url)
            guard reader.fileSize <= maxImageBytes else {
                throw LCFileExplorerError.fileTooLargeForViewer(actualBytes: reader.fileSize, maxBytes: maxImageBytes)
            }
            return try reader.readData(offset: 0, count: Int(reader.fileSize))
        }
    }

    // MARK: - Paginated Hex Loader

    static func loadHexPage(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool,
        offset: UInt64,
        pageSize: Int = 4096
    ) throws -> LCHexPage {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: url)
            let safeOffset = min(offset, reader.fileSize)
            let data = try reader.readUpTo(offset: safeOffset, maxCount: pageSize)
            return LCHexPage(offset: safeOffset, fileSize: reader.fileSize, data: data)
        }
    }

    /// Formats raw bytes into an offset + 16-byte hex + ASCII dump string off the MainActor.
    nonisolated static func formatHexDump(data: Data, baseOffset: UInt64) -> String {
        guard !data.isEmpty else { return "(Empty file)" }
        let bytesPerLine = 16
        var lines: [String] = []
        lines.reserveCapacity((data.count + bytesPerLine - 1) / bytesPerLine)

        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var idx = 0
            while idx < data.count {
                let rowLen = min(bytesPerLine, data.count - idx)
                var hexPart = ""
                hexPart.reserveCapacity(bytesPerLine * 3 + 1)
                var asciiPart = ""
                asciiPart.reserveCapacity(bytesPerLine)

                for col in 0..<bytesPerLine {
                    if col == 8 { hexPart.append(" ") }
                    if col < rowLen {
                        let b = ptr[idx + col]
                        hexPart.append(String(format: "%02X ", b))
                        asciiPart.append((b >= 0x20 && b <= 0x7E) ? Character(UnicodeScalar(b)) : ".")
                    } else {
                        hexPart.append("   ")
                        asciiPart.append(" ")
                    }
                }
                lines.append(String(format: "%08llX  %@ |%@|", baseOffset + UInt64(idx), hexPart, asciiPart))
                idx += bytesPerLine
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Read-Only SQLite Browser

    private static func quoteSQLiteIdentifier(_ name: String) throws -> String {
        guard !name.contains("\0") else {
            throw LCFileExplorerError.sqliteFailed("Invalid table identifier.")
        }
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func openSQLiteReadOnly(at url: URL) throws -> OpaquePointer {
        // Verify regular file with O_NONBLOCK first so FIFOs/sockets with `.db` extension never block
        _ = try LCBoundedFileReader(url: url)

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path

        func tryOpen(uri: String) -> (db: OpaquePointer?, errorMessage: String?) {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(uri, &db, flags, nil)
            guard rc == SQLITE_OK, let opened = db else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database (code \(rc))"
                if let db { sqlite3_close(db) }
                return (nil, msg)
            }
            sqlite3_exec(opened, "PRAGMA query_only = ON;", nil, nil, nil)
            // Probe sqlite_master eagerly so WAL-mode DBs in read-only directories trigger the immutable fallback
            var probeStmt: OpaquePointer?
            let prepRC = sqlite3_prepare_v2(opened, "SELECT 1 FROM sqlite_master LIMIT 1;", -1, &probeStmt, nil)
            if prepRC == SQLITE_OK, let probeStmt {
                let stepRC = sqlite3_step(probeStmt)
                sqlite3_finalize(probeStmt)
                if stepRC == SQLITE_ROW || stepRC == SQLITE_DONE {
                    return (opened, nil)
                }
            } else if let probeStmt {
                sqlite3_finalize(probeStmt)
            }
            let msg = String(cString: sqlite3_errmsg(opened))
            sqlite3_close(opened)
            return (nil, msg)
        }

        let roAttempt = tryOpen(uri: "file:\(encodedPath)?mode=ro")
        if let opened = roAttempt.db {
            return opened
        }
        let immutableAttempt = tryOpen(uri: "file:\(encodedPath)?immutable=1")
        if let opened = immutableAttempt.db {
            return opened
        }
        throw LCFileExplorerError.sqliteFailed(immutableAttempt.errorMessage ?? roAttempt.errorMessage ?? "Unable to open database.")
    }

    static func loadSQLiteTables(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool
    ) throws -> [LCSQLiteTableInfo] {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let db = try openSQLiteReadOnly(at: url)
            defer { sqlite3_close(db) }

            let query = "SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name COLLATE NOCASE;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw LCFileExplorerError.sqliteFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            var rawTables: [(name: String, sql: String)] = []
            var stepRC = sqlite3_step(stmt)
            while stepRC == SQLITE_ROW {
                let name = readSQLiteTextColumn(stmt: stmt, index: 0)
                let sql = readSQLiteTextColumn(stmt: stmt, index: 1)
                if !name.isEmpty {
                    rawTables.append((name, sql))
                }
                stepRC = sqlite3_step(stmt)
            }
            guard stepRC == SQLITE_DONE else {
                throw LCFileExplorerError.sqliteFailed(String(cString: sqlite3_errmsg(db)))
            }

            return rawTables.map { item in
                let count = queryRowCount(db: db, tableName: item.name)
                return LCSQLiteTableInfo(name: item.name, rowCount: count, createSQL: item.sql)
            }
        }
    }

    private static func readSQLiteTextColumn(stmt: OpaquePointer, index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0 else { return "" }
        let data = Data(bytes: ptr, count: min(byteCount, 4096))
        return String(decoding: data, as: UTF8.self)
    }

    private static func queryRowCount(db: OpaquePointer, tableName: String) -> Int64 {
        guard let quoted = try? quoteSQLiteIdentifier(tableName) else { return -1 }
        let sql = "SELECT COUNT(*) FROM \(quoted);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : -1
    }

    static func loadSQLitePage(
        at url: URL,
        rootURL: URL,
        needsSecurityScope: Bool,
        tableName: String,
        offset: Int,
        limit: Int = 50
    ) throws -> LCSQLitePageResult {
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let db = try openSQLiteReadOnly(at: url)
            defer { sqlite3_close(db) }

            let totalRows = queryRowCount(db: db, tableName: tableName)
            let safeLimit = max(1, min(limit, 200))
            let safeOffset = max(0, offset)
            let quotedTable = try quoteSQLiteIdentifier(tableName)
            let sql = "SELECT * FROM \(quotedTable) LIMIT \(safeLimit) OFFSET \(safeOffset);"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw LCFileExplorerError.sqliteFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let colCount = Int(sqlite3_column_count(stmt))
            let columns: [String] = (0..<colCount).map { idx in
                sqlite3_column_name(stmt, Int32(idx)).map { String(cString: $0) } ?? "col_\(idx)"
            }

            var rows: [[String]] = []
            var stepRC = sqlite3_step(stmt)
            while stepRC == SQLITE_ROW {
                var row: [String] = []
                row.reserveCapacity(colCount)
                for idx in 0..<colCount {
                    let cIdx = Int32(idx)
                    switch sqlite3_column_type(stmt, cIdx) {
                    case SQLITE_NULL:
                        row.append("NULL")
                    case SQLITE_INTEGER:
                        row.append(String(sqlite3_column_int64(stmt, cIdx)))
                    case SQLITE_FLOAT:
                        row.append(String(sqlite3_column_double(stmt, cIdx)))
                    case SQLITE_TEXT:
                        let text = readSQLiteTextColumn(stmt: stmt, index: cIdx)
                        row.append(text.count > 512 ? String(text.prefix(512)) + "…" : text)
                    case SQLITE_BLOB:
                        let byteCount = sqlite3_column_bytes(stmt, cIdx)
                        row.append("<BLOB \(byteCount) B>")
                    default:
                        row.append("")
                    }
                }
                rows.append(row)
                stepRC = sqlite3_step(stmt)
            }
            guard stepRC == SQLITE_DONE else {
                throw LCFileExplorerError.sqliteFailed(String(cString: sqlite3_errmsg(db)))
            }

            return LCSQLitePageResult(
                tableName: tableName,
                columns: columns,
                rows: rows,
                totalRows: totalRows,
                offset: safeOffset,
                limit: safeLimit
            )
        }
    }

    // MARK: - Safe Mutations (Guarded When Writable)

    static func createFolder(named name: String, in directoryURL: URL, rootURL: URL, needsSecurityScope: Bool) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".", trimmed != ".." else {
            throw NSError(domain: "LCFileExplorer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid folder name."])
        }
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let dest = directoryURL.appendingPathComponent(trimmed, isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        }
    }

    static func renameItem(at itemURL: URL, to newName: String, rootURL: URL, needsSecurityScope: Bool) throws {
        guard itemURL.standardizedFileURL != rootURL.standardizedFileURL else {
            throw NSError(domain: "LCFileExplorer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot rename the root container directory."])
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".", trimmed != ".." else {
            throw NSError(domain: "LCFileExplorer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid item name."])
        }
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            let dest = itemURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            try FileManager.default.moveItem(at: itemURL, to: dest)
        }
    }

    static func deleteItem(at itemURL: URL, rootURL: URL, needsSecurityScope: Bool) throws {
        guard itemURL.standardizedFileURL != rootURL.standardizedFileURL else {
            throw NSError(domain: "LCFileExplorer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot delete the root container directory."])
        }
        try withSecurityScope(rootURL: rootURL, needsSecurityScope: needsSecurityScope) {
            try FileManager.default.removeItem(at: itemURL)
        }
    }

    /// Returns a shareable URL for `UIActivityViewController`. For security-scoped
    /// external containers, validates that the target is a regular file within safe
    /// size bounds before staging a temporary copy in `tmp/LCExports`.
    static func stageFileForSharing(at itemURL: URL, rootURL: URL, needsSecurityScope: Bool) throws -> URL {
        guard needsSecurityScope else {
            return itemURL
        }
        return try withSecurityScope(rootURL: rootURL, needsSecurityScope: true) {
            let reader = try LCBoundedFileReader(url: itemURL)
            guard reader.fileSize <= maxStageShareBytes else {
                throw LCFileExplorerError.fileTooLargeForViewer(actualBytes: reader.fileSize, maxBytes: maxStageShareBytes)
            }
            let stagingDir = try lcEnsureExportArtifactDirectory()
                .appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let destURL = stagingDir.appendingPathComponent(itemURL.lastPathComponent)
            try FileManager.default.copyItem(at: itemURL, to: destURL)
            return destURL
        }
    }
}

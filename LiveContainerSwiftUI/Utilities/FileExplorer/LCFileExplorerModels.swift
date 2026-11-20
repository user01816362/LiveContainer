//
//  LCFileExplorerModels.swift
//  LiveContainerSwiftUI
//
//  Immutable Sendable models for LiveContainer's built-in File Explorer,
//  Property List viewer, read-only SQLite viewer, text previewer, and hex viewer.
//

import Foundation

/// High-level semantic classification for a filesystem item inside an app bundle,
/// data container, or tweaks folder.
enum LCFileKind: String, Hashable, Sendable {
    case directory
    case bundle          // .app, .framework, .appex, .bundle
    case machOBinary     // Executable, .dylib, or Mach-O payload
    case plist           // .plist, .strings, .entitlements
    case json            // .json, .geojson, .webmanifest
    case sqlite          // .sqlite, .sqlite3, .db, .storedata
    case text            // .txt, .log, .xml, .md, .h, .m, .swift, .js, .css, .html, .ini, .cfg, .yml, .yaml
    case image           // .png, .jpg, .jpeg, .heic, .gif, .webp, .bmp, .tiff, .ico
    case archive         // .zip, .ipa, .tipa, .deb, .tar, .gz
    case symlink
    case special         // Socket, FIFO, device — never opened for reading
    case binary          // Arbitrary binary data (hex peek / QuickLook)

    var systemImage: String {
        switch self {
        case .directory: return "folder.fill"
        case .bundle: return "shippingbox.fill"
        case .machOBinary: return "cpu.fill"
        case .plist: return "list.bullet.rectangle.portrait.fill"
        case .json: return "curlybraces"
        case .sqlite: return "cylinder.split.1x2.fill"
        case .text: return "doc.text.fill"
        case .image: return "photo.fill"
        case .archive: return "doc.zipper"
        case .symlink: return "link"
        case .special: return "exclamationmark.octagon.fill"
        case .binary: return "doc.fill"
        }
    }

    var badgeTitle: String? {
        switch self {
        case .machOBinary: return "Mach-O"
        case .plist: return "Plist"
        case .json: return "JSON"
        case .sqlite: return "SQLite"
        case .symlink: return "Link"
        case .special: return "Special"
        default: return nil
        }
    }
}

/// Sort ordering options for ``LCFileExplorerView``.
enum LCFileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case size = "Size"
    case modified = "Date Modified"
    case kind = "Kind"

    var id: String { rawValue }
}

/// One filesystem item inside a browsed directory.
struct LCFileEntry: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: LCFileKind
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let symlinkDestination: String?
    let size: Int64
    let modifiedDate: Date?
    let machOExecutableURL: URL?

    var canOpenBinaryInspector: Bool {
        machOExecutableURL != nil
    }

    var formattedSize: String {
        if isDirectory {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Configuration for opening ``LCFileExplorerView`` at a specific LiveContainer root.
struct LCFileExplorerRoot: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let rootURL: URL
    let needsSecurityScope: Bool
    let isReadOnly: Bool
    let readOnlyReason: String?

    init(
        title: String,
        rootURL: URL,
        needsSecurityScope: Bool = false,
        isReadOnly: Bool = false,
        readOnlyReason: String? = nil
    ) {
        self.id = rootURL.path
        self.title = title
        self.rootURL = rootURL
        self.needsSecurityScope = needsSecurityScope
        self.isReadOnly = isReadOnly
        self.readOnlyReason = readOnlyReason
    }
}

/// Recursive node representing a Property List (`.plist` / `.strings`) entry.
struct LCPlistNode: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let typeLabel: String
    let valueSummary: String
    let children: [LCPlistNode]?
}

/// Decoded Property List payload containing both a browsable node tree and raw XML/text view.
struct LCPlistDocument: Sendable {
    let formatLabel: String
    let nodes: [LCPlistNode]
    let rawText: String
}

/// Bounded text/JSON preview payload.
struct LCFileTextPreview: Sendable {
    let text: String
    let totalBytes: UInt64
    let displayedBytes: Int
    let isTruncated: Bool
    let isPrettyJSON: Bool
}

/// One SQLite table summary inside a database file.
struct LCSQLiteTableInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let rowCount: Int64
    let createSQL: String
}

/// Paginated SQLite query result for a single table.
struct LCSQLitePageResult: Sendable {
    let tableName: String
    let columns: [String]
    let rows: [[String]]
    let totalRows: Int64
    let offset: Int
    let limit: Int
}

/// One 4 KiB (or custom-sized) random-access hex page loaded via `pread(2)`.
struct LCHexPage: Sendable {
    let offset: UInt64
    let fileSize: UInt64
    let data: Data
}

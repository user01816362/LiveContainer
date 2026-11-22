//
//  LCPlistValueModel.swift
//  LiveContainerSwiftUI
//
//  Recursive, Sendable Property List value model and presets for editing
//  installed app Info.plist files without losing CFBoolean or numeric fidelity.
//

import CoreFoundation
import Foundation
import SwiftUI

enum LCPlistValueType: String, CaseIterable, Identifiable, Sendable {
    case string
    case integer
    case real
    case boolean
    case date
    case data
    case array
    case dictionary

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .string: return "String"
        case .integer: return "Int"
        case .real: return "Real"
        case .boolean: return "Bool"
        case .date: return "Date"
        case .data: return "Data"
        case .array: return "Array"
        case .dictionary: return "Dict"
        }
    }

    var fullLabel: String {
        switch self {
        case .string: return "String"
        case .integer: return "Integer"
        case .real: return "Real (Decimal)"
        case .boolean: return "Boolean"
        case .date: return "Date"
        case .data: return "Data"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        }
    }

    var systemImage: String {
        switch self {
        case .string: return "textformat"
        case .integer, .real: return "number"
        case .boolean: return "switch.2"
        case .date: return "calendar"
        case .data: return "doc.text.fill"
        case .array: return "list.number"
        case .dictionary: return "curlybraces"
        }
    }

    var badgeColor: Color {
        switch self {
        case .string: return .blue
        case .integer, .real: return .purple
        case .boolean: return .orange
        case .date: return .teal
        case .data: return .indigo
        case .array: return .green
        case .dictionary: return .pink
        }
    }

    var defaultValue: LCPlistValue {
        switch self {
        case .string: return .string("")
        case .integer: return .integer(0)
        case .real: return .real(0.0)
        case .boolean: return .boolean(false)
        case .date: return .date(Date())
        case .data: return .data(Data())
        case .array: return .array([])
        case .dictionary: return .dictionary([:])
        }
    }
}

enum LCPlistValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case array([LCPlistValue])
    case dictionary([String: LCPlistValue])

    var type: LCPlistValueType {
        switch self {
        case .string: return .string
        case .integer: return .integer
        case .real: return .real
        case .boolean: return .boolean
        case .date: return .date
        case .data: return .data
        case .array: return .array
        case .dictionary: return .dictionary
        }
    }

    var summaryText: String {
        switch self {
        case .string(let s):
            return s.isEmpty ? "\"\"" : s
        case .integer(let i):
            return String(i)
        case .real(let d):
            return String(d)
        case .boolean(let b):
            return b ? "YES (true)" : "NO (false)"
        case .date(let date):
            return date.formatted(date: .abbreviated, time: .shortened)
        case .data(let data):
            if data.isEmpty {
                return "0 bytes"
            }
            let prefixHex = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "\(data.count) B (\(prefixHex)\(data.count > 12 ? "…" : ""))"
        case .array(let items):
            return "\(items.count) item\(items.count == 1 ? "" : "s")"
        case .dictionary(let dict):
            return "\(dict.count) key\(dict.count == 1 ? "" : "s")"
        }
    }

    func converted(to targetType: LCPlistValueType) -> LCPlistValue {
        if self.type == targetType {
            return self
        }
        switch (self, targetType) {
        case (_, .string):
            switch self {
            case .integer(let i): return .string(String(i))
            case .real(let r): return .string(String(r))
            case .boolean(let b): return .string(b ? "YES" : "NO")
            case .date(let d): return .string(ISO8601DateFormatter().string(from: d))
            case .data(let data): return .string(data.base64EncodedString())
            default: return .string("")
            }
        case (.string(let s), .integer):
            return .integer(Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case (.real(let r), .integer):
            return .integer(Int64(r))
        case (.boolean(let b), .integer):
            return .integer(b ? 1 : 0)
        case (.string(let s), .real):
            return .real(Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0)
        case (.integer(let i), .real):
            return .real(Double(i))
        case (.boolean(let b), .real):
            return .real(b ? 1.0 : 0.0)
        case (.string(let s), .boolean):
            let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return .boolean(["1", "true", "yes", "on"].contains(normalized))
        case (.integer(let i), .boolean):
            return .boolean(i != 0)
        case (.real(let r), .boolean):
            return .boolean(r != 0)
        case (.string(let s), .data):
            if let decoded = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .data(decoded)
            }
            return .data(Data(s.utf8))
        default:
            return targetType.defaultValue
        }
    }

    static func fromFoundation(_ object: Any) -> LCPlistValue {
        if let str = object as? String {
            return .string(str)
        }
        if let date = object as? Date {
            return .date(date)
        }
        if let data = object as? Data {
            return .data(data)
        }
        // Check CFBoolean before numeric types so booleans are not coerced to 0/1 integers.
        if let num = object as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .boolean(num.boolValue)
            }
            if CFNumberIsFloatType(num) {
                return .real(num.doubleValue)
            }
            return .integer(num.int64Value)
        }
        if let boolValue = object as? Bool {
            return .boolean(boolValue)
        }
        if let array = object as? [Any] {
            return .array(array.map(fromFoundation))
        }
        if let dict = object as? [String: Any] {
            return .dictionary(dict.mapValues(fromFoundation))
        }
        return .string(String(describing: object))
    }

    func toFoundation() -> Any {
        switch self {
        case .string(let s):
            return s
        case .integer(let i):
            return NSNumber(value: i)
        case .real(let r):
            return NSNumber(value: r)
        case .boolean(let b):
            return b
        case .date(let d):
            return d
        case .data(let data):
            return data
        case .array(let items):
            return items.map { $0.toFoundation() }
        case .dictionary(let dict):
            return dict.mapValues { $0.toFoundation() }
        }
    }

    static func dictionaryFromFoundation(_ dict: [String: Any]) -> [String: LCPlistValue] {
        dict.mapValues(fromFoundation)
    }

    static func foundationDictionary(from dict: [String: LCPlistValue]) -> [String: Any] {
        dict.mapValues { $0.toFoundation() }
    }

    static func parseXMLString(_ xml: String) throws -> [String: LCPlistValue] {
        guard let data = xml.data(using: .utf8) else {
            throw "Unable to encode XML text as UTF-8."
        }
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = parsed as? [String: Any] else {
            throw "Top-level Info.plist must be a dictionary (<dict>)."
        }
        return dictionaryFromFoundation(dict)
    }

    static func renderXMLString(from dict: [String: LCPlistValue]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: foundationDictionary(from: dict),
            format: .xml,
            options: 0
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw "Failed to decode generated XML text."
        }
        return string
    }
}

struct LCPlistKeyPreset: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let title: String
    let defaultValue: LCPlistValue

    static let commonInfoPlistKeys: [LCPlistKeyPreset] = [
        LCPlistKeyPreset(key: "CFBundleDisplayName", title: "App Display Name", defaultValue: .string("")),
        LCPlistKeyPreset(key: "CFBundleName", title: "Bundle Name", defaultValue: .string("")),
        LCPlistKeyPreset(key: "CFBundleIdentifier", title: "Bundle Identifier", defaultValue: .string("")),
        LCPlistKeyPreset(key: "CFBundleShortVersionString", title: "Marketing Version", defaultValue: .string("1.0")),
        LCPlistKeyPreset(key: "CFBundleVersion", title: "Build Version", defaultValue: .string("1")),
        LCPlistKeyPreset(key: "MinimumOSVersion", title: "Minimum iOS Version", defaultValue: .string("15.0")),
        LCPlistKeyPreset(key: "UIFileSharingEnabled", title: "Enable Files App Sharing", defaultValue: .boolean(true)),
        LCPlistKeyPreset(key: "LSSupportsOpeningDocumentsInPlace", title: "Open Documents in Place", defaultValue: .boolean(true)),
        LCPlistKeyPreset(key: "UISupportsDocumentBrowser", title: "Document Browser Support", defaultValue: .boolean(true)),
        LCPlistKeyPreset(key: "UIDesignRequiresCompatibility", title: "Disable Liquid Glass Compatibility", defaultValue: .boolean(true)),
        LCPlistKeyPreset(key: "UIRequiresFullScreen", title: "Requires Full Screen", defaultValue: .boolean(false)),
        LCPlistKeyPreset(key: "UIStatusBarHidden", title: "Hide Status Bar", defaultValue: .boolean(false)),
        LCPlistKeyPreset(key: "ITSAppUsesNonExemptEncryption", title: "Uses Non-Exempt Encryption", defaultValue: .boolean(false)),
        LCPlistKeyPreset(key: "UIBackgroundModes", title: "Background Modes", defaultValue: .array([.string("fetch")])),
        LCPlistKeyPreset(
            key: "NSAppTransportSecurity",
            title: "Allow Arbitrary Loads (HTTP)",
            defaultValue: .dictionary(["NSAllowsArbitraryLoads": .boolean(true)])
        )
    ]
}

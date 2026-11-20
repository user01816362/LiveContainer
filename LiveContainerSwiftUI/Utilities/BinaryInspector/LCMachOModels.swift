//
//  LCMachOModels.swift
//  LiveContainerSwiftUI
//
//  Immutable Sendable data models for LiveContainer's native Mach-O binary
//  inspector, compatibility doctor, Objective-C/Swift metadata viewer,
//  symbol/export analyzer, and string extractor.
//

import Foundation

/// Errors thrown by LiveContainer's native Mach-O analysis engine.
enum LCMachOInspectorError: LocalizedError, Sendable {
    case notMachOFile
    case truncatedHeader(expected: Int, available: UInt64)
    case invalidSliceIndex(Int)
    case malformedLoadCommands(String)
    case encryptedBinaryCannotDump
    case unsupportedArchitecture(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notMachOFile:
            return "This file is not a valid Mach-O binary."
        case let .truncatedHeader(expected, available):
            return "Truncated Mach-O header (expected \(expected) bytes, file has \(available) bytes)."
        case let .invalidSliceIndex(index):
            return "Architecture slice #\(index) does not exist in this binary."
        case let .malformedLoadCommands(reason):
            return "Malformed Mach-O load commands: \(reason)"
        case .encryptedBinaryCannotDump:
            return "This binary is FairPlay-encrypted (cryptid != 0). Runtime metadata sections cannot be decoded from encrypted pages."
        case let .unsupportedArchitecture(arch):
            return "Metadata decoding is not supported for architecture '\(arch)'."
        case let .exportFailed(reason):
            return "Unable to generate export artifact: \(reason)"
        }
    }
}

/// Kind of inspectable Mach-O target inside an app bundle or tweaks directory.
enum LCMachOTargetKind: String, Sendable {
    case appExecutable = "Main Executable"
    case framework = "Framework"
    case dylib = "Dylib"
    case plugin = "App Extension"
    case standalone = "Binary"

    var systemImage: String {
        switch self {
        case .appExecutable: return "app.badge.checkmark"
        case .framework: return "shippingbox.fill"
        case .dylib: return "building.columns.fill"
        case .plugin: return "puzzlepiece.extension.fill"
        case .standalone: return "cpu.fill"
        }
    }
}

/// Represents a single inspectable Mach-O binary target (e.g., main executable,
/// embedded framework, dylib, or plugin).
struct LCMachOTargetItem: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let relativePath: String
    let executableURL: URL
    let bundleURL: URL?
    let kind: LCMachOTargetKind
}

/// Describes one architecture slice inside a thin or universal (fat) Mach-O binary.
struct LCMachOArchitectureSlice: Identifiable, Hashable, Sendable {
    var id: Int { index }
    let index: Int
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let architectureName: String
    let fileOffset: UInt64
    let size: UInt64
    let is64Bit: Bool
    let isByteSwapped: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(size, UInt64(Int64.max))), countStyle: .file)
    }
}

/// Parsed Mach-O header, build metadata, encryption status, and security posture.
struct LCMachOHeaderInfo: Sendable {
    let magic: UInt32
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let architectureName: String
    let fileType: UInt32
    let fileTypeName: String
    let numberOfCommands: UInt32
    let sizeOfCommands: UInt32
    let flags: UInt32
    let flagNames: [String]
    let is64Bit: Bool
    let isPIE: Bool
    let isEncrypted: Bool
    let cryptID: UInt32
    let uuid: String?
    let platformName: String?
    let minOSVersion: String?
    let sdkVersion: String?
    let sourceVersion: String?
    let entryPointOffset: UInt64?
    let hasChainedFixups: Bool
    let hasExportsTrie: Bool
    let hasCodeSignature: Bool
    let hasObjCMetadata: Bool
    let hasSwiftMetadata: Bool
    let usesARC: Bool
    let hasStackCanary: Bool
    let isRestricted: Bool
    let hasDisabledTweakLoaderMarker: Bool
}

/// Summary of a single Mach-O load command.
struct LCMachOLoadCommandInfo: Identifiable, Sendable {
    var id: Int { index }
    let index: Int
    let cmd: UInt32
    let name: String
    let cmdSize: UInt32
    let fileOffset: UInt64
    let summary: String
}

/// A Mach-O section within a segment.
struct LCMachOSectionInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(segmentName),\(sectionName)@\(fileOffset)" }
    let sectionName: String
    let segmentName: String
    let vmAddress: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let flags: UInt32

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(size, UInt64(Int64.max))), countStyle: .file)
    }
}

/// A Mach-O segment and its child sections.
struct LCMachOSegmentInfo: Identifiable, Sendable {
    var id: String { "\(name)@\(vmAddress)" }
    let name: String
    let vmAddress: UInt64
    let vmSize: UInt64
    let fileOffset: UInt64
    let fileSize: UInt64
    let maxProtection: UInt32
    let initProtection: UInt32
    let protectionString: String
    let sections: [LCMachOSectionInfo]
}

/// Linkage type for a dynamic library load command.
enum LCMachODylibKind: String, Sendable {
    case id = "ID"
    case required = "Required"
    case weak = "Weak"
    case reexport = "Re-export"
    case upward = "Upward"
    case lazy = "Lazy"
}

/// A dynamic library referenced by a Mach-O binary.
struct LCMachODylibDependency: Identifiable, Sendable {
    var id: String { "\(index):\(kind.rawValue):\(path)" }
    let index: Int
    let path: String
    let kind: LCMachODylibKind
    let currentVersion: String
    let compatibilityVersion: String
    let statusNote: String?
    let isPotentiallyBroken: Bool
}

/// Parsed `LC_CODE_SIGNATURE` SuperBlob, CodeDirectory, and Entitlements metadata.
struct LCMachOCodeSignInfo: Sendable {
    let isSigned: Bool
    let isAdHoc: Bool
    let identifier: String?
    let teamIdentifier: String?
    let cdHashHex: String?
    let hashTypeName: String?
    let flags: UInt32
    let flagNames: [String]
    let entitlementsXML: String?
    let entitlementsSummary: [(key: String, value: String)]
    let hasDEREntitlements: Bool
    let derEntitlementsSize: Int
    let hasCMSSignature: Bool
    let cmsSignatureSize: Int
    let kernelSignatureValid: Bool?

    static let unsigned = LCMachOCodeSignInfo(
        isSigned: false,
        isAdHoc: false,
        identifier: nil,
        teamIdentifier: nil,
        cdHashHex: nil,
        hashTypeName: nil,
        flags: 0,
        flagNames: [],
        entitlementsXML: nil,
        entitlementsSummary: [],
        hasDEREntitlements: false,
        derEntitlementsSize: 0,
        hasCMSSignature: false,
        cmsSignatureSize: 0,
        kernelSignatureValid: nil
    )
}

/// Severity level for a LiveContainer Compatibility Doctor finding.
enum LCMachOFindingSeverity: String, Sendable {
    case ok = "OK"
    case warning = "Warning"
    case error = "Issue"

    var systemImage: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Single diagnostic check produced by the LiveContainer Compatibility Doctor.
struct LCMachOCompatibilityFinding: Identifiable, Sendable {
    let id: String
    let severity: LCMachOFindingSeverity
    let title: String
    let detail: String
}

/// Complete overview result for a Mach-O binary slice.
struct LCMachOOverviewResult: Sendable {
    let fileURL: URL
    let fileName: String
    let fileSize: UInt64
    let slices: [LCMachOArchitectureSlice]
    let selectedSlice: LCMachOArchitectureSlice
    let header: LCMachOHeaderInfo
    let segments: [LCMachOSegmentInfo]
    let loadCommands: [LCMachOLoadCommandInfo]
    let dylibs: [LCMachODylibDependency]
    let rpaths: [String]
    let codeSign: LCMachOCodeSignInfo
    let compatibilityFindings: [LCMachOCompatibilityFinding]
    let diagnostics: [String]
}

// MARK: - Objective-C Metadata Models

struct LCObjCMethodInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(isClassMethod ? "+" : "-")\(name)@\(implementationAddress)" }
    let name: String
    let typeEncoding: String
    let isClassMethod: Bool
    let implementationAddress: UInt64
    let formattedDeclaration: String
}

struct LCObjCPropertyInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(name):\(attributes)" }
    let name: String
    let attributes: String
    let formattedDeclaration: String
}

struct LCObjCIvarInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(name):\(offset)" }
    let name: String
    let typeEncoding: String
    let offset: UInt32
    let formattedDeclaration: String
}

struct LCObjCClassInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(name)@\(vmAddress)" }
    let name: String
    let superclassName: String?
    let vmAddress: UInt64
    let instanceSize: UInt32
    let isSwiftClass: Bool
    let protocols: [String]
    let ivars: [LCObjCIvarInfo]
    let properties: [LCObjCPropertyInfo]
    let instanceMethods: [LCObjCMethodInfo]
    let classMethods: [LCObjCMethodInfo]
}

struct LCObjCProtocolInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(name)@\(vmAddress)" }
    let name: String
    let vmAddress: UInt64
    let adoptedProtocols: [String]
    let properties: [LCObjCPropertyInfo]
    let requiredInstanceMethods: [LCObjCMethodInfo]
    let requiredClassMethods: [LCObjCMethodInfo]
    let optionalInstanceMethods: [LCObjCMethodInfo]
    let optionalClassMethods: [LCObjCMethodInfo]
}

struct LCObjCCategoryInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(className)+\(name)@\(vmAddress)" }
    let name: String
    let className: String
    let vmAddress: UInt64
    let protocols: [String]
    let properties: [LCObjCPropertyInfo]
    let instanceMethods: [LCObjCMethodInfo]
    let classMethods: [LCObjCMethodInfo]
}

struct LCObjCDumpResult: Sendable {
    let classes: [LCObjCClassInfo]
    let protocols: [LCObjCProtocolInfo]
    let categories: [LCObjCCategoryInfo]
    let diagnostics: [String]
    let wasTruncated: Bool
}

// MARK: - Swift Metadata Models

enum LCSwiftTypeKind: String, Sendable {
    case structType = "struct"
    case classType = "class"
    case enumType = "enum"
    case protocolType = "protocol"
}

struct LCSwiftFieldInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(name):\(typeName):\(isIndirect)" }
    let name: String
    let typeName: String
    let isMutable: Bool
    let isIndirect: Bool
}

struct LCSwiftTypeInfo: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(name)@\(vmAddress)" }
    let name: String
    let kind: LCSwiftTypeKind
    let vmAddress: UInt64
    let fields: [LCSwiftFieldInfo]
}

struct LCSwiftMetadataResult: Sendable {
    let types: [LCSwiftTypeInfo]
    let diagnostics: [String]
    let wasTruncated: Bool
}

// MARK: - Symbol & String Models

enum LCMachOSymbolScope: String, CaseIterable, Identifiable, Sendable {
    case exported = "Exported"
    case external = "External"
    case undefined = "Undefined"
    case local = "Local"

    var id: String { rawValue }
}

struct LCMachOSymbolInfo: Identifiable, Hashable, Sendable {
    let id: String
    let rawName: String
    let demangledName: String
    let address: UInt64
    let scope: LCMachOSymbolScope
    let isSwift: Bool
    let isObjC: Bool
}

struct LCMachOSymbolsResult: Sendable {
    let symbols: [LCMachOSymbolInfo]
    let exportCount: Int
    let symtabCount: Int
    let wasTruncated: Bool
    let diagnostics: [String]
}

enum LCMachOStringCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case url = "URLs"
    case urlScheme = "Schemes"
    case path = "Paths"
    case identifier = "Identifiers"
    case general = "Other"

    var id: String { rawValue }
}

struct LCMachOStringEntry: Identifiable, Hashable, Sendable {
    var id: String { "\(fileOffset):\(value.prefix(32))" }
    let value: String
    let fileOffset: UInt64
    let vmAddress: UInt64
    let sectionName: String
    let category: LCMachOStringCategory
}

struct LCMachOStringsResult: Sendable {
    let entries: [LCMachOStringEntry]
    let wasTruncated: Bool
    let diagnostics: [String]
}

// MARK: - Export Format

enum LCMachOExportFormat: String, CaseIterable, Identifiable, Sendable {
    case combinedHeader = "Combined Objective-C Header (.h)"
    case headersZip = "Full Headers Archive (.zip)"
    case markdownReport = "Analysis Report (.md)"
    case jsonReport = "Machine-Readable Report (.json)"

    var id: String { rawValue }
}

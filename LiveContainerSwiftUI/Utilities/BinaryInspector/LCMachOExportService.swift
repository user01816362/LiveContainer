//
//  LCMachOExportService.swift
//  LiveContainerSwiftUI
//
//  Generates shareable Objective-C `.h` header files, full `Headers.zip`
//  archives (via Foundation `NSFileCoordinator(.forUploading)`), Markdown
//  analysis reports, and machine-readable JSON reports in `tmp/LCExports`.
//

import Foundation

/// Pure nonisolated export generator for LiveContainer's Binary Inspector.
enum LCMachOExportService {

    /// Writes a single Objective-C `.h` file to `tmp/LCExports` and returns its URL.
    static func exportSingleHeader(name: String, content: String) throws -> URL {
        let safeName = sanitizeFilename(name)
        let fileURL = try lcExportArtifactFileURL(fileName: "\(safeName).h")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Exports a full archive containing per-class/protocol/category `.h` headers,
    /// Swift nominal types summary, and Markdown overview report as a `.zip` file.
    static func exportHeadersZip(
        overview: LCMachOOverviewResult,
        objcDump: LCObjCDumpResult?,
        swiftMetadata: LCSwiftMetadataResult?
    ) throws -> URL {
        let fm = FileManager.default
        let safeBinary = sanitizeFilename(overview.fileName)
        let workDir = fm.temporaryDirectory.appendingPathComponent("LCHeaders-\(UUID().uuidString)", isDirectory: true)
        let packageDir = workDir.appendingPathComponent("\(safeBinary)-Headers", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }

        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)

        // Write Markdown overview
        let reportMD = renderMarkdownReport(overview: overview, objcDump: objcDump, swiftMetadata: swiftMetadata)
        try reportMD.write(to: packageDir.appendingPathComponent("AnalysisReport.md"), atomically: true, encoding: .utf8)

        // Write Entitlements XML if present
        if let entXML = overview.codeSign.entitlementsXML {
            try entXML.write(to: packageDir.appendingPathComponent("Entitlements.plist"), atomically: true, encoding: .utf8)
        }

        // Write ObjC headers (with case-insensitive collision deduplication & cancellation checks)
        if let objcDump {
            let classesDir = packageDir.appendingPathComponent("Classes", isDirectory: true)
            let protocolsDir = packageDir.appendingPathComponent("Protocols", isDirectory: true)
            let categoriesDir = packageDir.appendingPathComponent("Categories", isDirectory: true)

            if !objcDump.classes.isEmpty {
                try fm.createDirectory(at: classesDir, withIntermediateDirectories: true)
                var seenNames = Set<String>()
                for cls in objcDump.classes {
                    try Task.checkCancellation()
                    let header = LCMachOObjCDumper.renderHeader(for: cls)
                    let fileName = uniqueFilename(stem: sanitizeFilename(cls.name), ext: "h", seenLowercased: &seenNames)
                    try header.write(to: classesDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                }
            }
            if !objcDump.protocols.isEmpty {
                try fm.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
                var seenNames = Set<String>()
                for proto in objcDump.protocols {
                    try Task.checkCancellation()
                    let header = LCMachOObjCDumper.renderHeader(for: proto)
                    let fileName = uniqueFilename(stem: "\(sanitizeFilename(proto.name))-Protocol", ext: "h", seenLowercased: &seenNames)
                    try header.write(to: protocolsDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                }
            }
            if !objcDump.categories.isEmpty {
                try fm.createDirectory(at: categoriesDir, withIntermediateDirectories: true)
                var seenNames = Set<String>()
                for cat in objcDump.categories {
                    try Task.checkCancellation()
                    let header = LCMachOObjCDumper.renderHeader(for: cat)
                    let fileName = uniqueFilename(stem: "\(sanitizeFilename(cat.className))+\(sanitizeFilename(cat.name))", ext: "h", seenLowercased: &seenNames)
                    try header.write(to: categoriesDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                }
            }

            try Task.checkCancellation()
            let combined = LCMachOObjCDumper.renderCombinedHeader(binaryName: overview.fileName, dump: objcDump)
            try combined.write(to: packageDir.appendingPathComponent("\(safeBinary)-AllHeaders.h"), atomically: true, encoding: .utf8)
        }

        // Write Swift types summary
        if let swiftMetadata, !swiftMetadata.types.isEmpty {
            try Task.checkCancellation()
            let swiftText = renderSwiftSummary(binaryName: overview.fileName, metadata: swiftMetadata)
            try swiftText.write(to: packageDir.appendingPathComponent("SwiftTypes.swift"), atomically: true, encoding: .utf8)
        }

        // Zip directory using Foundation NSFileCoordinator(.forUploading)
        let destZipURL = try lcExportArtifactFileURL(fileName: "\(safeBinary)-Headers-\(UUID().uuidString.prefix(8)).zip")
        if fm.fileExists(atPath: destZipURL.path) {
            try fm.removeItem(at: destZipURL)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: packageDir, options: .forUploading, error: &coordinatorError) { zipTempURL in
            do {
                try fm.copyItem(at: zipTempURL, to: destZipURL)
            } catch {
                copyError = error
            }
        }
        if let err = coordinatorError ?? copyError {
            throw LCMachOInspectorError.exportFailed(err.localizedDescription)
        }
        guard fm.fileExists(atPath: destZipURL.path) else {
            throw LCMachOInspectorError.exportFailed("Archive coordinator did not produce a zip file.")
        }
        return destZipURL
    }

    /// Writes a formatted Markdown analysis report to `tmp/LCExports`.
    static func exportMarkdownReport(
        overview: LCMachOOverviewResult,
        objcDump: LCObjCDumpResult?,
        swiftMetadata: LCSwiftMetadataResult?
    ) throws -> URL {
        let safeName = sanitizeFilename(overview.fileName)
        let url = try lcExportArtifactFileURL(fileName: "\(safeName)-Report.md")
        let md = renderMarkdownReport(overview: overview, objcDump: objcDump, swiftMetadata: swiftMetadata)
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes a machine-readable JSON analysis report to `tmp/LCExports`.
    static func exportJSONReport(
        overview: LCMachOOverviewResult,
        objcDump: LCObjCDumpResult?,
        swiftMetadata: LCSwiftMetadataResult?
    ) throws -> URL {
        let safeName = sanitizeFilename(overview.fileName)
        let url = try lcExportArtifactFileURL(fileName: "\(safeName)-Report.json")

        let payload: [String: Any] = [
            "fileName": overview.fileName,
            "fileSize": overview.fileSize,
            "architecture": overview.header.architectureName,
            "fileType": overview.header.fileTypeName,
            "uuid": overview.header.uuid ?? "",
            "platform": overview.header.platformName ?? "",
            "minOS": overview.header.minOSVersion ?? "",
            "sdk": overview.header.sdkVersion ?? "",
            "isPIE": overview.header.isPIE,
            "isEncrypted": overview.header.isEncrypted,
            "usesARC": overview.header.usesARC,
            "hasStackCanary": overview.header.hasStackCanary,
            "hasChainedFixups": overview.header.hasChainedFixups,
            "hasExportsTrie": overview.header.hasExportsTrie,
            "codeSign": [
                "isSigned": overview.codeSign.isSigned,
                "isAdHoc": overview.codeSign.isAdHoc,
                "identifier": overview.codeSign.identifier ?? "",
                "teamIdentifier": overview.codeSign.teamIdentifier ?? "",
                "cdHash": overview.codeSign.cdHashHex ?? "",
                "flags": overview.codeSign.flagNames,
                "entitlements": Dictionary(overview.codeSign.entitlementsSummary.map { ($0.key, $0.value) }, uniquingKeysWith: { _, latest in latest }),
            ],
            "compatibilityFindings": overview.compatibilityFindings.map { [
                "severity": $0.severity.rawValue,
                "title": $0.title,
                "detail": $0.detail,
            ] },
            "dylibs": overview.dylibs.map { [
                "path": $0.path,
                "kind": $0.kind.rawValue,
                "currentVersion": $0.currentVersion,
                "isPotentiallyBroken": $0.isPotentiallyBroken,
            ] },
            "rpaths": overview.rpaths,
            "segments": overview.segments.map { [
                "name": $0.name,
                "vmAddress": String(format: "0x%llX", $0.vmAddress),
                "vmSize": $0.vmSize,
                "protection": $0.protectionString,
                "sections": $0.sections.map(\.sectionName),
            ] },
            "objcSummary": [
                "classes": objcDump?.classes.count ?? 0,
                "protocols": objcDump?.protocols.count ?? 0,
                "categories": objcDump?.categories.count ?? 0,
            ],
            "swiftSummary": [
                "types": swiftMetadata?.types.count ?? 0,
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Renderers

    static func renderMarkdownReport(
        overview: LCMachOOverviewResult,
        objcDump: LCObjCDumpResult?,
        swiftMetadata: LCSwiftMetadataResult?
    ) -> String {
        let h = overview.header
        var lines: [String] = [
            "# LiveContainer Binary Analysis Report — `\(overview.fileName)`",
            "",
            "## Binary Overview",
            "- **Architecture**: `\(h.architectureName)` (\(overview.slices.map(\.architectureName).joined(separator: ", ")))",
            "- **File Type**: `\(h.fileTypeName)`",
            "- **File Size**: \(ByteCountFormatter.string(fromByteCount: Int64(min(overview.fileSize, UInt64(Int64.max))), countStyle: .file))",
            "- **UUID**: `\(h.uuid ?? "None")`",
            "- **Platform / MinOS / SDK**: \(h.platformName ?? "Unknown") / \(h.minOSVersion ?? "?") / \(h.sdkVersion ?? "?")",
            "- **Hardening**: PIE=\(h.isPIE), ARC=\(h.usesARC), StackCanary=\(h.hasStackCanary), ChainedFixups=\(h.hasChainedFixups)",
            "",
            "## LiveContainer Compatibility Doctor",
        ]
        for finding in overview.compatibilityFindings {
            lines.append("- **[\(finding.severity.rawValue)] \(finding.title)**: \(finding.detail)")
        }

        lines.append("")
        lines.append("## Code Signature & Entitlements")
        lines.append("- **Signed**: \(overview.codeSign.isSigned) (Ad-Hoc: \(overview.codeSign.isAdHoc))")
        if let ident = overview.codeSign.identifier { lines.append("- **Identifier**: `\(ident)`") }
        if let team = overview.codeSign.teamIdentifier { lines.append("- **Team ID**: `\(team)`") }
        if let cdHash = overview.codeSign.cdHashHex { lines.append("- **CDHash**: `\(cdHash)`") }
        if !overview.codeSign.entitlementsSummary.isEmpty {
            lines.append("- **Entitlements**:")
            for pair in overview.codeSign.entitlementsSummary {
                lines.append("  - `\(pair.key)`: `\(pair.value)`")
            }
        }

        lines.append("")
        lines.append("## Linked Dylibs (\(overview.dylibs.count))")
        for dep in overview.dylibs {
            let warn = dep.isPotentiallyBroken ? " ⚠️" : ""
            lines.append("- `[\(dep.kind.rawValue)]` `\(dep.path)` (\(dep.currentVersion))\(warn)")
        }

        if let objcDump {
            lines.append("")
            lines.append("## Objective-C Metadata")
            lines.append("- Classes: \(objcDump.classes.count), Protocols: \(objcDump.protocols.count), Categories: \(objcDump.categories.count)")
        }
        if let swiftMetadata {
            lines.append("")
            lines.append("## Swift Metadata")
            lines.append("- Nominal Types & Protocols: \(swiftMetadata.types.count)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderSwiftSummary(binaryName: String, metadata: LCSwiftMetadataResult) -> String {
        var lines: [String] = [
            "//",
            "//  SwiftTypes.swift",
            "//  Generated by LiveContainer Binary Inspector for \(binaryName)",
            "//",
            ""
        ]
        for type in metadata.types {
            lines.append("\(type.kind.rawValue) \(type.name) {")
            for field in type.fields {
                if type.kind == .enumType {
                    let indirectStr = field.isIndirect ? "indirect " : ""
                    if field.typeName == "Any" {
                        lines.append("    \(indirectStr)case \(field.name)")
                    } else {
                        lines.append("    \(indirectStr)case \(field.name)(\(field.typeName))")
                    }
                } else {
                    let kw = field.isMutable ? "var" : "let"
                    lines.append("    \(kw) \(field.name): \(field.typeName)")
                }
            }
            lines.append("}")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func uniqueFilename(stem: String, ext: String, seenLowercased: inout Set<String>) -> String {
        let base = "\(stem).\(ext)"
        if seenLowercased.insert(base.lowercased()).inserted {
            return base
        }
        var suffix = 2
        while true {
            let candidate = "\(stem)_\(suffix).\(ext)"
            if seenLowercased.insert(candidate.lowercased()).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "Binary" : String(cleaned.prefix(100))
    }
}

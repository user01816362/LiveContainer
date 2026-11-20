//
//  LCBinaryOverviewSection.swift
//  LiveContainerSwiftUI
//
//  Overview tab for LiveContainer's Binary Inspector: LiveContainer Compatibility
//  Doctor, Mach-O Header & Security Hardening badges, Code Signature &
//  Entitlements viewer, and parser diagnostics.
//

import SwiftUI
import UIKit

/// Renders the Overview tab for a parsed Mach-O binary slice.
struct LCBinaryOverviewSection: View {
    let overview: LCMachOOverviewResult

    @State private var rawEntitlementsItem: LCRawTextItem?
    @State private var copiedFeedback: String?

    var body: some View {
        List {
            LCBinaryCompatibilitySection(findings: overview.compatibilityFindings)
            LCBinaryHardeningSection(header: overview.header)
            LCBinaryHeaderInfoSection(
                overview: overview,
                onCopy: { label, value in
                    UIPasteboard.general.string = value
                    copiedFeedback = label
                }
            )
            LCBinaryCodeSignSection(
                codeSign: overview.codeSign,
                onOpenRawXML: {
                    if let xml = overview.codeSign.entitlementsXML {
                        rawEntitlementsItem = LCRawTextItem(title: "Entitlements XML", text: xml)
                    }
                },
                onCopy: { label, value in
                    UIPasteboard.general.string = value
                    copiedFeedback = label
                }
            )
            if !overview.diagnostics.isEmpty {
                Section("Parser Diagnostics") {
                    ForEach(Array(overview.diagnostics.enumerated()), id: \.offset) { _, msg in
                        Label(msg, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $rawEntitlementsItem) { item in
            LCRawTextSheetView(title: item.title, text: item.text)
        }
        .overlay(alignment: .bottom) {
            if let copiedFeedback {
                Text("Copied \(copiedFeedback)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: copiedFeedback) {
            guard copiedFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copiedFeedback = nil
        }
    }
}

private struct LCBinaryCompatibilitySection: View {
    let findings: [LCMachOCompatibilityFinding]

    var body: some View {
        Section("LiveContainer Compatibility Doctor") {
            ForEach(findings) { finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: finding.severity.systemImage)
                        .foregroundStyle(color(for: finding.severity))
                        .font(.body)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.title)
                            .font(.subheadline.weight(.semibold))
                        Text(finding.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func color(for severity: LCMachOFindingSeverity) -> Color {
        switch severity {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct LCBinaryHardeningSection: View {
    let header: LCMachOHeaderInfo

    var body: some View {
        Section("Runtime & Hardening") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LCBinaryPill(label: header.architectureName, tint: .blue)
                    LCBinaryPill(label: header.isEncrypted ? "Encrypted" : "Decrypted", tint: header.isEncrypted ? .red : .green)
                    LCBinaryPill(label: header.isPIE ? "PIE" : "No PIE", tint: header.isPIE ? .green : .orange)
                    LCBinaryPill(label: header.usesARC ? "ARC" : "MRC", tint: header.usesARC ? .teal : .secondary)
                    LCBinaryPill(label: header.hasStackCanary ? "Canary" : "No Canary", tint: header.hasStackCanary ? .green : .secondary)
                    if header.hasChainedFixups {
                        LCBinaryPill(label: "Chained Fixups", tint: .indigo)
                    }
                    if header.hasExportsTrie {
                        LCBinaryPill(label: "Exports Trie", tint: .purple)
                    }
                    if header.hasObjCMetadata {
                        LCBinaryPill(label: "ObjC", tint: .orange)
                    }
                    if header.hasSwiftMetadata {
                        LCBinaryPill(label: "Swift", tint: .pink)
                    }
                    if header.isRestricted {
                        LCBinaryPill(label: "__RESTRICT", tint: .red)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        }
    }
}

private struct LCBinaryPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

private struct LCBinaryHeaderInfoSection: View {
    let overview: LCMachOOverviewResult
    let onCopy: (String, String) -> Void

    var body: some View {
        let h = overview.header
        Section("Mach-O Header") {
            LabeledContent("File Name", value: overview.fileName)
            LabeledContent("File Size", value: ByteCountFormatter.string(fromByteCount: Int64(min(overview.fileSize, UInt64(Int64.max))), countStyle: .file))
            LabeledContent("File Type", value: h.fileTypeName)
            LabeledContent("Architecture", value: "\(h.architectureName) (\(h.is64Bit ? "64-bit" : "32-bit"))")
            if let platform = h.platformName {
                LabeledContent("Platform", value: platform)
            }
            if let minOS = h.minOSVersion {
                LabeledContent("Minimum OS", value: minOS)
            }
            if let sdk = h.sdkVersion {
                LabeledContent("Built With SDK", value: sdk)
            }
            if let src = h.sourceVersion {
                LabeledContent("Source Version", value: src)
            }
            if let entry = h.entryPointOffset {
                LabeledContent("Entry Point", value: String(format: "0x%llX", entry))
            }
            LabeledContent("Load Commands", value: "\(h.numberOfCommands) (\(h.sizeOfCommands) B)")
            if let uuid = h.uuid {
                Button {
                    onCopy("UUID", uuid)
                } label: {
                    HStack {
                        Text("UUID")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(uuid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !h.flagNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Header Flags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(h.flagNames.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct LCBinaryCodeSignSection: View {
    let codeSign: LCMachOCodeSignInfo
    let onOpenRawXML: () -> Void
    let onCopy: (String, String) -> Void

    var body: some View {
        Section("Code Signature & Entitlements") {
            LabeledContent("Status") {
                if !codeSign.isSigned {
                    Text("Unsigned").foregroundStyle(.orange)
                } else if codeSign.isAdHoc {
                    Text("Ad-Hoc Signed").foregroundStyle(.orange)
                } else {
                    Text("Signed").foregroundStyle(.green)
                }
            }

            if let kernelValid = codeSign.kernelSignatureValid {
                LabeledContent("Device Signature Check") {
                    Text(kernelValid ? "Valid" : "Mismatch / Needs Re-sign")
                        .foregroundStyle(kernelValid ? .green : .orange)
                }
            }

            if let ident = codeSign.identifier {
                Button {
                    onCopy("Signing ID", ident)
                } label: {
                    LabeledContent("Signing Identifier", value: ident)
                        .foregroundStyle(.primary)
                }
            }
            if let team = codeSign.teamIdentifier {
                Button {
                    onCopy("Team ID", team)
                } label: {
                    LabeledContent("Team ID", value: team)
                        .foregroundStyle(.primary)
                }
            }
            if let cdHash = codeSign.cdHashHex {
                Button {
                    onCopy("CDHash", cdHash)
                } label: {
                    HStack {
                        Text("CDHash")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(cdHash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let hashType = codeSign.hashTypeName {
                LabeledContent("Hash Algorithm", value: hashType)
            }
            if !codeSign.flagNames.isEmpty {
                LabeledContent("CS Flags", value: codeSign.flagNames.joined(separator: ", "))
            }
            if codeSign.hasDEREntitlements {
                LabeledContent("DER Entitlements", value: "Present (\(codeSign.derEntitlementsSize) B)")
            }
            if codeSign.hasCMSSignature {
                LabeledContent("CMS Certificate Blob", value: "\(codeSign.cmsSignatureSize) B")
            }

            if !codeSign.entitlementsSummary.isEmpty {
                DisclosureGroup("Entitlements (\(codeSign.entitlementsSummary.count))") {
                    ForEach(Array(codeSign.entitlementsSummary.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.key)
                                .font(.caption.monospaced().weight(.semibold))
                            Text(pair.value)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if codeSign.entitlementsXML != nil {
                Button("View Raw Entitlements XML", systemImage: "chevron.left.forwardslash.chevron.right") {
                    onOpenRawXML()
                }
            }
        }
    }
}

private struct LCRawTextItem: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// Modal raw monospace viewer with Copy action (used for Entitlements XML and single headers).
struct LCRawTextSheetView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

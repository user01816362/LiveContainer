//
//  LCFilePreviewView.swift
//  LiveContainerSwiftUI
//
//  Smart preview dispatcher supporting Property Lists, JSON/Text/Logs, SQLite
//  databases, Images, and paginated 4 KiB random-access Hex Peek.
//

import SwiftUI
import UIKit

/// Dispatches a selected ``LCFileEntry`` to the most appropriate read-only viewer,
/// with an instant toggle to paginated 4 KiB Hex Peek for any regular file.
struct LCFilePreviewView: View {
    let entry: LCFileEntry
    let rootURL: URL
    let needsSecurityScope: Bool
    var onInspectBinary: ((URL) -> Void)? = nil

    @State private var forceHexMode = false
    @State private var stagedShareURL: URL?
    @State private var shareErrorMessage: String?
    @State private var inspectedBinaryURL: URL?

    var body: some View {
        Group {
            if entry.kind == .special {
                ContentUnavailableView(
                    "Special File",
                    systemImage: "exclamationmark.octagon",
                    description: Text(LCFileExplorerError.specialFileUnsupported.localizedDescription)
                )
            } else if entry.kind == .symlink {
                List {
                    Section("Symbolic Link") {
                        LabeledContent("Name", value: entry.name)
                        LabeledContent("Path", value: entry.url.path)
                        LabeledContent("Destination", value: entry.symlinkDestination ?? "Unknown")
                    }
                }
                .listStyle(.insetGrouped)
            } else if forceHexMode {
                LCHexPageViewer(
                    fileURL: entry.url,
                    rootURL: rootURL,
                    needsSecurityScope: needsSecurityScope
                )
            } else {
                switch entry.kind {
                case .plist:
                    LCPlistViewerView(
                        fileURL: entry.url,
                        rootURL: rootURL,
                        needsSecurityScope: needsSecurityScope
                    )
                case .sqlite:
                    LCSQLiteViewerView(
                        fileURL: entry.url,
                        rootURL: rootURL,
                        needsSecurityScope: needsSecurityScope
                    )
                case .json, .text:
                    LCTextFileViewer(
                        fileURL: entry.url,
                        rootURL: rootURL,
                        needsSecurityScope: needsSecurityScope,
                        attemptPrettyJSON: entry.kind == .json
                    )
                case .image:
                    LCImageFileViewer(
                        fileURL: entry.url,
                        rootURL: rootURL,
                        needsSecurityScope: needsSecurityScope
                    )
                case .machOBinary, .binary, .archive, .directory, .bundle:
                    VStack(spacing: 0) {
                        if let machOURL = entry.machOExecutableURL {
                            HStack(spacing: 10) {
                                Image(systemName: "cpu.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mach-O Binary Detected")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Inspect load commands, entitlements, ObjC/Swift headers, and dependencies.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Analyze") {
                                    if let onInspectBinary {
                                        onInspectBinary(machOURL)
                                    } else {
                                        inspectedBinaryURL = machOURL
                                    }
                                }
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                            }
                            .padding(12)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                            .padding([.horizontal, .top], 12)
                        }
                        LCHexPageViewer(
                            fileURL: entry.url,
                            rootURL: rootURL,
                            needsSecurityScope: needsSecurityScope
                        )
                    }
                case .symlink, .special:
                    EmptyView()
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !entry.isDirectory && !entry.isSymbolicLink && entry.kind != .special {
                    if entry.kind != .binary && entry.kind != .archive && entry.kind != .machOBinary {
                        Button(forceHexMode ? "Preview" : "Hex") {
                            forceHexMode.toggle()
                        }
                    }
                    Button {
                        Task { await prepareShare() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { stagedShareURL.map { LCPreviewShareURL(url: $0) } },
            set: { if $0 == nil { stagedShareURL = nil } }
        )) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .navigationDestination(item: $inspectedBinaryURL) { url in
            LCBinaryInspectorView(
                binaryURL: url,
                title: entry.name,
                rootURL: rootURL,
                needsSecurityScope: needsSecurityScope
            )
        }
        .alert("Share Failed", isPresented: Binding(
            get: { shareErrorMessage != nil },
            set: { if !$0 { shareErrorMessage = nil } }
        )) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(shareErrorMessage ?? "")
        }
    }

    private func prepareShare() async {
        let url = entry.url
        let root = rootURL
        let scope = needsSecurityScope
        do {
            stagedShareURL = try await Task.detached(priority: .userInitiated) {
                try LCFileExplorerService.stageFileForSharing(at: url, rootURL: root, needsSecurityScope: scope)
            }.value
        } catch {
            shareErrorMessage = error.localizedDescription
        }
    }
}

private struct LCPreviewShareURL: Identifiable {
    var id: String { url.path }
    let url: URL
}

private struct LCTextFileViewer: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    let attemptPrettyJSON: Bool

    @State private var preview: LCFileTextPreview?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var copied = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Read File", systemImage: "doc.text", description: Text(errorMessage))
            } else if let preview {
                VStack(spacing: 0) {
                    if preview.isTruncated {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Showing first \(ByteCountFormatter.string(fromByteCount: Int64(preview.displayedBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(min(preview.totalBytes, UInt64(Int64.max))), countStyle: .file)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background { Color.orange.opacity(0.12) }
                    }
                    ScrollView {
                        Text(preview.text)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
        }
        .toolbar {
            if let text = preview?.text {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .task(id: fileURL) {
            await loadText()
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func loadText() async {
        isLoading = true
        errorMessage = nil
        let url = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        let pretty = attemptPrettyJSON
        do {
            let loaded = try await lcRunOffMain {
                try LCFileExplorerService.loadTextPreview(
                    at: url,
                    rootURL: root,
                    needsSecurityScope: scope,
                    attemptPrettyJSON: pretty
                )
            }
            if !Task.isCancelled {
                preview = loaded
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

private struct LCImageFileViewer: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool

    @State private var image: UIImage?
    @State private var dimensionsText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading image…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Render Image", systemImage: "photo", description: Text(errorMessage))
            } else if let image {
                VStack(spacing: 12) {
                    Spacer()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding()
                    Spacer()
                    if !dimensionsText.isEmpty {
                        Text(dimensionsText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .task(id: fileURL) {
            await loadImage()
        }
    }

    private func loadImage() async {
        isLoading = true
        errorMessage = nil
        let url = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        do {
            let data = try await lcRunOffMain {
                try LCFileExplorerService.loadImageData(at: url, rootURL: root, needsSecurityScope: scope)
            }
            if !Task.isCancelled {
                if let decoded = UIImage(data: data) {
                    image = decoded
                    let w = Int(decoded.size.width * decoded.scale)
                    let h = Int(decoded.size.height * decoded.scale)
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                    dimensionsText = "\(w) × \(h) px · \(sizeStr)"
                } else {
                    errorMessage = "Unsupported or corrupted image format."
                }
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

/// Paginated 4 KiB random-access hex dump viewer backed by POSIX `pread(2)`.
struct LCHexPageViewer: View {
    let fileURL: URL
    let rootURL: URL
    let needsSecurityScope: Bool
    var initialOffset: UInt64 = 0

    private let pageSize: UInt64 = 4096
    @State private var currentOffset: UInt64 = 0
    @State private var didInitializeOffset = false
    @State private var page: LCHexPage?
    @State private var formattedHexText = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var jumpOffsetText = ""
    @State private var showJumpAlert = false

    private var pageTaskID: String {
        "\(fileURL.path)#\(currentOffset)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && page == nil {
                ProgressView("Reading hex page…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Hex Read Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if let page {
                ScrollView([.vertical, .horizontal]) {
                    Text(formattedHexText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        currentOffset = currentOffset >= pageSize ? currentOffset - pageSize : 0
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(currentOffset == 0)

                    Spacer()

                    Button {
                        jumpOffsetText = String(format: "0x%llX", currentOffset)
                        showJumpAlert = true
                    } label: {
                        let end = page.offset + UInt64(page.data.count)
                        Text(String(format: "0x%llX – 0x%llX / 0x%llX", page.offset, end, page.fileSize))
                            .font(.caption2.monospaced())
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Spacer()

                    Button {
                        let next = currentOffset + pageSize
                        if next < page.fileSize {
                            currentOffset = next
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(page.offset + UInt64(page.data.count) >= page.fileSize)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .alert("Jump to Offset", isPresented: $showJumpAlert) {
            TextField("Hex (0x1000) or decimal", text: $jumpOffsetText)
            Button("Jump") {
                applyJumpOffset()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        }
        .task(id: pageTaskID) {
            if !didInitializeOffset {
                didInitializeOffset = true
                if initialOffset > 0 && currentOffset == 0 {
                    currentOffset = initialOffset
                    return
                }
            }
            await loadPage()
        }
    }

    private func applyJumpOffset() {
        let trimmed = jumpOffsetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: UInt64?
        if trimmed.lowercased().hasPrefix("0x") {
            parsed = UInt64(trimmed.dropFirst(2), radix: 16)
        } else {
            parsed = UInt64(trimmed, radix: 10) ?? UInt64(trimmed, radix: 16)
        }
        guard let parsed, let fileSize = page?.fileSize, fileSize > 0 else { return }
        let aligned = min(parsed, fileSize - 1) & ~UInt64(0xF)
        currentOffset = aligned
    }

    private func loadPage() async {
        isLoading = true
        errorMessage = nil
        let url = fileURL
        let root = rootURL
        let scope = needsSecurityScope
        let off = currentOffset
        let size = Int(pageSize)
        do {
            let (loaded, formatted) = try await lcRunOffMain {
                let p = try LCFileExplorerService.loadHexPage(
                    at: url,
                    rootURL: root,
                    needsSecurityScope: scope,
                    offset: off,
                    pageSize: size
                )
                return (p, LCFileExplorerService.formatHexDump(data: p.data, baseOffset: p.offset))
            }
            if !Task.isCancelled {
                page = loaded
                formattedHexText = formatted
                isLoading = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

//
//  LCBinaryInspectorView.swift
//  LiveContainerSwiftUI
//
//  Top-level Liquid Glass Mach-O Binary & Tweak Inspector supporting thin and
//  universal (fat) binaries, multi-target app bundles (main executable,
//  frameworks, dylibs, plugins), LiveContainer Compatibility Doctor,
//  Objective-C/Swift header dumping, structure exploration, deep dive,
//  and `.h` / `.zip` / Markdown / JSON export.
//

import SwiftUI
import UIKit

/// Primary navigation sections inside ``LCBinaryInspectorView``.
enum LCBinaryInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case headers = "Headers"
    case structure = "Structure"
    case deepDive = "Deep Dive"

    var id: String { rawValue }
}

/// Sub-tabs within the Deep Dive section.
enum LCBinaryDeepDiveSubtab: String, CaseIterable, Identifiable, Sendable {
    case symbols = "Symbols"
    case strings = "Strings"
    case hex = "Hex"

    var id: String { rawValue }
}

/// Top-level Binary & Tweak Inspector view.
///
/// Can be initialized either for a single Mach-O binary/tweak URL or for an entire
/// `.app` / `.framework` bundle (enabling seamless switching between the main
/// executable, embedded frameworks, dylibs, and app extensions).
struct LCBinaryInspectorView: View {
    let initialURL: URL
    let bundleRootURL: URL?
    let rootURL: URL?
    let needsSecurityScope: Bool
    let displayTitle: String

    @State private var targets: [LCMachOTargetItem] = []
    @State private var selectedTargetURL: URL?
    @State private var selectedSliceIndex: Int?
    @State private var activeTab: LCBinaryInspectorTab = .overview
    @State private var deepDiveSubtab: LCBinaryDeepDiveSubtab = .symbols
    @State private var hexJumpOffset: UInt64 = 0

    @State private var sliceContext: LCMachOParsedSliceContext?
    @State private var isLoadingOverview = true
    @State private var overviewError: String?

    @State private var objcDump: LCObjCDumpResult?
    @State private var swiftMetadata: LCSwiftMetadataResult?
    @State private var isLoadingHeaders = false
    @State private var headersError: String?

    @State private var symbolsResult: LCMachOSymbolsResult?
    @State private var isLoadingSymbols = false
    @State private var symbolsError: String?

    @State private var stringsResult: LCMachOStringsResult?
    @State private var isLoadingStrings = false
    @State private var stringsError: String?

    @State private var isExporting = false
    @State private var exportedShareURL: URL?
    @State private var exportErrorMessage: String?

    init(
        binaryURL: URL,
        title: String? = nil,
        bundleRootURL: URL? = nil,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) {
        self.initialURL = binaryURL
        self.bundleRootURL = bundleRootURL
        self.rootURL = rootURL
        self.needsSecurityScope = needsSecurityScope
        self.displayTitle = title ?? binaryURL.lastPathComponent
    }

    init(
        bundleURL: URL,
        title: String? = nil,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) {
        self.initialURL = LCBoundedFileReader.resolveMachOExecutableURL(for: bundleURL) ?? bundleURL
        self.bundleRootURL = bundleURL
        self.rootURL = rootURL
        self.needsSecurityScope = needsSecurityScope
        self.displayTitle = title ?? bundleURL.lastPathComponent
    }

    private var activeBinaryURL: URL {
        selectedTargetURL ?? initialURL
    }

    private var loadTaskKey: String {
        "\(activeBinaryURL.path)#\(selectedSliceIndex.map(String.init) ?? "auto")"
    }

    var body: some View {
        VStack(spacing: 0) {
            LCBinaryInspectorControlBar(
                targets: targets,
                activeBinaryURL: activeBinaryURL,
                slices: sliceContext?.overview.slices ?? [],
                selectedSlice: sliceContext?.overview.selectedSlice,
                activeTab: $activeTab,
                onSelectTarget: { target in
                    selectedTargetURL = target.executableURL
                    selectedSliceIndex = nil
                },
                onSelectSlice: { index in
                    selectedSliceIndex = index
                }
            )

            Group {
                if isLoadingOverview && sliceContext == nil {
                    ProgressView("Analyzing Mach-O binary…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let overviewError {
                    ContentUnavailableView(
                        "Binary Inspection Failed",
                        systemImage: "exclamationmark.octagon",
                        description: Text(overviewError)
                    )
                } else if let context = sliceContext {
                    switch activeTab {
                    case .overview:
                        LCBinaryOverviewSection(overview: context.overview)
                    case .headers:
                        LCBinaryHeadersSection(
                            binaryName: context.overview.fileName,
                            isEncrypted: context.overview.header.isEncrypted,
                            objcDump: objcDump,
                            swiftMetadata: swiftMetadata,
                            isLoading: isLoadingHeaders,
                            errorMessage: headersError,
                            onReload: { Task { await loadHeadersIfNeeded(force: true) } },
                            onShareHeaderFile: { url in exportedShareURL = url }
                        )
                    case .structure:
                        LCBinaryStructureSection(
                            overview: context.overview,
                            onJumpToHexOffset: { offset in
                                hexJumpOffset = offset
                                deepDiveSubtab = .hex
                                activeTab = .deepDive
                            }
                        )
                    case .deepDive:
                        LCBinaryDeepDiveSection(
                            fileURL: context.overview.fileURL,
                            rootURL: rootURL ?? context.overview.fileURL,
                            needsSecurityScope: needsSecurityScope,
                            subtab: $deepDiveSubtab,
                            hexJumpOffset: $hexJumpOffset,
                            symbolsResult: symbolsResult,
                            isLoadingSymbols: isLoadingSymbols,
                            symbolsError: symbolsError,
                            stringsResult: stringsResult,
                            isLoadingStrings: isLoadingStrings,
                            stringsError: stringsError,
                            onEnsureSymbols: { Task { await loadSymbolsIfNeeded() } },
                            onEnsureStrings: { Task { await loadStringsIfNeeded() } }
                        )
                    }
                }
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isExporting {
                    ProgressView()
                } else if let context = sliceContext {
                    Menu {
                        Button("Export Combined Header (.h)", systemImage: "doc.plaintext") {
                            Task { await performExport(.combinedHeader, context: context) }
                        }
                        .disabled(context.overview.header.isEncrypted)

                        Button("Export Full Headers Archive (.zip)", systemImage: "doc.zipper") {
                            Task { await performExport(.headersZip, context: context) }
                        }

                        Divider()

                        Button("Export Markdown Report (.md)", systemImage: "doc.richtext") {
                            Task { await performExport(.markdownReport, context: context) }
                        }

                        Button("Export JSON Report (.json)", systemImage: "curlybraces") {
                            Task { await performExport(.jsonReport, context: context) }
                        }

                        Divider()

                        Button("Share Raw Binary", systemImage: "square.and.arrow.up") {
                            Task { await shareRawBinary(url: context.overview.fileURL) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { exportedShareURL.map { LCBinaryShareItem(url: $0) } },
            set: { if $0 == nil { exportedShareURL = nil } }
        )) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .task(id: bundleRootURL) {
            await loadBundleTargetsIfNeeded()
        }
        .task(id: loadTaskKey) {
            await loadOverview()
        }
        .task(id: "\(loadTaskKey)|\(activeTab.rawValue)|\(deepDiveSubtab.rawValue)") {
            guard sliceContext != nil else { return }
            if activeTab == .headers {
                await loadHeadersIfNeeded(force: false)
            } else if activeTab == .deepDive {
                if deepDiveSubtab == .symbols {
                    await loadSymbolsIfNeeded()
                } else if deepDiveSubtab == .strings {
                    await loadStringsIfNeeded()
                }
            }
        }
    }

    // MARK: - Async Loaders

    private func loadBundleTargetsIfNeeded() async {
        guard let bundleRootURL else { return }
        let discovered = await Task.detached(priority: .userInitiated) {
            LCMachOParser.listBundleTargets(bundleURL: bundleRootURL)
        }.value
        if !Task.isCancelled {
            targets = discovered
            if selectedTargetURL == nil, let first = discovered.first {
                selectedTargetURL = first.executableURL
            }
        }
    }

    private func loadOverview() async {
        isLoadingOverview = true
        overviewError = nil
        // Clear lazy caches when target or slice changes
        objcDump = nil
        swiftMetadata = nil
        headersError = nil
        symbolsResult = nil
        symbolsError = nil
        stringsResult = nil
        stringsError = nil

        let targetURL = activeBinaryURL
        let sliceIdx = selectedSliceIndex
        let bRoot = bundleRootURL
        let sRoot = rootURL
        let scope = needsSecurityScope

        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                try LCMachOParser.parseSliceContext(
                    at: targetURL,
                    sliceIndex: sliceIdx,
                    bundleRootURL: bRoot,
                    rootURL: sRoot,
                    needsSecurityScope: scope
                )
            }.value
            if !Task.isCancelled {
                sliceContext = parsed
            }
        } catch {
            if !Task.isCancelled {
                sliceContext = nil
                overviewError = error.localizedDescription
            }
        }
        isLoadingOverview = false
    }

    private func loadHeadersIfNeeded(force: Bool) async {
        guard let context = sliceContext else { return }
        if !force && (objcDump != nil || swiftMetadata != nil || isLoadingHeaders) {
            return
        }
        if context.overview.header.isEncrypted {
            headersError = LCMachOInspectorError.encryptedBinaryCannotDump.localizedDescription
            return
        }

        isLoadingHeaders = true
        headersError = nil
        let sRoot = rootURL
        let scope = needsSecurityScope

        do {
            let (dump, swift) = try await Task.detached(priority: .userInitiated) {
                let d = try LCMachOObjCDumper.dumpMetadata(context: context, rootURL: sRoot, needsSecurityScope: scope)
                let s = try LCMachOSwiftParser.parseMetadata(context: context, rootURL: sRoot, needsSecurityScope: scope)
                return (d, s)
            }.value
            if !Task.isCancelled {
                objcDump = dump
                swiftMetadata = swift
            }
        } catch {
            if !Task.isCancelled {
                headersError = error.localizedDescription
            }
        }
        isLoadingHeaders = false
    }

    private func loadSymbolsIfNeeded() async {
        guard let context = sliceContext, symbolsResult == nil, !isLoadingSymbols else { return }
        isLoadingSymbols = true
        symbolsError = nil
        let sRoot = rootURL
        let scope = needsSecurityScope

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try LCMachOSymbolsParser.parseSymbols(context: context, rootURL: sRoot, needsSecurityScope: scope)
            }.value
            if !Task.isCancelled {
                symbolsResult = result
            }
        } catch {
            if !Task.isCancelled {
                symbolsError = error.localizedDescription
            }
        }
        isLoadingSymbols = false
    }

    private func loadStringsIfNeeded() async {
        guard let context = sliceContext, stringsResult == nil, !isLoadingStrings else { return }
        if context.overview.header.isEncrypted {
            stringsError = LCMachOInspectorError.encryptedBinaryCannotDump.localizedDescription
            return
        }
        isLoadingStrings = true
        stringsError = nil
        let sRoot = rootURL
        let scope = needsSecurityScope

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try LCMachOStringsParser.extractStrings(context: context, rootURL: sRoot, needsSecurityScope: scope)
            }.value
            if !Task.isCancelled {
                stringsResult = result
            }
        } catch {
            if !Task.isCancelled {
                stringsError = error.localizedDescription
            }
        }
        isLoadingStrings = false
    }

    // MARK: - Export Actions

    private func performExport(_ format: LCMachOExportFormat, context: LCMachOParsedSliceContext) async {
        isExporting = true
        defer { isExporting = false }

        let sRoot = rootURL
        let scope = needsSecurityScope
        var currentObjC = objcDump
        var currentSwift = swiftMetadata

        do {
            if (format == .combinedHeader || format == .headersZip) && !context.overview.header.isEncrypted {
                if currentObjC == nil {
                    currentObjC = try await Task.detached(priority: .userInitiated) {
                        try LCMachOObjCDumper.dumpMetadata(context: context, rootURL: sRoot, needsSecurityScope: scope)
                    }.value
                    objcDump = currentObjC
                }
                if currentSwift == nil {
                    currentSwift = try await Task.detached(priority: .userInitiated) {
                        try LCMachOSwiftParser.parseMetadata(context: context, rootURL: sRoot, needsSecurityScope: scope)
                    }.value
                    swiftMetadata = currentSwift
                }
            }

            let finalObjC = currentObjC
            let finalSwift = currentSwift
            let overview = context.overview
            let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                switch format {
                case .combinedHeader:
                    guard let finalObjC else {
                        throw LCMachOInspectorError.encryptedBinaryCannotDump
                    }
                    let text = LCMachOObjCDumper.renderCombinedHeader(binaryName: overview.fileName, dump: finalObjC)
                    return try LCMachOExportService.exportSingleHeader(name: "\(overview.fileName)-Headers", content: text)
                case .headersZip:
                    return try LCMachOExportService.exportHeadersZip(overview: overview, objcDump: finalObjC, swiftMetadata: finalSwift)
                case .markdownReport:
                    return try LCMachOExportService.exportMarkdownReport(overview: overview, objcDump: finalObjC, swiftMetadata: finalSwift)
                case .jsonReport:
                    return try LCMachOExportService.exportJSONReport(overview: overview, objcDump: finalObjC, swiftMetadata: finalSwift)
                }
            }.value

            exportedShareURL = url
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func shareRawBinary(url: URL) async {
        isExporting = true
        defer { isExporting = false }
        let sRoot = rootURL ?? url
        let scope = needsSecurityScope
        do {
            let shareable = try await Task.detached(priority: .userInitiated) {
                try LCFileExplorerService.stageFileForSharing(at: url, rootURL: sRoot, needsSecurityScope: scope)
            }.value
            exportedShareURL = shareable
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

private struct LCBinaryShareItem: Identifiable {
    var id: String { url.path }
    let url: URL
}

/// Top control bar with optional bundle target switcher, universal slice picker,
/// and Liquid Glass segmented tab control.
private struct LCBinaryInspectorControlBar: View {
    let targets: [LCMachOTargetItem]
    let activeBinaryURL: URL
    let slices: [LCMachOArchitectureSlice]
    let selectedSlice: LCMachOArchitectureSlice?
    @Binding var activeTab: LCBinaryInspectorTab
    let onSelectTarget: (LCMachOTargetItem) -> Void
    let onSelectSlice: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if targets.count > 1 || slices.count > 1 {
                HStack(spacing: 8) {
                    if targets.count > 1 {
                        Menu {
                            ForEach(targets) { target in
                                Button {
                                    onSelectTarget(target)
                                } label: {
                                    Label(
                                        "\(target.displayName) (\(target.kind.rawValue))",
                                        systemImage: target.executableURL == activeBinaryURL ? "checkmark" : target.kind.systemImage
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cpu.fill")
                                    .font(.caption)
                                Text(activeBinaryURL.lastPathComponent)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }

                    Spacer(minLength: 4)

                    if slices.count > 1 {
                        Menu {
                            ForEach(slices) { slice in
                                Button {
                                    onSelectSlice(slice.index)
                                } label: {
                                    Label(
                                        "\(slice.architectureName) (\(slice.formattedSize))",
                                        systemImage: slice.index == selectedSlice?.index ? "checkmark" : "memorychip"
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedSlice?.architectureName ?? "Slice")
                                    .font(.caption.monospaced().weight(.semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            Picker("Section", selection: $activeTab) {
                ForEach(LCBinaryInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

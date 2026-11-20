//
//  LCBinaryStructureSection.swift
//  LiveContainerSwiftUI
//
//  Structure tab for LiveContainer's Binary Inspector: Linked Dylibs & @rpath
//  (with broken/substrate highlights), Segments & Sections (with tap-to-jump
//  into Hex Viewer), and Load Commands.
//

import SwiftUI
import UIKit

private enum LCBinaryStructureSubtab: String, CaseIterable, Identifiable {
    case dylibs = "Dylibs"
    case segments = "Segments"
    case loadCommands = "Load Cmds"

    var id: String { rawValue }
}

/// Renders Linked Dylibs, Segments/Sections, and Load Commands for a Mach-O slice.
struct LCBinaryStructureSection: View {
    let overview: LCMachOOverviewResult
    let onJumpToHexOffset: (UInt64) -> Void

    @State private var subtab: LCBinaryStructureSubtab = .dylibs
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LCBinaryStructureSubtab.allCases) { tab in
                        Button {
                            subtab = tab
                        } label: {
                            Text(tabTitle(for: tab))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        .tint(subtab == tab ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            switch subtab {
            case .dylibs:
                LCBinaryDylibsListView(
                    dylibs: filteredDylibs,
                    rpaths: overview.rpaths
                )
            case .segments:
                LCBinarySegmentsListView(
                    segments: filteredSegments,
                    sliceOffset: overview.selectedSlice.fileOffset,
                    onJumpToHexOffset: onJumpToHexOffset
                )
            case .loadCommands:
                LCBinaryLoadCommandsListView(
                    commands: filteredLoadCommands,
                    onJumpToHexOffset: onJumpToHexOffset
                )
            }
        }
        .searchable(text: $searchQuery, prompt: "Filter dylibs, sections, load commands")
    }

    private func tabTitle(for tab: LCBinaryStructureSubtab) -> String {
        switch tab {
        case .dylibs: return "Dylibs (\(overview.dylibs.count))"
        case .segments: return "Segments (\(overview.segments.count))"
        case .loadCommands: return "Load Cmds (\(overview.loadCommands.count))"
        }
    }

    private var filteredDylibs: [LCMachODylibDependency] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return overview.dylibs }
        return overview.dylibs.filter { $0.path.localizedCaseInsensitiveContains(q) || $0.kind.rawValue.localizedCaseInsensitiveContains(q) }
    }

    private var filteredSegments: [LCMachOSegmentInfo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return overview.segments }
        return overview.segments.filter { seg in
            seg.name.localizedCaseInsensitiveContains(q)
                || seg.sections.contains { $0.sectionName.localizedCaseInsensitiveContains(q) }
        }
    }

    private var filteredLoadCommands: [LCMachOLoadCommandInfo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return overview.loadCommands }
        return overview.loadCommands.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }
}

private struct LCBinaryDylibsListView: View {
    let dylibs: [LCMachODylibDependency]
    let rpaths: [String]

    var body: some View {
        List {
            if !rpaths.isEmpty {
                Section("Runpath Search Paths (@rpath)") {
                    ForEach(rpaths, id: \.self) { rp in
                        Text(rp)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Linked Libraries (\(dylibs.count))") {
                if dylibs.isEmpty {
                    Text("No linked dynamic libraries.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dylibs) { dep in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if dep.isPotentiallyBroken {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                }
                                Text((dep.path as NSString).lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(dep.kind.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(kindColor(dep.kind))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(kindColor(dep.kind).opacity(0.14), in: .capsule)
                            }
                            Text(dep.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("v\(dep.currentVersion) (compat \(dep.compatibilityVersion))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let note = dep.statusNote {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Copy Path", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = dep.path
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func kindColor(_ kind: LCMachODylibKind) -> Color {
        switch kind {
        case .id: return .indigo
        case .required: return .blue
        case .weak: return .orange
        case .reexport: return .purple
        case .upward, .lazy: return .teal
        }
    }
}

private struct LCBinarySegmentsListView: View {
    let segments: [LCMachOSegmentInfo]
    let sliceOffset: UInt64
    let onJumpToHexOffset: (UInt64) -> Void

    var body: some View {
        List {
            ForEach(segments) { seg in
                Section {
                    HStack {
                        Text(String(format: "VM 0x%llX · %llu B", seg.vmAddress, seg.vmSize))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(seg.protectionString)
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.indigo.opacity(0.14), in: .capsule)
                    }

                    ForEach(seg.sections) { sec in
                        Button {
                            if sec.fileOffset > 0 {
                                onJumpToHexOffset(sliceOffset + sec.fileOffset)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sec.sectionName)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(String(format: "VM 0x%llX · off 0x%llX", sec.vmAddress, sec.fileOffset))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(sec.formattedSize)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if sec.fileOffset > 0 {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(sec.fileOffset == 0)
                    }
                } header: {
                    Text("\(seg.name) (\(seg.sections.count) sections)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct LCBinaryLoadCommandsListView: View {
    let commands: [LCMachOLoadCommandInfo]
    let onJumpToHexOffset: (UInt64) -> Void

    var body: some View {
        List(commands) { cmd in
            Button {
                onJumpToHexOffset(cmd.fileOffset)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("#\(cmd.index) \(cmd.name)")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(cmd.cmdSize) B")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !cmd.summary.isEmpty {
                        Text(cmd.summary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
    }
}

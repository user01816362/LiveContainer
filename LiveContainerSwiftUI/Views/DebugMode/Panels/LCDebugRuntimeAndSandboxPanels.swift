//
//  LCDebugRuntimeAndSandboxPanels.swift
//  LiveContainerSwiftUI
//
//  Modular nominal SwiftUI 27 panels for Runtime (Dylibs, ObjC Classes, Attach/Info),
//  Sandbox & Keychain, and Tap-to-Inspect View Detail.
//

import SwiftUI

// MARK: - 1. Runtime Panel (Dylibs, ObjC Classes, Frida/LLDB Info)

private enum LCDebugRuntimeSubTab: String, CaseIterable, Identifiable {
    case dylibs = "Dylibs"
    case classes = "ObjC"
    case attach = "Attach / Info"

    var id: String { rawValue }
}

struct LCDebugRuntimePanel: View {
    let inspectorStore: LCDebugInspectorStore
    let manager: LCDebugStudioManager
    let onCopyWithFeedback: (String, String) -> Void

    @State private var subTab: LCDebugRuntimeSubTab = .dylibs
    @State private var dylibSearch = ""
    @State private var hideSystemDylibs = true
    @State private var classSearch = ""

    var body: some View {
        VStack(spacing: 6) {
            Picker("Runtime Section", selection: $subTab) {
                ForEach(LCDebugRuntimeSubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch subTab {
            case .dylibs:
                dylibsSection
            case .classes:
                classesSection
            case .attach:
                attachInfoSection
            }
        }
    }

    private var dylibsSection: some View {
        let filtered = inspectorStore.dylibs.filter { img in
            if hideSystemDylibs && img.isSystem { return false }
            let q = dylibSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            return img.name.localizedCaseInsensitiveContains(q) || img.path.localizedCaseInsensitiveContains(q)
        }
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter Mach-O images…", text: $dylibSearch)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !dylibSearch.isEmpty {
                        Button {
                            dylibSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))

                Toggle("App Only", isOn: $hideSystemDylibs)
                    .font(.caption2.bold())
                    .toggleStyle(.button)
                    .controlSize(.mini)
            }

            List(filtered) { img in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(img.name)
                            .font(.caption.bold())
                        Spacer()
                        Text(img.base)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(img.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contextMenu {
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        onCopyWithFeedback(img.path, "Copied Image Path")
                    }
                    Button("Copy Base Address", systemImage: "number") {
                        onCopyWithFeedback(img.base, "Copied Base Address")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var classesSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Search Objective-C class…", text: $classSearch)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await manager.searchObjCClasses(query: classSearch) }
                        }
                    if !classSearch.isEmpty {
                        Button {
                            classSearch = ""
                            Task { await manager.searchObjCClasses(query: "") }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))

                Button("Search") {
                    Task { await manager.searchObjCClasses(query: classSearch) }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            List(inspectorStore.objcClasses, id: \.self) { clsName in
                Button {
                    Task { await manager.inspectObjCClass(clsName) }
                } label: {
                    HStack {
                        Text(clsName)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var attachInfoSection: some View {
        ScrollView {
            if let info = inspectorStore.fridaInfo {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("JIT-Less Agent: Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Label(
                            "FridaGadget: \(info.fridaGadgetLoaded ? "Loaded" : "Absent")",
                            systemImage: info.fridaGadgetLoaded ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundStyle(info.fridaGadgetLoaded ? Color.green : Color.secondary)
                    }
                    .font(.caption.bold())

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(info.fridaAttachCmd)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy Frida") {
                                onCopyWithFeedback(info.fridaAttachCmd, "Copied Frida Command")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                        }
                        HStack {
                            Text(info.lldbCmd)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy LLDB") {
                                onCopyWithFeedback(info.lldbCmd, "Copied LLDB Command")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                        }
                    }

                    Text(info.fridaGadgetTip)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } else {
                ProgressView()
                    .padding(.top, 20)
            }
        }
    }
}

struct ObjCClassInspectorSheet: View {
    let detail: LCDebugClassDetail
    let onCopyWithFeedback: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Info") {
                    LabeledContent("Class", value: detail.className)
                    LabeledContent("Superclass", value: detail.superclassName)
                    if !detail.image.isEmpty {
                        Text(detail.image)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("Methods (\(detail.methods.count))") {
                    ForEach(detail.methodItems) { m in
                        Text(m.signature)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section("Properties (\(detail.properties.count))") {
                    ForEach(detail.propertyItems) { p in
                        Text(p.signature)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section("Ivars (\(detail.ivars.count))") {
                    ForEach(detail.ivarItems) { iv in
                        Text(iv.signature)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(detail.className)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy Methods") {
                        onCopyWithFeedback(detail.methods.joined(separator: "\n"), "Copied Methods")
                    }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 2. Sandbox & Keychain Panel

private enum LCDebugSandboxSubTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case defaults = "Defaults"
    case keychain = "Keychain"

    var id: String { rawValue }
}

private struct LCSandboxInspectItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct LCDebugSandboxPanel: View {
    let inspectorStore: LCDebugInspectorStore
    let manager: LCDebugStudioManager
    let onCopyWithFeedback: (String, String) -> Void

    @State private var subTab: LCDebugSandboxSubTab = .files
    @State private var query = ""
    @State private var inspectedItem: LCSandboxInspectItem? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Search sandbox files, defaults, keychain…", text: $query)
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))

                Button {
                    Task { await manager.loadSandbox() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            Picker("Sandbox Tab", selection: $subTab) {
                ForEach(LCDebugSandboxSubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if let summary = inspectorStore.sandboxSummary {
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
                List {
                    switch subTab {
                    case .files:
                        let files = q.isEmpty ? summary.files : summary.files.filter { $0.path.localizedCaseInsensitiveContains(q) }
                        ForEach(files) { file in
                            HStack {
                                Image(systemName: file.type == "dir" ? "folder.fill" : "doc.text")
                                    .font(.caption2)
                                    .foregroundStyle(file.type == "dir" ? Color.cyan : Color.secondary)
                                Text(file.path)
                                    .font(.caption2.monospaced())
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Copy Relative Path", systemImage: "doc.on.doc") {
                                    onCopyWithFeedback(file.path, "Copied Sandbox Path")
                                }
                            }
                        }

                    case .defaults:
                        let keys = q.isEmpty ? summary.sortedUserDefaultKeys : summary.sortedUserDefaultKeys.filter {
                            $0.localizedCaseInsensitiveContains(q) || (summary.userDefaults[$0]?.localizedCaseInsensitiveContains(q) ?? false)
                        }
                        ForEach(keys, id: \.self) { key in
                            let val = summary.userDefaults[key] ?? ""
                            Button {
                                inspectedItem = LCSandboxInspectItem(title: key, value: val)
                            } label: {
                                HStack {
                                    Text(key)
                                        .font(.caption2.bold().monospaced())
                                    Spacer()
                                    Text(val)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                    case .keychain:
                        let kc = q.isEmpty ? summary.keychainItems : summary.keychainItems.filter {
                            $0.service.localizedCaseInsensitiveContains(q)
                                || $0.account.localizedCaseInsensitiveContains(q)
                                || $0.value.localizedCaseInsensitiveContains(q)
                        }
                        ForEach(kc) { item in
                            Button {
                                var detail = "Service: \(item.service)\nAccount: \(item.account)\nAccess Group: \(item.accessGroup)"
                                if !item.value.isEmpty {
                                    detail += "\n\nValue:\n\(item.value)"
                                }
                                inspectedItem = LCSandboxInspectItem(
                                    title: item.service.isEmpty ? item.account : item.service,
                                    value: detail
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.service) · \(item.account)")
                                        .font(.caption2.bold().monospaced())
                                    if !item.value.isEmpty {
                                        Text(item.value)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.cyan)
                                            .lineLimit(1)
                                    }
                                    if !item.accessGroup.isEmpty {
                                        Text(item.accessGroup)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .sheet(item: $inspectedItem) { item in
            NavigationStack {
                ScrollView {
                    Text(item.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy") { onCopyWithFeedback(item.value, "Copied Value") }
                    }
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("lc.common.done".loc) { inspectedItem = nil }
                    }
                }
            }
        }
    }
}

// MARK: - 3. Full Tap-to-Inspect View Detail Sheet

struct LCDebugViewDetailSheet: View {
    let info: LCDebugSelectedView
    let onCopy: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    LabeledContent("View Class", value: info.viewClass)
                    if !info.viewController.isEmpty {
                        LabeledContent("View Controller", value: info.viewController)
                    }
                    if let win = info.windowClass, !win.isEmpty {
                        LabeledContent("Window", value: win)
                    }
                    if info.isSwiftUI == true {
                        LabeledContent("Framework", value: "SwiftUI Hosting / Internal")
                    }
                    if !info.accessibilityIdentifier.isEmpty {
                        LabeledContent("Accessibility ID", value: info.accessibilityIdentifier)
                    }
                    if !info.accessibilityLabel.isEmpty {
                        LabeledContent("Accessibility Label", value: info.accessibilityLabel)
                    }
                }

                Section("Layout & Rendering") {
                    LabeledContent("Frame", value: info.frame)
                    LabeledContent("Bounds", value: info.bounds)
                    LabeledContent("Alpha", value: String(format: "%.2f", info.alpha))
                    LabeledContent("Hidden", value: info.hidden ? "Yes" : "No")
                    LabeledContent("Tag", value: "\(info.tag)")
                    LabeledContent("Subviews", value: "\(info.subviewCount)")
                    if let c = info.constraintsCount {
                        LabeledContent("Constraints", value: "\(c)")
                    }
                    if !info.backgroundColor.isEmpty {
                        Text("Background: \(info.backgroundColor)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let chain = info.responderChain, !chain.isEmpty {
                    let chainItems = LCDebugClassMemberItem.buildList(prefix: "rc", raw: chain)
                    Section("Responder Chain (\(chain.count))") {
                        ForEach(chainItems) { item in
                            Text(item.signature)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(info.viewClass)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy Class") { onCopy(info.viewClass, "Copied View Class") }
                }
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

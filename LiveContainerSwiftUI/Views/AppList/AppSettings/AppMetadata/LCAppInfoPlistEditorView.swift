//
//  LCAppInfoPlistEditorView.swift
//  LiveContainerSwiftUI
//
//  Full structured & Raw XML Info.plist editor for installed apps with search,
//  nested dictionary/array drill-down, presets, validation, backup restore,
//  and optional bundle re-signing.
//

import SwiftUI
import UIKit

enum LCInfoPlistEditorMode: String, CaseIterable, Identifiable {
    case structured = "Structured"
    case rawXML = "Raw XML"

    var id: String { rawValue }
}

private struct LCPlistEditableScalarKey: Identifiable {
    let key: String
    let value: LCPlistValue
    var id: String { key }
}

private struct LCPlistEditableArrayIndex: Identifiable {
    let index: Int
    let value: LCPlistValue
    var id: Int { index }
}

struct LCAppInfoPlistEditorView: View {
    @ObservedObject var model: LCAppModel
    @EnvironmentObject private var sharedModel: SharedModel

    @State private var mode: LCInfoPlistEditorMode = .structured
    @State private var entries: [String: LCPlistValue] = [:]
    @State private var xmlText = ""
    @State private var xmlParseError: String?
    @State private var searchQuery = ""
    @State private var hasUnsavedChanges = false
    @State private var didLoadInitial = false

    @State private var resignAfterSave = false
    @State private var isSaving = false
    @State private var showAddKeySheet = false
    @State private var editingScalar: LCPlistEditableScalarKey?
    @State private var showRestoreConfirmation = false

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var copiedToast = false

    private var isSecondaryLC: Bool {
        sharedModel.multiLCStatus == 2
    }

    private var canResign: Bool {
        !model.uiDontSign &&
        !model.uiIs32bit &&
        LCUtils.certificateData() != nil &&
        LCSharedUtils.certificatePassword() != nil
    }

    private var hasOriginalBackup: Bool {
        _ = model.metadataRevision
        return model.appInfo.hasOriginalMetadataBackup()
    }

    private var filteredKeys: [String] {
        let allKeys = entries.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allKeys }
        return allKeys.filter { key in
            key.localizedCaseInsensitiveContains(q) ||
            (entries[key]?.summaryText.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if mode == .structured {
                structuredListView
            } else {
                rawXMLEditorView
            }
        }
        .navigationTitle("Info.plist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Editor Mode", selection: Binding(
                    get: { mode },
                    set: { switchMode(to: $0) }
                )) {
                    ForEach(LCInfoPlistEditorMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .structured && !isSecondaryLC {
                    Button {
                        showAddKeySheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isSaving)
                }

                Menu {
                    Button {
                        Task { await savePlist(forceResign: false) }
                    } label: {
                        Label("Save Changes", systemImage: "checkmark.circle")
                    }
                    .disabled(isSecondaryLC || isSaving || model.isAppRunning || (mode == .rawXML && xmlParseError != nil))

                    if canResign {
                        Button {
                            Task { await savePlist(forceResign: true) }
                        } label: {
                            Label("Save & Re-sign App", systemImage: "signature")
                        }
                        .disabled(isSecondaryLC || isSaving || model.isAppRunning || (mode == .rawXML && xmlParseError != nil))
                    }

                    if mode == .rawXML {
                        Divider()
                        Button {
                            formatXMLInPlace()
                        } label: {
                            Label("Format XML", systemImage: "text.alignleft")
                        }
                        .disabled(xmlParseError != nil)
                    }

                    Divider()
                    Button {
                        copyCurrentXML()
                    } label: {
                        Label(copiedToast ? "Copied XML" : "Copy XML", systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                    }

                    if hasOriginalBackup && !isSecondaryLC {
                        Divider()
                        Button(role: .destructive) {
                            showRestoreConfirmation = true
                        } label: {
                            Label("Restore Original Info.plist", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isSaving || model.isAppRunning)
                    }
                } label: {
                    Image(systemName: hasUnsavedChanges ? "ellipsis.circle.fill" : "ellipsis.circle")
                }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search keys or values")
        .onAppear {
            if !didLoadInitial {
                resignAfterSave = canResign
                loadFromAppInfo()
                didLoadInitial = true
            }
        }
        .onChange(of: model.metadataRevision) { _, _ in
            if !isSaving {
                loadFromAppInfo()
            }
        }
        .task(id: copiedToast) {
            guard copiedToast else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copiedToast = false
        }
        .sheet(isPresented: $showAddKeySheet) {
            LCPlistAddKeySheet(existingKeys: Set(entries.keys), showPresets: true) { newKey, newValue in
                entries[newKey] = newValue
                syncXMLFromEntries()
                hasUnsavedChanges = true
            }
        }
        .sheet(item: $editingScalar) { item in
            LCPlistEntryEditorSheet(
                initialKey: item.key,
                initialValue: item.value,
                allowKeyRename: item.key != "CFBundleExecutable" && item.key != "CFBundleIdentifier",
                existingSiblingKeys: Set(entries.keys.filter { $0 != item.key })
            ) { updatedKey, updatedValue in
                if updatedKey != item.key {
                    entries.removeValue(forKey: item.key)
                }
                entries[updatedKey] = updatedValue
                syncXMLFromEntries()
                hasUnsavedChanges = true
            }
        }
        .confirmationDialog(
            "Restore Original Info.plist?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(canResign ? "Restore & Re-sign" : "Restore Original", role: .destructive) {
                Task { await restoreOriginal(forceResign: canResign) }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("Discards your Info.plist edits and restores the pre-edit snapshot.")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var structuredListView: some View {
        List {
            Section {
                if !isSecondaryLC {
                    Toggle("Re-sign App on Save", isOn: $resignAfterSave)
                        .disabled(!canResign || isSaving)

                    Button {
                        Task { await savePlist(forceResign: resignAfterSave && canResign) }
                    } label: {
                        HStack {
                            if isSaving || model.isSigningInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                Text(model.isSigningInProgress ? "Re-signing App…" : "Saving Info.plist…")
                            } else {
                                Image(systemName: (resignAfterSave && canResign) ? "signature" : "checkmark.circle.fill")
                                Text((resignAfterSave && canResign) ? "Save & Re-sign" : "Save Info.plist")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!hasUnsavedChanges || isSaving || model.isAppRunning)
                } else {
                    Label("Secondary LiveContainer cannot edit Info.plist.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }

                LabeledContent("Top-Level Keys", value: "\(entries.count)")
                if model.uiUseLCBundleId {
                    Label(
                        "CFBundleIdentifier edits target LCOrignalBundleIdentifier automatically.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }
            }

            Section {
                if filteredKeys.isEmpty {
                    Text(searchQuery.isEmpty ? "Info.plist has no keys." : "No keys match \"\(searchQuery)\".")
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(filteredKeys, id: \.self) { key in
                        if let value = entries[key] {
                            rootEntryRow(forKey: key, value: value)
                        }
                    }
                }
            } header: {
                Text("Entries")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func rootEntryRow(forKey key: String, value: LCPlistValue) -> some View {
        switch value {
        case .dictionary(let childDict):
            NavigationLink {
                LCPlistDictionaryEditorView(
                    title: key,
                    isReadOnly: isSecondaryLC,
                    dictionary: Binding(
                        get: {
                            if case .dictionary(let latest) = entries[key] {
                                return latest
                            }
                            return childDict
                        },
                        set: { updated in
                            entries[key] = .dictionary(updated)
                            syncXMLFromEntries()
                            hasUnsavedChanges = true
                        }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .swipeActions(edge: .trailing) {
                if !isSecondaryLC {
                    Button(role: .destructive) {
                        deleteRootKey(key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .array(let childArray):
            NavigationLink {
                LCPlistArrayEditorView(
                    title: key,
                    isReadOnly: isSecondaryLC,
                    array: Binding(
                        get: {
                            if case .array(let latest) = entries[key] {
                                return latest
                            }
                            return childArray
                        },
                        set: { updated in
                            entries[key] = .array(updated)
                            syncXMLFromEntries()
                            hasUnsavedChanges = true
                        }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .swipeActions(edge: .trailing) {
                if !isSecondaryLC {
                    Button(role: .destructive) {
                        deleteRootKey(key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .boolean(let flag):
            HStack(spacing: 10) {
                Button {
                    if !isSecondaryLC {
                        editingScalar = LCPlistEditableScalarKey(key: key, value: value)
                    }
                } label: {
                    LCPlistKeyValueRowContent(key: key, value: value)
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { flag },
                    set: { newFlag in
                        entries[key] = .boolean(newFlag)
                        syncXMLFromEntries()
                        hasUnsavedChanges = true
                    }
                ))
                .labelsHidden()
                .disabled(isSecondaryLC)
            }
            .swipeActions(edge: .trailing) {
                if !isSecondaryLC {
                    Button(role: .destructive) {
                        deleteRootKey(key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        default:
            Button {
                if !isSecondaryLC {
                    editingScalar = LCPlistEditableScalarKey(key: key, value: value)
                }
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                if !isSecondaryLC {
                    Button(role: .destructive) {
                        deleteRootKey(key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var rawXMLEditorView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: xmlParseError == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(xmlParseError == nil ? Color.green : Color.red)
                Text(xmlParseError ?? "Valid XML Property List")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(xmlParseError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                if !isSecondaryLC {
                    Button((resignAfterSave && canResign) ? "Save & Re-sign" : "Save") {
                        Task { await savePlist(forceResign: resignAfterSave && canResign) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(xmlParseError != nil || !hasUnsavedChanges || isSaving || model.isAppRunning)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            TextEditor(text: Binding(
                get: { xmlText },
                set: { newValue in
                    xmlText = newValue
                    hasUnsavedChanges = true
                    validateXML(newValue)
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(isSecondaryLC || isSaving)
            .padding(.horizontal, 8)
        }
    }

    private func loadFromAppInfo() {
        let dict = model.appInfo.editableInfoPlistDictionary()
        entries = LCPlistValue.dictionaryFromFoundation(dict)
        xmlText = (try? LCPlistValue.renderXMLString(from: entries)) ?? ""
        xmlParseError = nil
        hasUnsavedChanges = false
    }

    private func syncXMLFromEntries() {
        if let rendered = try? LCPlistValue.renderXMLString(from: entries) {
            xmlText = rendered
            xmlParseError = nil
        }
    }

    private func validateXML(_ text: String) {
        do {
            _ = try LCPlistValue.parseXMLString(text)
            xmlParseError = nil
        } catch {
            xmlParseError = error.localizedDescription
        }
    }

    private func switchMode(to newMode: LCInfoPlistEditorMode) {
        guard newMode != mode else { return }
        if newMode == .rawXML {
            syncXMLFromEntries()
            mode = .rawXML
        } else {
            do {
                let parsed = try LCPlistValue.parseXMLString(xmlText)
                entries = parsed
                xmlParseError = nil
                mode = .structured
            } catch {
                alertTitle = "Invalid XML Plist"
                alertMessage = "Fix the XML syntax error before switching to Structured view:\n\(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    private func formatXMLInPlace() {
        do {
            let parsed = try LCPlistValue.parseXMLString(xmlText)
            entries = parsed
            xmlText = try LCPlistValue.renderXMLString(from: parsed)
            xmlParseError = nil
        } catch {
            xmlParseError = error.localizedDescription
        }
    }

    private func copyCurrentXML() {
        if mode == .structured {
            syncXMLFromEntries()
        }
        UIPasteboard.general.string = xmlText
        copiedToast = true
    }

    private func deleteRootKey(_ key: String) {
        if key == "CFBundleExecutable" || key == "CFBundleIdentifier" {
            alertTitle = "Required Key"
            alertMessage = "\"\(key)\" is required by iOS and LiveContainer to launch the app and cannot be deleted."
            showAlert = true
            return
        }
        entries.removeValue(forKey: key)
        syncXMLFromEntries()
        hasUnsavedChanges = true
    }

    private func savePlist(forceResign: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let dictToSave: [String: LCPlistValue]
            if mode == .rawXML {
                dictToSave = try LCPlistValue.parseXMLString(xmlText)
                entries = dictToSave
                xmlParseError = nil
            } else {
                dictToSave = entries
            }

            let foundationDict = LCPlistValue.foundationDictionary(from: dictToSave)
            try await model.replaceInfoPlist(foundationDict, resignAfterSave: forceResign)
            hasUnsavedChanges = false
            loadFromAppInfo()

            alertTitle = "lc.common.success".loc
            alertMessage = forceResign
                ? "Info.plist saved and app bundle re-signed."
                : "Info.plist saved."
            showAlert = true
        } catch {
            alertTitle = "lc.common.error".loc
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func restoreOriginal(forceResign: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.resetMetadataToOriginal(resignAfterSave: forceResign)
            hasUnsavedChanges = false
            loadFromAppInfo()
            alertTitle = "lc.common.success".loc
            alertMessage = forceResign
                ? "Original Info.plist restored and bundle re-signed."
                : "Original Info.plist restored."
            showAlert = true
        } catch {
            alertTitle = "lc.common.error".loc
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

private struct LCPlistKeyValueRowContent: View {
    let key: String
    let value: LCPlistValue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(key)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(value.type.shortLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(value.type.badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(value.type.badgeColor.opacity(0.14), in: .capsule)
            }
            Text(value.summaryText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

struct LCPlistDictionaryEditorView: View {
    let title: String
    let isReadOnly: Bool
    @Binding var dictionary: [String: LCPlistValue]

    @State private var searchQuery = ""
    @State private var showAddKeySheet = false
    @State private var editingScalar: LCPlistEditableScalarKey?

    private var sortedKeys: [String] {
        let keys = dictionary.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return keys }
        return keys.filter {
            $0.localizedCaseInsensitiveContains(q) ||
            (dictionary[$0]?.summaryText.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        List {
            if sortedKeys.isEmpty {
                Text(searchQuery.isEmpty ? "Empty dictionary." : "No matching entries.")
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(sortedKeys, id: \.self) { key in
                    if let value = dictionary[key] {
                        row(forKey: key, value: value)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Filter keys")
        .toolbar {
            if !isReadOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddKeySheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddKeySheet) {
            LCPlistAddKeySheet(existingKeys: Set(dictionary.keys), showPresets: false) { newKey, newValue in
                dictionary[newKey] = newValue
            }
        }
        .sheet(item: $editingScalar) { item in
            LCPlistEntryEditorSheet(
                initialKey: item.key,
                initialValue: item.value,
                allowKeyRename: true,
                existingSiblingKeys: Set(dictionary.keys.filter { $0 != item.key })
            ) { updatedKey, updatedValue in
                if updatedKey != item.key {
                    dictionary.removeValue(forKey: item.key)
                }
                dictionary[updatedKey] = updatedValue
            }
        }
    }

    @ViewBuilder
    private func row(forKey key: String, value: LCPlistValue) -> some View {
        switch value {
        case .dictionary(let child):
            NavigationLink {
                LCPlistDictionaryEditorView(
                    title: key,
                    isReadOnly: isReadOnly,
                    dictionary: Binding(
                        get: {
                            if case .dictionary(let latest) = dictionary[key] { return latest }
                            return child
                        },
                        set: { dictionary[key] = .dictionary($0) }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .swipeActions(edge: .trailing) {
                if !isReadOnly {
                    Button(role: .destructive) {
                        dictionary.removeValue(forKey: key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .array(let child):
            NavigationLink {
                LCPlistArrayEditorView(
                    title: key,
                    isReadOnly: isReadOnly,
                    array: Binding(
                        get: {
                            if case .array(let latest) = dictionary[key] { return latest }
                            return child
                        },
                        set: { dictionary[key] = .array($0) }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .swipeActions(edge: .trailing) {
                if !isReadOnly {
                    Button(role: .destructive) {
                        dictionary.removeValue(forKey: key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        case .boolean(let flag):
            HStack(spacing: 10) {
                Button {
                    if !isReadOnly {
                        editingScalar = LCPlistEditableScalarKey(key: key, value: value)
                    }
                } label: {
                    LCPlistKeyValueRowContent(key: key, value: value)
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { flag },
                    set: { dictionary[key] = .boolean($0) }
                ))
                .labelsHidden()
                .disabled(isReadOnly)
            }
            .swipeActions(edge: .trailing) {
                if !isReadOnly {
                    Button(role: .destructive) {
                        dictionary.removeValue(forKey: key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

        default:
            Button {
                if !isReadOnly {
                    editingScalar = LCPlistEditableScalarKey(key: key, value: value)
                }
            } label: {
                LCPlistKeyValueRowContent(key: key, value: value)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                if !isReadOnly {
                    Button(role: .destructive) {
                        dictionary.removeValue(forKey: key)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}

struct LCPlistArrayEditorView: View {
    let title: String
    let isReadOnly: Bool
    @Binding var array: [LCPlistValue]

    @State private var showAddItemSheet = false
    @State private var editingIndex: LCPlistEditableArrayIndex?

    var body: some View {
        List {
            if array.isEmpty {
                Text("Empty array.")
                    .foregroundStyle(Color.secondary)
            } else {
                ForEach(array.indices, id: \.self) { index in
                    row(at: index, value: array[index])
                }
                .onMove { source, destination in
                    guard !isReadOnly else { return }
                    array.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    guard !isReadOnly else { return }
                    array.remove(atOffsets: offsets)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isReadOnly {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button {
                        showAddItemSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddItemSheet) {
            LCPlistAddArrayItemSheet { newValue in
                array.append(newValue)
            }
        }
        .sheet(item: $editingIndex) { item in
            LCPlistEntryEditorSheet(
                initialKey: "[\(item.index)]",
                initialValue: item.value,
                allowKeyRename: false,
                existingSiblingKeys: []
            ) { _, updatedValue in
                if array.indices.contains(item.index) {
                    array[item.index] = updatedValue
                }
            }
        }
    }

    @ViewBuilder
    private func row(at index: Int, value: LCPlistValue) -> some View {
        let keyLabel = "[\(index)]"
        switch value {
        case .dictionary(let child):
            NavigationLink {
                LCPlistDictionaryEditorView(
                    title: keyLabel,
                    isReadOnly: isReadOnly,
                    dictionary: Binding(
                        get: {
                            if array.indices.contains(index), case .dictionary(let latest) = array[index] {
                                return latest
                            }
                            return child
                        },
                        set: { updated in
                            if array.indices.contains(index) {
                                array[index] = .dictionary(updated)
                            }
                        }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: keyLabel, value: value)
            }

        case .array(let child):
            NavigationLink {
                LCPlistArrayEditorView(
                    title: keyLabel,
                    isReadOnly: isReadOnly,
                    array: Binding(
                        get: {
                            if array.indices.contains(index), case .array(let latest) = array[index] {
                                return latest
                            }
                            return child
                        },
                        set: { updated in
                            if array.indices.contains(index) {
                                array[index] = .array(updated)
                            }
                        }
                    )
                )
            } label: {
                LCPlistKeyValueRowContent(key: keyLabel, value: value)
            }

        default:
            Button {
                if !isReadOnly {
                    editingIndex = LCPlistEditableArrayIndex(index: index, value: value)
                }
            } label: {
                LCPlistKeyValueRowContent(key: keyLabel, value: value)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LCPlistEntryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let allowKeyRename: Bool
    let existingSiblingKeys: Set<String>
    let onCommit: (String, LCPlistValue) -> Void

    @State private var keyName: String
    @State private var selectedType: LCPlistValueType
    @State private var stringValue = ""
    @State private var intValueText = "0"
    @State private var realValueText = "0.0"
    @State private var boolValue = false
    @State private var dateValue = Date()
    @State private var dataBase64Text = ""

    init(
        initialKey: String,
        initialValue: LCPlistValue,
        allowKeyRename: Bool,
        existingSiblingKeys: Set<String>,
        onCommit: @escaping (String, LCPlistValue) -> Void
    ) {
        self.allowKeyRename = allowKeyRename
        self.existingSiblingKeys = existingSiblingKeys
        self.onCommit = onCommit
        _keyName = State(initialValue: initialKey)
        _selectedType = State(initialValue: initialValue.type)
        switch initialValue {
        case .string(let s):
            _stringValue = State(initialValue: s)
        case .integer(let i):
            _intValueText = State(initialValue: String(i))
            _stringValue = State(initialValue: String(i))
        case .real(let r):
            _realValueText = State(initialValue: String(r))
            _stringValue = State(initialValue: String(r))
        case .boolean(let b):
            _boolValue = State(initialValue: b)
        case .date(let d):
            _dateValue = State(initialValue: d)
        case .data(let data):
            _dataBase64Text = State(initialValue: data.base64EncodedString())
        case .array, .dictionary:
            break
        }
    }

    private var trimmedKey: String {
        keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if allowKeyRename {
            if trimmedKey.isEmpty {
                return "Key name cannot be empty."
            }
            if existingSiblingKeys.contains(trimmedKey) {
                return "Another entry already uses key \"\(trimmedKey)\"."
            }
        }
        switch selectedType {
        case .integer:
            if Int64(intValueText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                return "Enter a valid 64-bit integer."
            }
        case .real:
            if Double(realValueText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                return "Enter a valid decimal number."
            }
        case .data:
            let cleaned = dataBase64Text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) == nil {
                return "Enter valid Base64 data."
            }
        default:
            break
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowKeyRename {
                    Section("Key") {
                        TextField("Key name", text: $keyName)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Type") {
                    Picker("Value Type", selection: $selectedType) {
                        ForEach(LCPlistValueType.allCases) { type in
                            Text(type.fullLabel).tag(type)
                        }
                    }
                    .onChange(of: selectedType) { oldType, newType in
                        convertState(from: oldType, to: newType)
                    }
                }

                Section("Value") {
                    valueInputView
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(allowKeyRename ? "Edit Entry" : "Edit \(keyName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onCommit(trimmedKey, buildValue())
                        dismiss()
                    }
                    .disabled(validationError != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var valueInputView: some View {
        switch selectedType {
        case .string:
            TextEditor(text: $stringValue)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
        case .integer:
            TextField("Integer", text: $intValueText)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .real:
            TextField("Decimal number", text: $realValueText)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .boolean:
            Toggle(boolValue ? "YES (true)" : "NO (false)", isOn: $boolValue)
        case .date:
            DatePicker("Date", selection: $dateValue)
        case .data:
            VStack(alignment: .leading, spacing: 6) {
                Text("Base64 Payload")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                TextEditor(text: $dataBase64Text)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 110)
            }
        case .array:
            Text("Converts this value into an empty Array ([]) that you can open and populate.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        case .dictionary:
            Text("Converts this value into an empty Dictionary ({}) that you can open and populate.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private func convertState(from oldType: LCPlistValueType, to newType: LCPlistValueType) {
        let currentValue: LCPlistValue
        switch oldType {
        case .string:
            currentValue = .string(stringValue)
        case .integer:
            currentValue = .integer(Int64(intValueText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .real:
            currentValue = .real(Double(realValueText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0)
        case .boolean:
            currentValue = .boolean(boolValue)
        case .date:
            currentValue = .date(dateValue)
        case .data:
            let cleaned = dataBase64Text.trimmingCharacters(in: .whitespacesAndNewlines)
            currentValue = .data(Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? Data())
        case .array:
            currentValue = .array([])
        case .dictionary:
            currentValue = .dictionary([:])
        }

        let converted = currentValue.converted(to: newType)
        switch converted {
        case .string(let s):
            stringValue = s
        case .integer(let i):
            intValueText = String(i)
        case .real(let r):
            realValueText = String(r)
        case .boolean(let b):
            boolValue = b
        case .date(let d):
            dateValue = d
        case .data(let data):
            dataBase64Text = data.base64EncodedString()
        case .array, .dictionary:
            break
        }
    }

    private func buildValue() -> LCPlistValue {
        switch selectedType {
        case .string:
            return .string(stringValue)
        case .integer:
            return .integer(Int64(intValueText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .real:
            return .real(Double(realValueText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0)
        case .boolean:
            return .boolean(boolValue)
        case .date:
            return .date(dateValue)
        case .data:
            let cleaned = dataBase64Text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .data(Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? Data())
        case .array:
            return .array([])
        case .dictionary:
            return .dictionary([:])
        }
    }
}

private struct LCPlistAddKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingKeys: Set<String>
    let showPresets: Bool
    let onAdd: (String, LCPlistValue) -> Void

    @State private var keyName = ""
    @State private var selectedType: LCPlistValueType = .string
    @State private var stringValue = ""
    @State private var boolValue = true
    @State private var numberText = "0"
    @State private var overrideValue: LCPlistValue?

    private var trimmedKey: String {
        keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if trimmedKey.isEmpty {
            return "Enter a key name."
        }
        if existingKeys.contains(trimmedKey) {
            return "\"\(trimmedKey)\" already exists."
        }
        if overrideValue == nil {
            if selectedType == .integer && Int64(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                return "Enter a valid integer."
            }
            if selectedType == .real && Double(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                return "Enter a valid decimal number."
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Key") {
                    TextField("Info.plist key", text: Binding(
                        get: { keyName },
                        set: {
                            keyName = $0
                            overrideValue = nil
                        }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Picker("Type", selection: Binding(
                        get: { selectedType },
                        set: {
                            selectedType = $0
                            overrideValue = nil
                        }
                    )) {
                        ForEach(LCPlistValueType.allCases) { type in
                            Text(type.fullLabel).tag(type)
                        }
                    }

                    if overrideValue == nil {
                        switch selectedType {
                        case .string:
                            TextField("String value", text: $stringValue)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        case .boolean:
                            Toggle(boolValue ? "YES (true)" : "NO (false)", isOn: $boolValue)
                        case .integer, .real:
                            TextField("Numeric value", text: $numberText)
                                .font(.system(.body, design: .monospaced))
                                .keyboardType(.numbersAndPunctuation)
                        default:
                            Text("Created as an empty \(selectedType.fullLabel).")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    } else if let overrideValue {
                        LabeledContent("Preset Value", value: overrideValue.summaryText)
                    }
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }

                if showPresets {
                    let availablePresets = LCPlistKeyPreset.commonInfoPlistKeys.filter { !existingKeys.contains($0.key) }
                    if !availablePresets.isEmpty {
                        Section("Common Info.plist Presets") {
                            ForEach(availablePresets) { preset in
                                Button {
                                    keyName = preset.key
                                    selectedType = preset.defaultValue.type
                                    switch preset.defaultValue {
                                    case .string(let s):
                                        stringValue = s
                                        overrideValue = nil
                                    case .boolean(let b):
                                        boolValue = b
                                        overrideValue = nil
                                    default:
                                        overrideValue = preset.defaultValue
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(preset.key)
                                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color.primary)
                                            Spacer()
                                            Text(preset.defaultValue.type.shortLabel)
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(preset.defaultValue.type.badgeColor)
                                        }
                                        Text(preset.title)
                                            .font(.caption)
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Info.plist Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(trimmedKey, makeValue())
                        dismiss()
                    }
                    .disabled(validationError != nil)
                }
            }
        }
    }

    private func makeValue() -> LCPlistValue {
        if let overrideValue {
            return overrideValue
        }
        switch selectedType {
        case .string:
            return .string(stringValue)
        case .boolean:
            return .boolean(boolValue)
        case .integer:
            return .integer(Int64(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .real:
            return .real(Double(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0)
        default:
            return selectedType.defaultValue
        }
    }
}

private struct LCPlistAddArrayItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (LCPlistValue) -> Void

    @State private var selectedType: LCPlistValueType = .string
    @State private var stringValue = ""
    @State private var numberText = "0"
    @State private var boolValue = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $selectedType) {
                    ForEach(LCPlistValueType.allCases) { type in
                        Text(type.fullLabel).tag(type)
                    }
                }

                switch selectedType {
                case .string:
                    TextField("Value", text: $stringValue)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .boolean:
                    Toggle(boolValue ? "YES (true)" : "NO (false)", isOn: $boolValue)
                case .integer, .real:
                    TextField("Numeric value", text: $numberText)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numbersAndPunctuation)
                default:
                    Text("Appends an empty \(selectedType.fullLabel).")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("Add Array Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(makeValue())
                        dismiss()
                    }
                }
            }
        }
    }

    private func makeValue() -> LCPlistValue {
        switch selectedType {
        case .string:
            return .string(stringValue)
        case .boolean:
            return .boolean(boolValue)
        case .integer:
            return .integer(Int64(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .real:
            return .real(Double(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0)
        default:
            return selectedType.defaultValue
        }
    }
}

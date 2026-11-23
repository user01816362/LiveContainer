//
//  LCContainerProfileSubviews.swift
//  LiveContainerSwiftUI
//
//  Modular SwiftUI subviews for the container spoof profile screen:
//  - Preset quick-apply / save / coherent-randomize controls
//  - Three-vector Smart Leak & Consistency Inspector card
//  - Searchable Locale and Time Zone sheets replacing laggy inline pickers
//

import SwiftUI

/// Pre-sorted locale and time-zone identifier lists shared by searchable sheets.
enum LCContainerProfileCatalog {
    static let allLocaleIdentifiers: [String] = Array(Set(Locale.availableIdentifiers.map {
        Locale.identifier(.icu, from: $0)
    })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    static let allTimeZoneIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    static let availableRadioAccessTechnologies: [String] = [
        "CTRadioAccessTechnologyNR",
        "CTRadioAccessTechnologyNRNSA",
        "CTRadioAccessTechnologyLTE",
        "CTRadioAccessTechnologyWCDMA",
        "CTRadioAccessTechnologyHSDPA",
        "CTRadioAccessTechnologyHSUPA",
        "CTRadioAccessTechnologyCDMAEVDORevA"
    ]

    static func localeDisplayName(_ identifier: String) -> String {
        if identifier.isEmpty { return "None (Use Host)" }
        let localized = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return "\(localized) — \(identifier)"
    }
}

/// Interactive bar for 1-tap preset application, custom preset saving, and coherent randomization.
struct LCProfilePresetControlBar: View {
    @ObservedObject private var presetStore = LCProfilePresetStore.shared

    let onApplyPreset: (LCProfilePreset) -> Void
    let onSaveAsPreset: (String) -> Void
    let onApplyCurrentDevice: () -> Void
    let onRandomizeCoherent: () -> Void

    @State private var showSavePrompt = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                if !presetStore.customPresets.isEmpty {
                    Section("Custom Saved Presets") {
                        ForEach(presetStore.customPresets) { preset in
                            Button {
                                onApplyPreset(preset)
                            } label: {
                                Label(preset.name, systemImage: preset.iconSystemName)
                            }
                        }
                    }
                }
                Section("Built-in & Privacy Templates") {
                    ForEach(presetStore.builtInPresets) { preset in
                        Button {
                            onApplyPreset(preset)
                        } label: {
                            Label(preset.name, systemImage: preset.iconSystemName)
                        }
                    }
                }
            } label: {
                Label("Apply Profile Preset…", systemImage: "rectangle.stack.badge.plus")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 12) {
                Button {
                    newPresetName = ""
                    showSavePrompt = true
                } label: {
                    Label("Save as Preset", systemImage: "bookmark.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)

                Button {
                    onRandomizeCoherent()
                } label: {
                    Label("Randomize Device", systemImage: "die.face.5")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
            }

            Button("Copy Current Real Device Values") {
                onApplyCurrentDevice()
            }
            .font(.caption)

            NavigationLink {
                LCDefaultProfileSettingsView()
            } label: {
                Label("Configure Global Auto-Apply Preset…", systemImage: "gearshape.2")
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .alert("Save Profile as Custom Preset", isPresented: $showSavePrompt) {
            TextField("Preset Name (e.g. EU iPhone 18 Pro)", text: $newPresetName)
            Button("Save") {
                onSaveAsPreset(newPresetName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this configuration to App Group presets for reuse across containers or Main Settings.")
        }
    }
}

/// Real-time Smart Leak & Consistency Inspector covering Network, WebKit JS, and Native Hardware vectors.
struct LCProfileLeakInspectorCard: View {
    let report: LCProfileAuditReport
    let onAutoFix: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            vectorSummaryGrid
            if let modelSpec = report.matchedSpec {
                Text("Matched Spec: \(modelSpec.shortSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !report.realHostMachine.isEmpty {
                Text("Host Hardware: \(report.realHostMachine) · Active Spec: \(report.matchedSpec?.hwMachine ?? "Custom")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !report.findings.isEmpty {
                DisclosureGroup("Inspect Findings (\(report.findings.count))", isExpanded: $isExpanded) {
                    findingsList
                }
                .font(.caption.weight(.medium))
            }
            if report.hasAutoFixableIssues {
                Button {
                    onAutoFix()
                } label: {
                    Label("Auto-Fix Coherence & Leaks", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: report.status.symbolName)
                .foregroundStyle(report.status.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Leak & Coherence Inspector")
                    .font(.subheadline.weight(.semibold))
                Text(report.status.title)
                    .font(.caption)
                    .foregroundStyle(report.status.color)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var vectorSummaryGrid: some View {
        VStack(spacing: 6) {
            vectorRow(.network, interceptions: report.networkInterceptions)
            vectorRow(.webkit, interceptions: report.webkitInterceptions)
            vectorRow(.hardware, interceptions: report.hardwareInterceptions)
        }
    }

    @ViewBuilder
    private func vectorRow(_ vector: LCLeakVector, interceptions: Int) -> some View {
        let items = report.findings(for: vector)
        let worstSeverity = items.map(\.severity).max()
        let statusColor: Color = worstSeverity?.color ?? .green
        let statusLabel: String = {
            if let worstSeverity {
                let count = items.count
                return "\(count) \(worstSeverity.badgeText)\(count > 1 ? "s" : "")"
            }
            return "Clean"
        }()

        HStack(spacing: 8) {
            Image(systemName: vector.symbolName)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 18)
            Text(vector.rawValue)
                .font(.caption)
            Spacer()
            if interceptions > 0 {
                Text("\(interceptions) hooked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var findingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.findings) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.severity.badgeText.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(item.severity.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(item.severity.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.vector.rawValue): \(item.title)")
                            .font(.caption.weight(.semibold))
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// Searchable modal picker for selecting any OS locale identifier without Form lag.
struct LCLocalePickerSheet: View {
    @Binding var selectedLocale: String
    let onSelect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLocales: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return LCContainerProfileCatalog.allLocaleIdentifiers
        }
        return LCContainerProfileCatalog.allLocaleIdentifiers.filter { identifier in
            identifier.localizedCaseInsensitiveContains(query) ||
                LCContainerProfileCatalog.localeDisplayName(identifier).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectedLocale = ""
                    onSelect()
                    dismiss()
                } label: {
                    HStack {
                        Text("None (Use Host Locale)")
                        Spacer()
                        if selectedLocale.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                ForEach(filteredLocales, id: \.self) { identifier in
                    Button {
                        selectedLocale = identifier
                        onSelect()
                        dismiss()
                    } label: {
                        HStack {
                            Text(LCContainerProfileCatalog.localeDisplayName(identifier))
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedLocale == identifier {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search country, language, or ICU code")
            .navigationTitle("Select Locale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Searchable modal picker for selecting any known IANA time zone identifier.
struct LCTimeZonePickerSheet: View {
    @Binding var selectedTimeZone: String
    let onSelect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredTimeZones: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return LCContainerProfileCatalog.allTimeZoneIdentifiers
        }
        return LCContainerProfileCatalog.allTimeZoneIdentifiers.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectedTimeZone = ""
                    onSelect()
                    dismiss()
                } label: {
                    HStack {
                        Text("None (Use Host Time Zone)")
                        Spacer()
                        if selectedTimeZone.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                ForEach(filteredTimeZones, id: \.self) { identifier in
                    Button {
                        selectedTimeZone = identifier
                        onSelect()
                        dismiss()
                    } label: {
                        HStack {
                            Text(identifier)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedTimeZone == identifier {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search region or city (e.g. Tokyo, Riyadh)")
            .navigationTitle("Select Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

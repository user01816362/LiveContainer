//
//  LCDebugNetworkSheets.swift
//  LiveContainerSwiftUI
//
//  Modal configuration, request replay, and file share sheets for Debug Studio's
//  Network Inspector.
//

import SwiftUI
import UIKit

// MARK: - Network Settings Sheet

struct LCDebugNetworkSettingsSheet: View {
    let manager: LCDebugStudioManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LCDebugNetworkSettings = .default
    @State private var newExcludedHost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Capture Network Traffic", isOn: $draft.isCaptureEnabled)
                    Toggle("Cache Image Responses", isOn: $draft.cacheMediaBodies)
                    Toggle("Redact Sensitive Data (Headers & Tokens)", isOn: $draft.redactSensitive)
                } header: {
                    Text("Capture & Developer Privacy")
                } footer: {
                    Text("Redaction is disabled by default so real Authorization headers, Cookies, API keys, cURL commands, and Keychain values are shown in full during development.")
                }

                Section("Limits") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Body Cache Limit")
                            Spacer()
                            Text("\(draft.cacheLimitMB) MB")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $draft.cacheLimitMBDouble,
                            in: 4...50,
                            step: 2
                        )
                    }

                    Picker("Retained Requests", selection: $draft.maxTransactions) {
                        Text("200").tag(200)
                        Text("500").tag(500)
                        Text("1,000").tag(1000)
                        Text("2,000").tag(2000)
                    }
                }

                Section("Excluded Hosts (\(draft.excludedHosts.count))") {
                    HStack {
                        TextField("e.g. analytics.example.com", text: $newExcludedHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let trimmed = newExcludedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            guard !trimmed.isEmpty, !draft.excludedHosts.contains(trimmed) else { return }
                            draft.excludedHosts.append(trimmed)
                            draft.excludedHosts.sort()
                            newExcludedHost = ""
                        }
                        .disabled(newExcludedHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(draft.excludedHosts, id: \.self) { host in
                        Text(host)
                            .font(.caption.monospaced())
                    }
                    .onDelete { offsets in
                        draft.excludedHosts.remove(atOffsets: offsets)
                    }

                    if !draft.excludedHosts.isEmpty {
                        Button("Clear All Excluded Hosts", role: .destructive) {
                            draft.excludedHosts.removeAll()
                        }
                    }
                }
            }
            .navigationTitle("Network Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let toSave = draft
                        Task {
                            await manager.updateNetworkSettings(toSave)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                draft = manager.networkStore.settings
            }
        }
    }
}

// MARK: - Request Replay Sheet

struct LCDebugNetworkReplaySheet: View {
    let initialTarget: LCDebugNetworkReplayTarget
    let manager: LCDebugStudioManager

    @Environment(\.dismiss) private var dismiss
    @State private var method: String = "GET"
    @State private var url: String = ""
    @State private var headersText: String = ""
    @State private var bodyText: String = ""
    @State private var isSending = false
    @State private var result: LCDebugNetworkReplayResult? = nil

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    Picker("Method", selection: $method) {
                        ForEach(Self.methods, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    TextField("URL", text: $url, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Headers (Key: Value per line)") {
                    TextEditor(text: $headersText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Body") {
                    TextEditor(text: $bodyText)
                        .font(.caption.monospaced())
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let result {
                    Section("Result") {
                        HStack {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? .green : .red)
                            Text(result.ok ? "Status \(result.statusCode ?? 200)" : (result.error ?? "Failed"))
                                .font(.caption.bold())
                            Spacer()
                            if let ms = result.durationMs {
                                Text("\(ms) ms")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if let b = result.bytes {
                                Text("· \(LCDebugFormatting.formatByteCount(b))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Replay Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send()
                    } label: {
                        if isSending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(isSending || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                method = initialTarget.method.uppercased()
                url = initialTarget.url
                headersText = initialTarget.headers.keys
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    .map { "\($0): \(initialTarget.headers[$0] ?? "")" }
                    .joined(separator: "\n")
                bodyText = initialTarget.body
            }
        }
    }

    private func send() {
        guard !isSending else { return }
        isSending = true
        var parsedHeaders: [String: String] = [:]
        for line in headersText.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { parsedHeaders[k] = v }
        }
        let target = LCDebugNetworkReplayTarget(
            id: initialTarget.id,
            transactionId: initialTarget.transactionId,
            method: method,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            headers: parsedHeaders,
            body: bodyText
        )
        Task {
            defer { isSending = false }
            result = await manager.replayTransaction(target)
        }
    }
}

struct LCDebugActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

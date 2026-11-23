//
//  LCPackageMetadataSectionView.swift
//  LiveContainerSwiftUI
//

import SwiftUI

struct LCPackageMetadataSectionView: View {
    @Binding var metadata: LCPackageMetadataDraft

    var body: some View {
        Form {
            Section("Identity") {
                labeledField("Display Name", text: $metadata.displayName)
                labeledField("Bundle Name", text: $metadata.bundleName)
                labeledField("Bundle Identifier", text: $metadata.bundleIdentifier, monospace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Versioning") {
                labeledField("Short Version", text: $metadata.shortVersion, monospace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                labeledField("Build Version", text: $metadata.buildVersion, monospace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                labeledField("Minimum iOS", text: $metadata.minimumOSVersion, monospace: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Propagation") {
                Toggle("Update PlugIns & Watch Bundle IDs", isOn: $metadata.updateExtensionBundleIds)
                Toggle("Update Localized Names (InfoPlist.strings)", isOn: $metadata.updateLocalizedNames)
            }

            Section("Info.plist Options") {
                Toggle("Remove UISupportedDevices", isOn: $metadata.removeSupportedDevices)
                Toggle("Enable Files App Sharing", isOn: $metadata.enableFileSharing)
                Toggle("Remove Custom URL Schemes", isOn: $metadata.removeURLSchemes)
            }
        }
        .navigationTitle("Metadata & Plist")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func labeledField(_ title: String, text: Binding<String>, monospace: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField(title, text: text)
                .multilineTextAlignment(.trailing)
                .font(monospace ? .callout.monospaced() : .body)
        }
    }
}

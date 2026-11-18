import Foundation
import UniformTypeIdentifiers

struct SharePayload: Sendable {
    enum Kind: Sendable {
        case loading
        case url(URL)
        case file(URL)
        case empty
        case failed(String)
    }

    var kind: Kind = .loading

    var sharedURL: URL? {
        if case .url(let url) = kind {
            return url
        }
        return nil
    }
    
    @MainActor
    static func load(from context: NSExtensionContext?) async throws -> SharePayload.Kind {
        guard let items = context?.inputItems as? [NSExtensionItem] else {
            return .empty
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                let loadedURL: URL? = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: url)
                        }
                    }
                }
                if let loadedURL {
                    return loadedURL.isFileURL ? .file(loadedURL) : .url(loadedURL)
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let rawData: Data? = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadDataRepresentation(for: .url) { data, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: data)
                        }
                    }
                }
                if let rawData,
                   let string = String(data: rawData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: string) {
                    return url.isFileURL ? .file(url) : .url(url)
                }
            }
        }
        return .empty
    }
}

struct ShareContainer: Identifiable, Hashable, Sendable {
    let id: String
    let folderName: String
    let name: String
    let isShared: Bool
}

struct ShareApp: Identifiable, Hashable, Sendable {
    let id: String
    let relativeBundlePath: String
    let displayName: String
    let bundleIdentifier: String
    let isShared: Bool
    let isHidden: Bool
    let isLocked: Bool
    let isJITNeeded: Bool
    let containers: [ShareContainer]
    let iconURL: URL?
    let lastLaunched: Date?
    let installationDate: Date?
    let isBuiltInSideStore: Bool

    var primaryContainer: ShareContainer? {
        containers.first
    }
}

struct ShareLaunchItem: Identifiable, Hashable, Sendable {
    let app: ShareApp
    let container: ShareContainer

    var id: String {
        "\(app.id)|\(container.id)"
    }
}

struct ShareExtensionError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

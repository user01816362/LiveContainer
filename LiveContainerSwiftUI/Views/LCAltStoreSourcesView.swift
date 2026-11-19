//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import SwiftUI
import UIKit
import CryptoKit

struct AltStoreSourceAppVersion: Identifiable, Hashable, Sendable {
    let id = UUID()
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?
}

struct AltStoreSourceApp: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let tintColor: Color?
    let screenshots: [URL]
    let versions: [AltStoreSourceAppVersion]
    let latestVersion: AltStoreSourceAppVersion?
    let isBeta: Bool
}

struct AltStoreSource: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: URL?
    let headerURL: URL?
    let tintColor: Color?
    let website: URL?
    let apps: [AltStoreSourceApp]
}

struct LCAppUpdateCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let installedApp: LCAppModel
    let sourceURL: URL
    let sourceName: String
    let sourceApp: AltStoreSourceApp
    let latestVersion: AltStoreSourceAppVersion
    let currentDisplayVersion: String

    var latestDisplayVersion: String {
        if let build = latestVersion.buildVersion, !build.isEmpty {
            return "\(latestVersion.version) (\(build))"
        }
        return latestVersion.version
    }

    var updateKey: String {
        "\(latestVersion.version)#\(latestVersion.buildVersion ?? "")"
    }
}

private struct AltStoreSourceResponse: Decodable, Sendable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

private struct AltStoreSourceAppResponse: Decodable, Sendable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let buildVersion: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let versions: [AltStoreSourceAppVersionResponse]?

    enum CodingKeys: String, CodingKey {
        case beta, name, bundleIdentifier, developerName, subtitle
        case version, buildVersion, buildNumber
        case versionDate, versionDescription, downloadURL
        case localizedDescription, iconURL, tintColor, screenshotURLs, versions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        beta = try container.decodeIfPresent(Bool.self, forKey: .beta)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        developerName = try container.decodeIfPresent(String.self, forKey: .developerName)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        buildVersion = Self.decodeFlexibleString(in: container, key: .buildVersion)
            ?? Self.decodeFlexibleString(in: container, key: .buildNumber)
        versionDate = try container.decodeIfPresent(String.self, forKey: .versionDate)
        versionDescription = try container.decodeIfPresent(String.self, forKey: .versionDescription)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        tintColor = try container.decodeIfPresent(String.self, forKey: .tintColor)
        screenshotURLs = try container.decodeIfPresent([String].self, forKey: .screenshotURLs)
        versions = try container.decodeIfPresent([AltStoreSourceAppVersionResponse].self, forKey: .versions)
    }

    fileprivate static func decodeFlexibleString(in container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return str
        }
        if let num = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(num)
        }
        return nil
    }
}

private struct AltStoreSourceAppVersionResponse: Decodable, Sendable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case version
        case buildVersion
        case buildNumber
        case date
        case localizedDescription
        case downloadURL
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        if let bv = try? container.decodeIfPresent(String.self, forKey: .buildVersion) {
            buildVersion = bv
        } else if let bn = try? container.decodeIfPresent(String.self, forKey: .buildNumber) {
            buildVersion = bn
        } else if let bvInt = try? container.decodeIfPresent(Int.self, forKey: .buildVersion) {
            buildVersion = String(bvInt)
        } else if let bnInt = try? container.decodeIfPresent(Int.self, forKey: .buildNumber) {
            buildVersion = String(bnInt)
        } else {
            buildVersion = nil
        }
        date = try container.decodeIfPresent(String.self, forKey: .date)
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
    }
}

@MainActor
final class AltStoreSourcesViewModel: ObservableObject {
    static let shared = AltStoreSourcesViewModel()

    struct SourceItem: Identifiable, Hashable {
        let id: URL
        let url: URL
        var source: AltStoreSource?
        var isLoading: Bool
        var error: String?

        init(url: URL, isLoading: Bool = false, source: AltStoreSource? = nil, error: String? = nil) {
            self.url = url
            self.id = url
            self.isLoading = isLoading
            self.source = source
            self.error = error
        }

        var displayName: String {
            if let source {
                return source.name
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return url.absoluteString
        }

        var primaryIconURL: URL? {
            if let icon = source?.iconURL {
                return icon
            }
            if let appIcon = source?.apps.first(where: { $0.iconURL != nil })?.iconURL {
                return appIcon
            }
            return nil
        }
    }

    @Published private(set) var sources: [SourceItem] = []
    @Published private(set) var availableUpdates: [LCAppUpdateCandidate] = []
    @Published var isRefreshingAll = false
    private let defaultsKey = "LCAltStoreSourceURLs"
    private var hasLoadedSources = false
    private var updateCandidatesByAppId: [String: LCAppUpdateCandidate] = [:]

    func loadSourcesIfNeeded() {
        guard !hasLoadedSources else { return }
        hasLoadedSources = true

        let defaults = UserDefaults.standard
        let stored = defaults.array(forKey: defaultsKey) as? [String] ?? []
        let urls = stored.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }

        // Populate placeholders immediately on MainActor with zero blocking I/O
        self.sources = urls.map { SourceItem(url: $0, isLoading: false) }

        // Decode cached repositories off-thread in background utility task
        Task.detached(priority: .utility) { [weak self] in
            var loaded: [URL: AltStoreSource] = [:]
            for url in urls {
                if let data = Self.cachedData(for: url),
                   let cachedSource = try? AltStoreSourceLoader.decode(from: data, baseURL: url) {
                    loaded[url] = cachedSource
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                var updated = self.sources
                var hasAnyChanges = false
                for i in updated.indices {
                    if let source = loaded[updated[i].url] {
                        updated[i].source = source
                        hasAnyChanges = true
                    }
                }
                if hasAnyChanges {
                    self.sources = updated
                    self.recomputeAvailableUpdates()
                }

                Task { [weak self] in
                    await self?.refreshAllSources()
                }
            }
        }
    }

    func addSource(from rawValue: String) async -> String? {
        guard let normalizedURL = normalizeSourceURL(from: rawValue) else {
            return "lc.sources.error.invalidUrl".loc
        }

        if sources.contains(where: { $0.url == normalizedURL }) {
            return "lc.sources.error.duplicate".loc
        }

        sources.append(SourceItem(url: normalizedURL, isLoading: true))
        persistSources()
        await refreshSource(url: normalizedURL)
        recomputeAvailableUpdates()
        return nil
    }

    func removeSource(_ item: SourceItem) {
        sources.removeAll { $0.id == item.id }
        persistSources()
        Self.removeCache(for: item.url)
        recomputeAvailableUpdates()
    }

    func refreshSource(_ item: SourceItem) async {
        await refreshSource(url: item.url)
        recomputeAvailableUpdates()
    }

    func refreshAllSources() async {
        guard !sources.isEmpty else {
            recomputeAvailableUpdates()
            return
        }
        isRefreshingAll = true
        let urlsToFetch = sources.map { $0.url }
        var initialSources = sources
        for index in initialSources.indices {
            initialSources[index].isLoading = true
            initialSources[index].error = nil
        }
        sources = initialSources

        await withTaskGroup(of: (URL, Result<(AltStoreSource, Data), Error>).self) { group in
            for url in urlsToFetch {
                group.addTask {
                    do {
                        let result = try await AltStoreSourceLoader.load(from: url)
                        return (url, .success(result))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }

            var updatedSources = sources
            var didChangeAnySource = false

            for await (url, result) in group {
                guard let idx = updatedSources.firstIndex(where: { $0.url == url }) else { continue }
                switch result {
                case .success(let (source, data)):
                    let prevData = Self.cachedData(for: url)
                    if prevData != data {
                        updatedSources[idx].source = source
                        Self.storeCache(data, for: url)
                        didChangeAnySource = true
                    } else if updatedSources[idx].source == nil {
                        updatedSources[idx].source = source
                        didChangeAnySource = true
                    }
                    updatedSources[idx].isLoading = false
                    updatedSources[idx].error = nil
                case .failure(let error):
                    updatedSources[idx].isLoading = false
                    updatedSources[idx].error = error.localizedDescription
                }
            }

            sources = updatedSources
            isRefreshingAll = false
            if didChangeAnySource {
                recomputeAvailableUpdates()
            }
        }
    }

    private func refreshSource(url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else {
            return
        }
        sources[index].isLoading = true
        sources[index].error = nil
        let previousData = Self.cachedData(for: url)
        do {
            let (source, data) = try await AltStoreSourceLoader.load(from: url)
            guard let sourceIndex = sources.firstIndex(where: { $0.url == url }) else {
                return
            }
            if let previousData, previousData == data, sources[sourceIndex].source != nil {
                sources[sourceIndex].isLoading = false
                return
            }
            sources[sourceIndex].source = source
            sources[sourceIndex].isLoading = false
            Self.storeCache(data, for: url)
        } catch {
            if let sourceIndex = sources.firstIndex(where: { $0.url == url }) {
                sources[sourceIndex].error = error.localizedDescription
                sources[sourceIndex].isLoading = false
            }
        }
    }

    // MARK: - Update Detection & Provenance Matching

    func recomputeAvailableUpdates() {
        let sharedModel = DataManager.shared.model
        let installedApps = sharedModel.isHiddenAppUnlocked ? (sharedModel.apps + sharedModel.hiddenApps) : sharedModel.apps
        var candidates: [LCAppUpdateCandidate] = []

        for app in installedApps {
            guard let bundleId = app.appInfo.bundleIdentifier(), !bundleId.isEmpty, bundleId != "Unknown" else {
                continue
            }
            let preferredSourceURL = app.appInfo.sourceURL
            let installedMarketing = app.appInfo.installedSourceVersion ?? app.appInfo.shortVersion() ?? app.appInfo.version() ?? "0"
            let installedBuild = app.appInfo.installedSourceBuildVersion ?? app.appInfo.buildVersion()

            var bestMatch: (sourceItem: SourceItem, sourceApp: AltStoreSourceApp, version: AltStoreSourceAppVersion)? = nil

            for item in sources {
                guard let source = item.source else { continue }
                for sourceApp in source.apps {
                    guard sourceApp.bundleIdentifier.caseInsensitiveCompare(bundleId) == .orderedSame,
                          let latest = sourceApp.latestVersion else {
                        continue
                    }

                    let matchesPreferredSource = preferredSourceURL == item.url.absoluteString
                    if let currentBest = bestMatch {
                        let currentBestIsPreferred = preferredSourceURL == currentBest.sourceItem.url.absoluteString
                        if matchesPreferredSource && !currentBestIsPreferred {
                            bestMatch = (item, sourceApp, latest)
                        } else if matchesPreferredSource == currentBestIsPreferred,
                                  Self.isVersion(latest.version, build: latest.buildVersion, newerThan: currentBest.version.version, build: currentBest.version.buildVersion) {
                            bestMatch = (item, sourceApp, latest)
                        }
                    } else {
                        bestMatch = (item, sourceApp, latest)
                    }
                }
            }

            guard let bestMatch else { continue }
            guard Self.isVersion(bestMatch.version.version, build: bestMatch.version.buildVersion, newerThan: installedMarketing, build: installedBuild) else {
                continue
            }

            let currentDisplay: String
            if let installedBuild, !installedBuild.isEmpty {
                currentDisplay = "\(installedMarketing) (\(installedBuild))"
            } else {
                currentDisplay = installedMarketing
            }

            let key = "\(bestMatch.version.version)#\(bestMatch.version.buildVersion ?? "")"
            if app.appInfo.ignoredUpdateVersion == key {
                continue
            }

            candidates.append(LCAppUpdateCandidate(
                id: app.appInfo.relativeBundlePath ?? bundleId,
                installedApp: app,
                sourceURL: bestMatch.sourceItem.url,
                sourceName: bestMatch.sourceItem.displayName,
                sourceApp: bestMatch.sourceApp,
                latestVersion: bestMatch.version,
                currentDisplayVersion: currentDisplay
            ))
        }

        availableUpdates = candidates
        updateCandidatesByAppId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func updateCandidate(for app: LCAppModel) -> LCAppUpdateCandidate? {
        let key = app.appInfo.relativeBundlePath ?? app.bundleIdentifier
        return updateCandidatesByAppId[key]
    }

    func updateCandidate(for sourceApp: AltStoreSourceApp, in sourceURL: URL) -> LCAppUpdateCandidate? {
        availableUpdates.first {
            $0.sourceApp.bundleIdentifier.caseInsensitiveCompare(sourceApp.bundleIdentifier) == .orderedSame
                && $0.sourceURL == sourceURL
        }
    }

    func installedApp(matching sourceApp: AltStoreSourceApp) -> LCAppModel? {
        let all = DataManager.shared.model.isHiddenAppUnlocked
            ? (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps)
            : DataManager.shared.model.apps
        return all.first {
            ($0.appInfo.bundleIdentifier() ?? "").caseInsensitiveCompare(sourceApp.bundleIdentifier) == .orderedSame
        }
    }

    func enqueueUpdate(_ candidate: LCAppUpdateCandidate) {
        LCDownloadManager.shared.enqueueAppDownload(
            url: candidate.latestVersion.downloadURL,
            displayName: "\(candidate.installedApp.displayName) \(candidate.latestVersion.version)",
            iconURL: candidate.sourceApp.iconURL,
            sourceURL: candidate.sourceURL.absoluteString,
            version: candidate.latestVersion.version,
            buildVersion: candidate.latestVersion.buildVersion,
            targetAppBundleId: candidate.sourceApp.bundleIdentifier,
            targetRelativePath: candidate.installedApp.appInfo.relativeBundlePath
        )
    }

    func enqueueUpdateAll() {
        for candidate in availableUpdates {
            enqueueUpdate(candidate)
        }
    }

    func ignoreUpdate(_ candidate: LCAppUpdateCandidate) {
        candidate.installedApp.appInfo.ignoredUpdateVersion = candidate.updateKey
        recomputeAvailableUpdates()
    }

    nonisolated static func isVersion(_ lhsVersion: String, build lhsBuild: String?, newerThan rhsVersion: String, build rhsBuild: String?) -> Bool {
        let cmp = normalizeVersion(lhsVersion).compare(normalizeVersion(rhsVersion), options: .numeric)
        if cmp == .orderedDescending {
            return true
        }
        if cmp == .orderedSame,
           let lhsBuild, !lhsBuild.isEmpty,
           let rhsBuild, !rhsBuild.isEmpty {
            return normalizeVersion(lhsBuild).compare(normalizeVersion(rhsBuild), options: .numeric) == .orderedDescending
        }
        return false
    }

    private nonisolated static func normalizeVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v"), trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    // MARK: - Persistence & Cache

    private func persistSources() {
        let urls = sources.map { $0.url.absoluteString }
        UserDefaults.standard.set(urls, forKey: defaultsKey)
    }

    private func normalizeSourceURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if let httpsURL = URL(string: "https://\(trimmed)") {
            return httpsURL
        }
        return nil
    }
}

private extension AltStoreSourcesViewModel {
    nonisolated private static let cacheDirectoryName = "AltStoreSourceCache"

    nonisolated static func cachedData(for url: URL) -> Data? {
        guard let fileURL = cacheFileURL(for: url) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    nonisolated static func storeCache(_ data: Data, for url: URL) {
        Task.detached(priority: .background) {
            guard let fileURL = cacheFileURL(for: url) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    nonisolated static func cacheFileURL(for url: URL) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let fileName = cacheFileName(for: url)
        return directory.appendingPathComponent(fileName)
    }

    nonisolated static func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }

    nonisolated static func cacheFileName(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    nonisolated static func removeCache(for url: URL) {
        guard let fileURL = cacheFileURL(for: url) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum AltStoreSourceLoader {
    static func load(from url: URL) async throws -> (AltStoreSource, Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw NSError(domain: "AltStoreSource", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }
        let source = try decode(from: data, baseURL: url)
        return (source, data)
    }

    static func decode(from data: Data, baseURL: URL) throws -> AltStoreSource {
        try decodeSource(from: data, baseURL: baseURL)
    }

    private static func makeShortDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func decodeSource(from data: Data, baseURL: URL) throws -> AltStoreSource {
        let shortFormatter = makeShortDateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            let localISOFormatter = ISO8601DateFormatter()
            if let isoDate = localISOFormatter.date(from: rawValue) {
                return isoDate
            }
            if let shortDate = shortFormatter.date(from: rawValue) {
                return shortDate
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(rawValue)")
        })
        let isoFormatter = ISO8601DateFormatter()

        let response = try decoder.decode(AltStoreSourceResponse.self, from: data)
        guard let name = response.name else {
            throw NSError(domain: "AltStoreSource", code: 0, userInfo: [NSLocalizedDescriptionKey: "lc.sources.error.malformed".loc])
        }
        let apps = (response.apps ?? []).compactMap { appResponse in
            buildApp(
                from: appResponse,
                baseURL: baseURL,
                fallbackTint: response.tintColor,
                isoFormatter: isoFormatter,
                shortFormatter: shortFormatter
            )
        }
        return AltStoreSource(
            name: name,
            identifier: response.identifier,
            subtitle: response.subtitle,
            description: response.description,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            headerURL: url(for: response.headerURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor),
            website: url(for: response.website, baseURL: baseURL),
            apps: apps
        )
    }

    private static func buildApp(
        from response: AltStoreSourceAppResponse,
        baseURL: URL,
        fallbackTint: String?,
        isoFormatter: ISO8601DateFormatter,
        shortFormatter: DateFormatter
    ) -> AltStoreSourceApp? {
        guard let name = response.name,
              let bundleIdentifier = response.bundleIdentifier else {
            return nil
        }

        let versions = buildVersions(from: response, baseURL: baseURL, isoFormatter: isoFormatter, shortFormatter: shortFormatter)
        let latest = versions.first ?? buildLegacyVersion(from: response, baseURL: baseURL, isoFormatter: isoFormatter, shortFormatter: shortFormatter)

        return AltStoreSourceApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            developerName: response.developerName,
            subtitle: response.subtitle,
            description: response.localizedDescription ?? response.versionDescription,
            iconURL: url(for: response.iconURL, baseURL: baseURL),
            tintColor: color(from: response.tintColor ?? fallbackTint),
            screenshots: (response.screenshotURLs ?? []).compactMap { url(for: $0, baseURL: baseURL) },
            versions: versions,
            latestVersion: latest,
            isBeta: response.beta ?? false
        )
    }

    private static func buildVersions(
        from response: AltStoreSourceAppResponse,
        baseURL: URL,
        isoFormatter: ISO8601DateFormatter,
        shortFormatter: DateFormatter
    ) -> [AltStoreSourceAppVersion] {
        guard let versions = response.versions else { return [] }
        return versions.compactMap { version in
            guard let versionString = version.version,
                  let downloadURLString = version.downloadURL,
                  let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
                return nil
            }
            return AltStoreSourceAppVersion(
                version: versionString,
                buildVersion: version.buildVersion,
                releaseDate: parseDate(version.date, isoFormatter: isoFormatter, shortFormatter: shortFormatter),
                localizedDescription: version.localizedDescription,
                downloadURL: downloadURL,
                size: version.size
            )
        }
    }

    private static func buildLegacyVersion(
        from response: AltStoreSourceAppResponse,
        baseURL: URL,
        isoFormatter: ISO8601DateFormatter,
        shortFormatter: DateFormatter
    ) -> AltStoreSourceAppVersion? {
        guard let versionString = response.version,
              let downloadURLString = response.downloadURL,
              let downloadURL = url(for: downloadURLString, baseURL: baseURL) else {
            return nil
        }
        return AltStoreSourceAppVersion(
            version: versionString,
            buildVersion: response.buildVersion,
            releaseDate: parseDate(response.versionDate, isoFormatter: isoFormatter, shortFormatter: shortFormatter),
            localizedDescription: response.versionDescription ?? response.localizedDescription,
            downloadURL: downloadURL,
            size: nil
        )
    }

    private static func parseDate(
        _ value: String?,
        isoFormatter: ISO8601DateFormatter,
        shortFormatter: DateFormatter
    ) -> Date? {
        guard let value else { return nil }
        if let isoDate = isoFormatter.date(from: value) {
            return isoDate
        }
        return shortFormatter.date(from: value)
    }

    private static func url(for string: String?, baseURL: URL) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let absoluteURL = URL(string: string), absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }

    private static func color(from hex: String?) -> Color? {
        guard let hex = hex else { return nil }
        return Color(hexString: hex)
    }
}

private extension Color {
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")

        if cleaned.count == 3 {
            var expanded = ""
            for character in cleaned {
                expanded.append(character)
                expanded.append(character)
            }
            cleaned = expanded
        }

        if cleaned.count == 6 {
            cleaned.append("FF")
        }

        guard cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }

        let red = Double((value & 0xFF00_0000) >> 24) / 255.0
        let green = Double((value & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((value & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(value & 0x0000_00FF) / 255.0

        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct LCSourcesView: View {
    @ObservedObject private var viewModel = AltStoreSourcesViewModel.shared
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @StateObject private var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false

    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var downloadManager: LCDownloadManager

    @State private var isViewAppeared = false

    var body: some View {
        sourcesNavigationStack
            .alert("lc.common.error".loc, isPresented: errorAlertBinding) {
                Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("lc.sources.removeConfirmation.title".loc, isPresented: removeSourceAlertBinding) {
                Button("lc.common.remove".loc, role: .destructive) {
                    if let sourcePendingRemoval {
                        viewModel.removeSource(sourcePendingRemoval)
                    }
                    sourcePendingRemoval = nil
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    sourcePendingRemoval = nil
                }
            } message: {
                if let name = sourcePendingRemoval?.displayName {
                    Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
                } else {
                    Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
                }
            }
            .sheet(isPresented: $isManagingSources) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            }
    }

    private var sourcesNavigationStack: some View {
        NavigationStack {
            Group {
                if viewModel.sources.isEmpty {
                    emptySourcesPlaceholder
                } else {
                    sourcesScrollContent
                }
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar {
                sourcesToolbar
            }
        }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))
        .onAppear {
            if sharedModel.selectedTab == .sources {
                viewModel.loadSourcesIfNeeded()
            }
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.selectedTab) { _, tab in
            if tab == .sources {
                viewModel.loadSourcesIfNeeded()
            }
        }
        .onChange(of: viewModel.sources) { _, newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { _, link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    private var emptySourcesPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("lc.sources.empty".loc)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var sourcesScrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !viewModel.availableUpdates.isEmpty {
                    updatesSummaryBanner
                        .padding(.horizontal)
                }

                ForEach(viewModel.sources, id: \.id) { item in
                    sourceRowView(for: item)
                }

                if totalFilteredAppCount == 0 {
                    VStack(spacing: 8) {
                        Text("lc.sources.section.noApps".loc)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 160, alignment: .center)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private func sourceRowView(for item: AltStoreSourcesViewModel.SourceItem) -> some View {
        let apps = filteredApps(for: item)
        return AltStoreSourceSectionView(
            item: item,
            filteredApps: apps,
            isFiltering: isFiltering,
            isExpanded: expandedSources.contains(item.id),
            onRefresh: { Task { await viewModel.refreshSource(item) } },
            onInstall: { sourceApp in
                install(app: sourceApp, from: item)
            },
            onRemove: { sourcePendingRemoval = item },
            toggleExpanded: { toggleExpansion(for: item.id) }
        )
        .padding(.horizontal)
        .animation(.easeInOut, value: apps.count)
    }

    @ToolbarContentBuilder
    private var sourcesToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isRefreshingAll {
                ProgressView()
            } else {
                Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                    Task { await viewModel.refreshAllSources() }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.availableUpdates.isEmpty {
                Button("Update All (\(viewModel.availableUpdates.count))") {
                    viewModel.enqueueUpdateAll()
                }
                .buttonStyle(.glassProminent)
            }
        }
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button("lc.sources.addSource".loc, systemImage: "plus") {
                isManagingSources = true
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var removeSourceAlertBinding: Binding<Bool> {
        Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } }
        )
    }

    private var updatesSummaryBanner: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(viewModel.availableUpdates.count) Updates Available", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.headline)
                    Spacer()
                    Button("Update All") {
                        viewModel.enqueueUpdateAll()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.availableUpdates) { candidate in
                            HStack(spacing: 8) {
                                Text(candidate.installedApp.displayName)
                                    .font(.caption.bold())
                                Text("→ \(candidate.latestVersion.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    viewModel.enqueueUpdate(candidate)
                                } label: {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.secondary.opacity(0.15), in: .capsule)
                        }
                    }
                }
            }
            .padding()
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }

    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }

    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        let lower = query.lowercased()
        return source.apps.filter { app in
            app.name.lowercased().contains(lower) ||
            app.bundleIdentifier.lowercased().contains(lower) ||
            (app.developerName?.lowercased().contains(lower) ?? false) ||
            (app.subtitle?.lowercased().contains(lower) ?? false)
        }
    }

    @MainActor
    private func handleAddSource(_ rawValue: String) async -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let error = await viewModel.addSource(from: trimmed)
        if let error {
            errorMessage = error
            return false
        }
        return true
    }

    @MainActor
    private func install(app: AltStoreSourceApp, from sourceItem: AltStoreSourcesViewModel.SourceItem) {
        guard let latest = app.latestVersion else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        let existing = viewModel.installedApp(matching: app)
        downloadManager.enqueueAppDownload(
            url: latest.downloadURL,
            displayName: "\(app.name) \(latest.version)",
            iconURL: app.iconURL,
            sourceURL: sourceItem.url.absoluteString,
            version: latest.version,
            buildVersion: latest.buildVersion,
            targetAppBundleId: app.bundleIdentifier,
            targetRelativePath: existing?.appInfo.relativeBundlePath
        )
    }

    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }

    func handleURL(url: URL) {
        if url.host == "source",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let sourceUrl = components.queryItems?.first(where: { $0.name == "url" })?.value {
            DataManager.shared.model.selectedTab = .sources
            Task { await handleAddSource(sourceUrl) }
        }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AltStoreSourcesViewModel
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool

    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @FocusState private var isManualFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .focused($isManualFieldFocused)

                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
    }

    private func resolvedIconURL(for item: AltStoreSourcesViewModel.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        return viewModel.sources.first(where: { $0.url == item.url })?.primaryIconURL
    }

    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

private struct AltStoreSourceSectionView: View {
    let item: AltStoreSourcesViewModel.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = item.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.sources.section.error".loc)
                        .font(.subheadline)
                        .bold()
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("lc.sources.refresh".loc, action: onRefresh)
                        .font(.footnote)
                }
                .padding()
                .background(Color(uiColor: UIColor.secondarySystemBackground), in: .rect(cornerRadius: 18))
            } else if let source = item.source, isExpanded || isFiltering {
                VStack(spacing: 12) {
                    ForEach(filteredApps[0..<min(50, filteredApps.count)]) { app in
                        LCSourceAppBanner(app: app, source: source, sourceURL: item.url, installAction: onInstall)
                    }
                    if filteredApps.isEmpty {
                        if source.apps.isEmpty || isFiltering {
                            Text("lc.sources.section.noApps".loc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if filteredApps.count > 50 {
                        Text("lc.sources.section.tooManyApps".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let sourceURL: URL
    let installAction: (AltStoreSourceApp) -> Void

    @ObservedObject private var sourcesVM = AltStoreSourcesViewModel.shared
    @EnvironmentObject private var downloadManager: LCDownloadManager
    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme

    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }

    private var textColor: Color {
        _ = colorScheme == .dark
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }

    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }

    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }

    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return app.developerName ?? ""
    }

    var body: some View {
        let activeTask = app.latestVersion.flatMap { downloadManager.activeTask(forURL: $0.downloadURL) }
            ?? downloadManager.activeTask(forBundleId: app.bundleIdentifier)
        let updateCandidate = sourcesVM.updateCandidate(for: app, in: sourceURL)
        let installedApp = sourcesVM.installedApp(matching: app)

        HStack {
            HStack(alignment: .center, spacing: 12) {
                SourceIconView(url: app.iconURL)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 16)).bold()
                        if app.isBeta {
                            Text("lc.sources.badge.beta".loc.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.orange, in: .capsule)
                        }
                    }
                    Text(metadataText)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    }
                }
            }
            .allowsHitTesting(false)
            Spacer()

            if let activeTask {
                Button {
                    downloadManager.cancel(activeTask)
                } label: {
                    HStack(spacing: 6) {
                        ProgressView(value: min(max(activeTask.progress, 0.05), 1))
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                }
                .buttonStyle(.glass)
            } else if updateCandidate != nil {
                Button("Update") {
                    installAction(app)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            } else if installedApp != nil {
                Button("Reinstall") {
                    installAction(app)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } else {
                Button("lc.common.install".loc) {
                    installAction(app)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
    }
}

private struct SourceIconView: View {
    let url: URL?

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty, .failure:
                    placeholder
                case .success(let image):
                    image.resizable().scaledToFill()
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image("DefaultIcon")
            .resizable()
            .scaledToFill()
    }
}

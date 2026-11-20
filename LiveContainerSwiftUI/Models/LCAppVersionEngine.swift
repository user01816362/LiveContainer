//
//  LCAppVersionEngine.swift
//  LiveContainerSwiftUI
//
//  Pure Sendable version comparator and multi-source catalog index
//  for update detection, version history, and safe downgrades.
//

import Foundation

enum LCVersionComparator {
    private enum Segment: Equatable, Sendable {
        case numeric(UInt64)
        case text(String)
    }

    private struct ParsedVersion: Sendable {
        let core: [Segment]
        let prerelease: [Segment]?
    }

    static func normalizeVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v"), trimmed.dropFirst().first?.isNumber == true {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func normalizeBuild(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func updateKey(version: String, build: String?) -> String {
        "\(version)#\(build ?? "")"
    }

    static func normalizedGroupKey(version: String, build: String?) -> String {
        let normVer = canonicalCoreKey(normalizeVersion(version))
        let normBuild = normalizeBuild(build) ?? ""
        return "\(normVer)#\(normBuild)"
    }

    static func matchesIgnoredKey(_ ignoredKey: String?, version: String, build: String?) -> Bool {
        guard let ignoredKey, !ignoredKey.isEmpty else { return false }
        if ignoredKey == updateKey(version: version, build: build) {
            return true
        }
        let parts = ignoredKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let ignoredVer = String(parts[0])
        let ignoredBuild = parts.count > 1 ? normalizeBuild(String(parts[1])) : nil
        return compare(version, build: build, to: ignoredVer, build: ignoredBuild) == .orderedSame
    }

    static func isNewer(
        _ lhsVersion: String,
        build lhsBuild: String?,
        than rhsVersion: String,
        build rhsBuild: String?
    ) -> Bool {
        compare(lhsVersion, build: lhsBuild, to: rhsVersion, build: rhsBuild) == .orderedDescending
    }

    static func compare(
        _ lhsVersion: String,
        build lhsBuild: String?,
        to rhsVersion: String,
        build rhsBuild: String?
    ) -> ComparisonResult {
        let lhsParsed = parse(normalizeVersion(lhsVersion))
        let rhsParsed = parse(normalizeVersion(rhsVersion))

        let coreResult = compareCore(lhsParsed.core, rhsParsed.core)
        if coreResult != .orderedSame {
            return coreResult
        }

        switch (lhsParsed.prerelease, rhsParsed.prerelease) {
        case (nil, nil):
            break
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case let (.some(lhsPre), .some(rhsPre)):
            let preResult = comparePrerelease(lhsPre, rhsPre)
            if preResult != .orderedSame {
                return preResult
            }
        }

        if let lhsB = normalizeBuild(lhsBuild), let rhsB = normalizeBuild(rhsBuild) {
            return compareBuildStrings(lhsB, rhsB)
        }

        return .orderedSame
    }

    private static func compareBuildStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParsed = parse(lhs)
        let rhsParsed = parse(rhs)
        let coreResult = compareCore(lhsParsed.core, rhsParsed.core)
        if coreResult != .orderedSame {
            return coreResult
        }
        return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private static func parse(_ normalized: String) -> ParsedVersion {
        // Strip SemVer "+buildMetadata" suffix if present
        let withoutMetadata: String
        if let plusIdx = normalized.firstIndex(of: "+") {
            withoutMetadata = String(normalized[..<plusIdx])
        } else {
            withoutMetadata = normalized
        }

        let coreString: String
        let prereleaseString: String?
        if let dashIdx = withoutMetadata.firstIndex(of: "-") {
            coreString = String(withoutMetadata[..<dashIdx])
            let afterDash = String(withoutMetadata[withoutMetadata.index(after: dashIdx)...])
            prereleaseString = afterDash.isEmpty ? nil : afterDash
        } else {
            coreString = withoutMetadata
            prereleaseString = nil
        }

        let core = coreString
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { parseSegment(String($0)) }

        let prerelease: [Segment]? = prereleaseString.map { pre in
            pre.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
                .map { parseSegment(String($0)) }
        }

        return ParsedVersion(core: core, prerelease: prerelease)
    }

    private static func parseSegment(_ raw: String) -> Segment {
        if !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let value = UInt64(raw) {
            return .numeric(value)
        }
        return .text(raw)
    }

    private static func compareCore(_ lhs: [Segment], _ rhs: [Segment]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lSeg: Segment = index < lhs.count ? lhs[index] : .numeric(0)
            let rSeg: Segment = index < rhs.count ? rhs[index] : .numeric(0)
            let result = compareSegments(lSeg, rSeg)
            if result != .orderedSame {
                return result
            }
        }
        return .orderedSame
    }

    private static func comparePrerelease(_ lhs: [Segment], _ rhs: [Segment]) -> ComparisonResult {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            let result = compareSegments(lhs[index], rhs[index])
            if result != .orderedSame {
                return result
            }
        }
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func compareSegments(_ lhs: Segment, _ rhs: Segment) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.numeric(a), .numeric(b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case let (.text(a), .text(b)):
            return a.compare(b, options: [.numeric, .caseInsensitive])
        case (.numeric, .text):
            return .orderedAscending
        case (.text, .numeric):
            return .orderedDescending
        }
    }

    private static func canonicalCoreKey(_ normalized: String) -> String {
        let parsed = parse(normalized)
        var core = parsed.core
        while core.count > 1, case .numeric(0) = core.last {
            core.removeLast()
        }
        let coreStr = core.map { segment -> String in
            switch segment {
            case .numeric(let value): return String(value)
            case .text(let value): return value.lowercased()
            }
        }.joined(separator: ".")

        if let prerelease = parsed.prerelease, !prerelease.isEmpty {
            let preStr = prerelease.map { segment -> String in
                switch segment {
                case .numeric(let value): return String(value)
                case .text(let value): return value.lowercased()
                }
            }.joined(separator: ".")
            return "\(coreStr)-\(preStr)"
        }
        return coreStr
    }
}

enum LCAppVersionRelation: String, Hashable, Sendable {
    case update
    case installed
    case downgrade
    case available
}

struct LCSourceVersionOffer: Identifiable, Hashable, Sendable {
    let id: String
    let sourceURL: URL
    let sourceName: String
    let sourceIconURL: URL?
    let sourceAppName: String
    let bundleIdentifier: String
    let appIconURL: URL?
    let isBeta: Bool
    let version: String
    let buildVersion: String?
    let releaseDate: Date?
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int64?

    var displayVersion: String {
        if let build = LCVersionComparator.normalizeBuild(buildVersion) {
            return "\(version) (\(build))"
        }
        return version
    }

    var updateKey: String {
        LCVersionComparator.updateKey(version: version, build: buildVersion)
    }
}

struct LCAppVersionGroup: Identifiable, Hashable, Sendable {
    let id: String
    let version: String
    let buildVersion: String?
    let relation: LCAppVersionRelation
    let primaryOffer: LCSourceVersionOffer
    let offers: [LCSourceVersionOffer]
    let bestReleaseDate: Date?
    let bestSize: Int64?
    let bestReleaseNotes: String?
    let isBeta: Bool
    let isIgnoredUpdate: Bool

    var displayVersion: String {
        if let build = LCVersionComparator.normalizeBuild(buildVersion) {
            return "\(version) (\(build))"
        }
        return version
    }

    var updateKey: String {
        LCVersionComparator.updateKey(version: version, build: buildVersion)
    }
}

struct AltStoreCatalogSourceSnapshot: Sendable {
    let url: URL
    let displayName: String
    let iconURL: URL?
    let source: AltStoreSource
}

struct AltStoreCatalogSourceAppEntry: Sendable {
    let sourceURL: URL
    let sourceName: String
    let sourceApp: AltStoreSourceApp
}

struct AltStoreCatalogIndex: Sendable {
    static let empty = AltStoreCatalogIndex(
        offersByBundleId: [:],
        distinctVersionCountsByBundleId: [:],
        sourceAppsByBundleId: [:]
    )

    let offersByBundleId: [String: [LCSourceVersionOffer]]
    let distinctVersionCountsByBundleId: [String: Int]
    let sourceAppsByBundleId: [String: [AltStoreCatalogSourceAppEntry]]

    static func build(from snapshots: [AltStoreCatalogSourceSnapshot]) -> AltStoreCatalogIndex {
        var offersByBundle: [String: [LCSourceVersionOffer]] = [:]
        var sourceAppsByBundle: [String: [AltStoreCatalogSourceAppEntry]] = [:]
        var seenOfferIDsByBundle: [String: Set<String>] = [:]
        var versionKeysByBundle: [String: Set<String>] = [:]

        for snapshot in snapshots {
            for app in snapshot.source.apps {
                let bundleKey = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !bundleKey.isEmpty else { continue }

                sourceAppsByBundle[bundleKey, default: []].append(
                    AltStoreCatalogSourceAppEntry(
                        sourceURL: snapshot.url,
                        sourceName: snapshot.displayName,
                        sourceApp: app
                    )
                )

                let versionsToIndex: [AltStoreSourceAppVersion]
                if !app.versions.isEmpty {
                    versionsToIndex = app.versions
                } else if let latest = app.latestVersion {
                    versionsToIndex = [latest]
                } else {
                    versionsToIndex = []
                }

                for versionItem in versionsToIndex {
                    let offerID = "\(snapshot.url.absoluteString)#\(versionItem.downloadURL.absoluteString)#\(versionItem.version)#\(versionItem.buildVersion ?? "")"
                    if seenOfferIDsByBundle[bundleKey, default: []].contains(offerID) {
                        continue
                    }
                    seenOfferIDsByBundle[bundleKey, default: []].insert(offerID)

                    let offer = LCSourceVersionOffer(
                        id: offerID,
                        sourceURL: snapshot.url,
                        sourceName: snapshot.displayName,
                        sourceIconURL: snapshot.iconURL,
                        sourceAppName: app.name,
                        bundleIdentifier: app.bundleIdentifier,
                        appIconURL: app.iconURL,
                        isBeta: app.isBeta,
                        version: versionItem.version,
                        buildVersion: versionItem.buildVersion,
                        releaseDate: versionItem.releaseDate,
                        localizedDescription: versionItem.localizedDescription,
                        downloadURL: versionItem.downloadURL,
                        size: versionItem.size
                    )
                    offersByBundle[bundleKey, default: []].append(offer)
                    let groupKey = LCVersionComparator.normalizedGroupKey(
                        version: versionItem.version,
                        build: versionItem.buildVersion
                    )
                    versionKeysByBundle[bundleKey, default: []].insert(groupKey)
                }
            }
        }

        let distinctCounts = versionKeysByBundle.mapValues(\.count)
        return AltStoreCatalogIndex(
            offersByBundleId: offersByBundle,
            distinctVersionCountsByBundleId: distinctCounts,
            sourceAppsByBundleId: sourceAppsByBundle
        )
    }

    func versionCount(forBundleId bundleId: String) -> Int {
        let key = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return distinctVersionCountsByBundleId[key] ?? 0
    }

    func sourceApps(forBundleId bundleId: String) -> [AltStoreCatalogSourceAppEntry] {
        let key = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sourceAppsByBundleId[key] ?? []
    }

    func versionGroups(
        forBundleId bundleId: String,
        installedVersion: String?,
        installedBuild: String?,
        preferredSourceURL: String?,
        ignoredUpdateKey: String?
    ) -> [LCAppVersionGroup] {
        let key = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let rawOffers = offersByBundleId[key], !rawOffers.isEmpty else {
            return []
        }

        var grouped: [String: [LCSourceVersionOffer]] = [:]
        for offer in rawOffers {
            let groupKey = LCVersionComparator.normalizedGroupKey(version: offer.version, build: offer.buildVersion)
            grouped[groupKey, default: []].append(offer)
        }

        var groups: [LCAppVersionGroup] = []
        groups.reserveCapacity(grouped.count)

        for (groupKey, groupOffers) in grouped {
            let sortedOffers = groupOffers.sorted { lhs, rhs in
                let lhsPref = preferredSourceURL != nil && lhs.sourceURL.absoluteString == preferredSourceURL
                let rhsPref = preferredSourceURL != nil && rhs.sourceURL.absoluteString == preferredSourceURL
                if lhsPref != rhsPref { return lhsPref }

                let lhsScore = metadataRichnessScore(lhs)
                let rhsScore = metadataRichnessScore(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }

                return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
            }

            guard let primary = sortedOffers.first else { continue }

            let relation: LCAppVersionRelation
            if let installedVersion, !installedVersion.isEmpty {
                switch LCVersionComparator.compare(primary.version, build: primary.buildVersion, to: installedVersion, build: installedBuild) {
                case .orderedDescending:
                    relation = .update
                case .orderedSame:
                    relation = .installed
                case .orderedAscending:
                    relation = .downgrade
                }
            } else {
                relation = .available
            }

            let bestDate = sortedOffers.compactMap(\.releaseDate).max()
            let bestSize = sortedOffers.compactMap(\.size).first(where: { $0 > 0 })
            let bestNotes = sortedOffers
                .compactMap { offer -> String? in
                    let trimmed = offer.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (trimmed?.isEmpty == false) ? trimmed : nil
                }
                .max(by: { $0.count < $1.count })
            let isIgnored = relation == .update
                && LCVersionComparator.matchesIgnoredKey(ignoredUpdateKey, version: primary.version, build: primary.buildVersion)

            groups.append(LCAppVersionGroup(
                id: groupKey,
                version: primary.version,
                buildVersion: primary.buildVersion,
                relation: relation,
                primaryOffer: primary,
                offers: sortedOffers,
                bestReleaseDate: bestDate,
                bestSize: bestSize,
                bestReleaseNotes: bestNotes,
                isBeta: sortedOffers.allSatisfy(\.isBeta),
                isIgnoredUpdate: isIgnored
            ))
        }

        return groups.sorted { lhs, rhs in
            let cmp = LCVersionComparator.compare(lhs.version, build: lhs.buildVersion, to: rhs.version, build: rhs.buildVersion)
            if cmp != .orderedSame {
                return cmp == .orderedDescending
            }
            if let lDate = lhs.bestReleaseDate, let rDate = rhs.bestReleaseDate, lDate != rDate {
                return lDate > rDate
            }
            let lhsPref = preferredSourceURL != nil && lhs.primaryOffer.sourceURL.absoluteString == preferredSourceURL
            let rhsPref = preferredSourceURL != nil && rhs.primaryOffer.sourceURL.absoluteString == preferredSourceURL
            if lhsPref != rhsPref {
                return lhsPref
            }
            return lhs.id > rhs.id
        }
    }

    private func metadataRichnessScore(_ offer: LCSourceVersionOffer) -> Int {
        var score = 0
        if let notes = offer.localizedDescription, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 2
        }
        if let size = offer.size, size > 0 {
            score += 1
        }
        if offer.releaseDate != nil {
            score += 1
        }
        if !offer.isBeta {
            score += 1
        }
        return score
    }
}

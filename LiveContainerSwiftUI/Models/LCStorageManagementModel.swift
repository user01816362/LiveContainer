import Foundation
import Combine

struct LCAppStorageItem: Identifiable, Sendable {
    let id: UUID

    let appModel: LCAppModel
    let bundleSize: Int64?
    let containersSize: Int64

    let totalSize: Int64

    let containerDetails: [LCAppStorageContainerItem]
}

struct LCAppStorageContainerItem: Identifiable, Sendable {
    let id: UUID
    let name: String
    let size: Int64
    let isExternalContainer: Bool
}

struct LCStorageBreakdown: Sendable {
    let totalSize: Int64
    let appBundleSize: Int64
    let containersSize: Int64
    let temporaryFilesSize: Int64
    let appGroupSize: Int64
    let tweaksSize: Int64
    let otherSize: Int64

    let appItems: [LCAppStorageItem]
}

@MainActor
final class LCStorageManagementModel: ObservableObject {
    @Published var breakdown: LCStorageBreakdown?
    @Published var isCalculating = false
    @Published var errorInfo: String?

    private struct ContainerSnapshot: Sendable {
        let name: String
        let url: URL
        let bookmarkResolved: Bool
        let isExternal: Bool
    }

    private struct AppSnapshot: Sendable {
        let appModel: LCAppModel
        let displayName: String
        let bundlePath: String?
        let isBuiltInSideStore: Bool
        let containers: [ContainerSnapshot]
    }

    func refresh(apps: [LCAppModel], hiddenApps: [LCAppModel]) async {
        guard !isCalculating else {
            return
        }

        isCalculating = true
        defer { isCalculating = false }
        errorInfo = nil
        breakdown = nil

        var allApps = DataManager.shared.model.isHiddenAppUnlocked ? (apps + hiddenApps) : apps
        if UserDefaults.sideStoreExist() {
            allApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }

        let snapshots = allApps.map { model in
            AppSnapshot(
                appModel: model,
                displayName: model.displayName,
                bundlePath: model.appInfo.bundlePath(),
                isBuiltInSideStore: model.appInfo is BuiltInSideStoreAppInfo,
                containers: model.uiContainers.map { container in
                    ContainerSnapshot(
                        name: container.name,
                        url: container.containerURL,
                        bookmarkResolved: container.bookmarkResolved,
                        isExternal: container.storageBookMark != nil
                    )
                }
            )
        }

        do {
            breakdown = try await Self.calculateBreakdown(from: snapshots)
        } catch {
            errorInfo = error.localizedDescription
        }
    }

    private enum StorageCategory: Sendable {
        case appBundle
        case containers
        case temporaryFiles
        case appGroup
        case tweaks
    }

    nonisolated private static func calculateBreakdown(from snapshots: [AppSnapshot]) async throws -> LCStorageBreakdown {
        let appItems = try await calculateAppItems(from: snapshots)

        var sizesByCategory: [StorageCategory: Int64] = [:]
        
        let knownRoots = uniquePaths([LCPath.docPath, LCPath.lcGroupDocPath])
        let appGroupRoots = uniquePaths([LCPath.appGroupPath, LCPath.lcGroupAppGroupPath])
        let tweakRoots = uniquePaths([LCPath.tweakPath, LCPath.lcGroupTweakPath])
        
        
        sizesByCategory[.appBundle] = 0
        sizesByCategory[.containers] = 0
        
        let builtInSideStoreIDs = Set(snapshots.filter(\.isBuiltInSideStore).map { ObjectIdentifier($0.appModel) })
        for appItem in appItems {
            if !builtInSideStoreIDs.contains(ObjectIdentifier(appItem.appModel)) {
                sizesByCategory[.appBundle]! += appItem.bundleSize ?? 0
            }
            
            for containerDetail in appItem.containerDetails {
                if containerDetail.isExternalContainer {
                    continue
                }
                sizesByCategory[.containers]! += containerDetail.size
            }
        }

        try await withThrowingTaskGroup(of: (StorageCategory, Int64).self) { group in

            group.addTask(priority: .utility) {
                (.temporaryFiles, try await calculateSize(at: FileManager.default.temporaryDirectory))
            }

            group.addTask(priority: .utility) {
                (.appGroup, try await calculateCombinedSize(of: appGroupRoots))
            }

            group.addTask(priority: .utility) {
                // Surface tweaks as a top-level bucket so managed tweak storage does not disappear into Other.
                (.tweaks, try await calculateCombinedSize(of: tweakRoots))
            }

            for try await (category, size) in group {
                sizesByCategory[category] = size
            }
        }

        let appBundleSize = sizesByCategory[.appBundle] ?? 0
        let containersSize = sizesByCategory[.containers] ?? 0
        let temporaryFilesSize = sizesByCategory[.temporaryFiles] ?? 0
        let appGroupSize = sizesByCategory[.appGroup] ?? 0
        let tweaksSize = sizesByCategory[.tweaks] ?? 0
        let knownRootsSize = try await calculateCombinedSize(of: knownRoots)
        var librarySize: Int64 = 0
        if let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            librarySize = try await calculateSize(at: libraryPath)
        }
        // Other is the residual after explicit categories are removed from the known storage roots, plus loose root-level files.
        let residualOtherSize = knownRootsSize - appBundleSize - containersSize - appGroupSize - tweaksSize
        let otherSize = residualOtherSize + librarySize

        return LCStorageBreakdown(
            totalSize: appBundleSize + containersSize + temporaryFilesSize + appGroupSize + tweaksSize + otherSize,
            appBundleSize: appBundleSize,
            containersSize: containersSize,
            temporaryFilesSize: temporaryFilesSize,
            appGroupSize: appGroupSize,
            tweaksSize: tweaksSize,
            otherSize: otherSize,
            appItems: appItems
        )
    }

    nonisolated private static func calculateAppItem(
        from input: AppSnapshot
    ) async throws -> LCAppStorageItem {
        var containerDetails: [LCAppStorageContainerItem] = []
        containerDetails.reserveCapacity(input.containers.count)

        var containersSize: Int64 = 0
        for container in input.containers {
            if container.bookmarkResolved {
                let _ = container.url.startAccessingSecurityScopedResource()
            }
            
            let size = try await calculateSize(at: container.url)
            
            if container.bookmarkResolved {
                container.url.stopAccessingSecurityScopedResource()
            }
            
            if !container.isExternal {
                containersSize += size
            }
            containerDetails.append(
                LCAppStorageContainerItem(
                    id: UUID(),
                    name: container.name,
                    size: size,
                    isExternalContainer: container.isExternal
                )
            )
        }


        let bundleSize: Int64?
        if let bundlePath = input.bundlePath {
            bundleSize = try await calculateSize(at: URL(fileURLWithPath: bundlePath))
        } else {
            bundleSize = nil
        }
        
        let totalSize: Int64
        if input.isBuiltInSideStore {
            totalSize = containersSize
        } else {
            totalSize = (bundleSize ?? 0) + containersSize
        }

        return LCAppStorageItem(
            id: UUID(),
            appModel: input.appModel,
            bundleSize: bundleSize,
            containersSize: containersSize,
            totalSize: totalSize,
            containerDetails: containerDetails
        )
    }

    nonisolated private static func calculateAppItems(
        from inputs: [AppSnapshot]
    ) async throws -> [LCAppStorageItem] {
        var itemsWithNames: [(LCAppStorageItem, String)] = []
        itemsWithNames.reserveCapacity(inputs.count)

        try await withThrowingTaskGroup(of: (LCAppStorageItem, String).self) { group in
            for input in inputs {
                let name = input.displayName
                group.addTask(priority: .utility) {
                    (try await calculateAppItem(from: input), name)
                }
            }

            for try await pair in group {
                itemsWithNames.append(pair)
            }
        }

        return itemsWithNames.sorted {
            if $0.0.totalSize == $1.0.totalSize {
                return $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending
            }
            return $0.0.totalSize > $1.0.totalSize
        }.map(\.0)
    }

    nonisolated private static func calculateCombinedSize(of urls: [URL]) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for url in uniquePaths(urls) {
                group.addTask(priority: .utility) {
                    try await calculateSize(at: url)
                }
            }

            var totalSize: Int64 = 0
            for try await size in group {
                totalSize += size
            }
            return totalSize
        }
    }

    nonisolated private static func uniquePaths(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                continue
            }
            uniqueURLs.append(url)
        }

        return uniqueURLs
    }

    nonisolated private static func calculateSize(at url: URL) async throws -> Int64 {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues.isRegularFile == true else {
                continue
            }

            let fileSize = resourceValues.totalFileAllocatedSize
                ?? resourceValues.fileAllocatedSize
                ?? resourceValues.fileSize
                ?? 0
            totalSize += Int64(fileSize)
        }

        return totalSize
    }
}

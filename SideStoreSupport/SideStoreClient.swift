//
//  SideStoreClient.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import OSLog
import os

enum SideStoreIntentError: LocalizedError, Sendable {
    case typeNotFound(String)
    case typeIsNotAppIntent(String)

    var errorDescription: String? {
        switch self {
        case .typeNotFound(let name):
            return "SideStore refresh intent type was not found: \(name)"
        case .typeIsNotAppIntent(let name):
            return "SideStore type is not an AppIntent: \(name)"
        }
    }
}

private func resolveType(_ mangledTypeName: String) throws -> any Any.Type {
    let bytes = Array(mangledTypeName.utf8)
    let resolvedType: Any.Type? = bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return nil
        }

        // Swift exposes the runtime symbol swift_getTypeByMangledNameInContext
        // as _getTypeByMangledNameInContext. The name intentionally omits
        // the "$s" prefix, which is the form accepted for this module.
        return _getTypeByMangledNameInContext(
            baseAddress,
            UInt(buffer.count),
            genericContext: nil,
            genericArguments: nil
        )
    }

    guard let resolvedType else {
        throw SideStoreIntentError.typeNotFound(mangledTypeName)
    }

    return resolvedType
}

struct SideStoreIntentCaller {
    static let shared = SideStoreIntentCaller()

    // call this when a IntentContext already exists (when sidestore is loaded in LiveContainer itself)
    func callRefreshIntent(mangledTypeName: String) async throws {
        let resolvedType = try resolveType(mangledTypeName)
        guard let intentType = resolvedType as? any ProgressReportingIntent.Type else {
            throw SideStoreIntentError.typeIsNotAppIntent(mangledTypeName)
        }

        let intent = intentType.init()
        let _ = try await intent.perform()
    }

    // call this when no IntentContext exists (when sidestore is loaded in LiveProcess)
    func callRefreshIntent2(identifier: String, mangledTypeName: String, progressCallback: (Progress) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let parent = PrivateIntentRunner.run(
                identifier: identifier,
                mangledTypeName: mangledTypeName
            ) { result, error in
                print("performAction result=\(String(describing: result)), " +
                      "error=\(String(describing: error))")
                let shouldResume = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard shouldResume else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            if let parent {
                progressCallback(parent)
            }
        }
    }
}

@objc extension SideStoreClient {
    @objc(performRefreshForRealWithIdentifier:mangledTypeName:server:)
    func performRefreshForReal(identifier: String, mangledTypeName: String, server: any RefreshServer) {
        Task {
            let obsLock = OSAllocatedUnfairLock<NSKeyValueObservation?>(initialState: nil)
            defer {
                obsLock.withLock {
                    $0?.invalidate()
                    $0 = nil
                }
            }
            do {
                try await SideStoreIntentCaller.shared.callRefreshIntent2(identifier: identifier, mangledTypeName: mangledTypeName) { progress in
                    let observation = progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                        if let newValue = change.newValue {
                            server.updateProgress(newValue)
                        }
                    }
                    obsLock.withLock { $0 = observation }
                }
                server.finish(nil)
            } catch {
                server.finish(error.localizedDescription)
            }
        }
    }

}

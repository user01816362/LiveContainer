//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import Foundation
import os

enum MultitaskMode : Int, Sendable {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc final class MultitaskManager : NSObject {
    private static let usingContainers = OSAllocatedUnfairLock(initialState: [String]())
    
    @objc class func registerMultitaskContainer(container: String) {
        usingContainers.withLock { list in
            if !list.contains(container) {
                list.append(container)
            }
        }
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        usingContainers.withLock { list in
            list.removeAll(where: { $0 == container })
        }
    }
    
    @objc class func isUsing(container: String) -> Bool {
        usingContainers.withLock { $0.contains(container) }
    }
    
    @objc class func isMultitasking() -> Bool {
        usingContainers.withLock { !$0.isEmpty }
    }
}

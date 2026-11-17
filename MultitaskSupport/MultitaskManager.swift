//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private let lock = NSLock()
    static private var usingMultitaskContainers : [String] = []
    
    @objc class func registerMultitaskContainer(container: String) {
        lock.withLock {
            if !usingMultitaskContainers.contains(container) {
                usingMultitaskContainers.append(container)
            }
        }
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        lock.withLock {
            usingMultitaskContainers.removeAll(where: { $0 == container })
        }
    }
    
    @objc class func isUsing(container: String) -> Bool {
        lock.withLock {
            usingMultitaskContainers.contains(container)
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        lock.withLock {
            !usingMultitaskContainers.isEmpty
        }
    }
}

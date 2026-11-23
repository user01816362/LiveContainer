//
//  Shared.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/22.
//

import SwiftUI
import UniformTypeIdentifiers
import SafariServices
import Security
import Combine

struct LCPath {
    public static let docPath = {
        let fm = FileManager()
        return fm.urls(for: .documentDirectory, in: .userDomainMask).last!
    }()
    public static let bundlePath = docPath.appendingPathComponent("Applications")
    public static let dataPath = docPath.appendingPathComponent("Data/Application")
    public static let appGroupPath = docPath.appendingPathComponent("Data/AppGroup")
    public static let tweakPath = docPath.appendingPathComponent("Tweaks")
    
    public static let lcGroupDocPath = {
        let fm = FileManager()
        // it seems that Apple don't want to create one for us, so we just borrow our Store's
        if let appGroupPathUrl = LCSharedUtils.appGroupPath() {
            return appGroupPathUrl.appendingPathComponent("LiveContainer")
        } else if let appGroupPathUrl =
                    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.SideStore.SideStore") {
            return appGroupPathUrl.appendingPathComponent("LiveContainer")
        } else {
            return docPath
        }
    }()
    public static let lcGroupBundlePath = lcGroupDocPath.appendingPathComponent("Applications")
    public static let lcGroupDataPath = lcGroupDocPath.appendingPathComponent("Data/Application")
    public static let lcGroupAppGroupPath = lcGroupDocPath.appendingPathComponent("Data/AppGroup")
    public static let lcGroupTweakPath = lcGroupDocPath.appendingPathComponent("Tweaks")
    
    public static func ensureAppGroupPaths() throws {
        let fm = FileManager()
        if !fm.fileExists(atPath: LCPath.lcGroupBundlePath.path) {
            try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupDataPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupDataPath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupTweakPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupTweakPath, withIntermediateDirectories: true)
        }
    }
}

@MainActor
class SharedModel: ObservableObject {
    @Published var selectedTab: LCTabIdentifier = .apps
    @Published var deepLink: URL?
    
    @Published var isHiddenAppUnlocked = false
    @Published var developerMode = false
    // 0 = current liveContainer is the primary one,
    // 2 = current liveContainer is not the primary one
    @Published var multiLCStatus = 0
    @Published var isJITModalOpen = false
    
    @Published var enableMultipleWindow = false

    @Published var appDataFolderNames: [String] = []
    @Published var tweakFolderNames: [String] = []
    
    @Published var apps : [LCAppModel] = []
    @Published var arm32EmuApps : [LCAppModel] = []
    @Published var hiddenApps : [LCAppModel] = []
    
    @Published var pidCallback : (@Sendable (NSNumber, Error?) -> Void)? = nil
    @Published var activeDebugApp : LCAppModel? = nil
    var appModelDelegate : LCAppModelDelegate? = nil
    
    static let isPhone: Bool = {
        UIDevice.current.userInterfaceIdiom == .phone
    }()
    
    static let isLiquidGlassEnabled: Bool = {
        if let compatibilityEnabled = Bundle.main.infoDictionary?["UIDesignRequiresCompatibility"] as? Bool, compatibilityEnabled {
            return false
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_UISolariumEnabled") {
            return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)()
        }
        return true
    }()
    
    var mainWindowOpened = false
    
    public static let keychainAccessGroupCount = 128
    
    func updateMultiLCStatus() {
        if LCUtils.appUrlScheme()?.lowercased() != "livecontainer" {
            multiLCStatus = 2
        } else {
            multiLCStatus = 0
        }
    }
    
    init() {
        updateMultiLCStatus()
    }
}

@MainActor
class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
    var sourcesViewModel: AltStoreSourcesViewModel {
        AltStoreSourcesViewModel.shared
    }
}

@MainActor
class AlertHelper<T: Sendable> : ObservableObject {
    @Published var show = false
    private var continuation : CheckedContinuation<T?, Never>? = nil
    
    func open() async -> T? {
        if let existing = continuation {
            self.continuation = nil
            existing.resume(returning: nil)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.show = true
        }
    }
    
    func close(result: T?) {
        self.show = false
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }
}

typealias YesNoHelper = AlertHelper<Bool>

@MainActor
class InputHelper : AlertHelper<String> {
    @Published var initVal = ""
    
    func open(initVal: String) async -> String? {
        self.initVal = initVal
        return await super.open()
    }
    
    override func open() async -> String? {
        self.initVal = ""
        return await super.open()
    }
}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
        
    private static let enBundle : Bundle? = {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    }()
    
    var loc: String {
        let message = NSLocalizedString(self, comment: "")
        if message != self {
            return message
        }

        if let forcedString = String.enBundle?.localizedString(forKey: self, value: nil, table: nil){
            return forcedString
        }else {
            return self
        }
    }
    
    func localizeWithFormat(_ arguments: CVarArg...) -> String{
        String.localizedStringWithFormat(self.loc, arguments)
    }
    
    func sanitizeNonACSII() -> String  {
        filter { $0.isASCII }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa")!
    static let tipa = UTType(filenameExtension: "tipa")!
    static let dylib = UTType(filenameExtension: "dylib")!
    static let deb = UTType(filenameExtension: "deb")!
    static let zipArchive = UTType(filenameExtension: "zip")!
    static let lcFramework = UTType(filenameExtension: "framework", conformingTo: .package)!
    static let p12 = UTType(filenameExtension: "p12")!
    static let tarArchiveCompat = UTType(filenameExtension: "tar") ?? .data
    static let gzArchive = UTType(filenameExtension: "gz") ?? .gzip
    static let tgzArchive = UTType(filenameExtension: "tgz") ?? .gzip
    static let xzArchive = UTType(filenameExtension: "xz") ?? .data
    static let bz2Archive = UTType(filenameExtension: "bz2") ?? .bz2
}

extension Color {
    func readableTextColor() -> Color {
        let color = Color(.systemBackground)
        let percentage = 0.5

        var fgR: CGFloat = 0, fgG: CGFloat = 0, fgB: CGFloat = 0, fgA: CGFloat = 0
        if !UIColor(self).getRed(&fgR, green: &fgG, blue: &fgB, alpha: &fgA) {
            var white: CGFloat = 0.5
            if UIColor(self).getWhite(&white, alpha: &fgA) {
                fgR = white
                fgG = white
                fgB = white
            }
        }
        var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        if !UIColor(color).getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA) {
            var white: CGFloat = 0.5
            if UIColor(color).getWhite(&white, alpha: &bgA) {
                bgR = white
                bgG = white
                bgB = white
            }
        }
        var red = (1.0 - percentage) * fgR + percentage * bgR
        var green = (1.0 - percentage) * fgG + percentage * bgG
        var blue = (1.0 - percentage) * fgB + percentage * bgB
        
        let brightness = (0.2126*red + 0.7152*green + 0.0722*blue)
        let brightnessOffset = brightness < 0.5 ? 0.4 : -0.4
        red = min(max(Double(red) + brightnessOffset, 0.0), 1.0)
        green = min(max(Double(green) + brightnessOffset, 0.0), 1.0)
        blue = min(max(Double(blue) + brightnessOffset, 0.0), 1.0)
        return Color(red: red, green: green, blue: blue)
    }
}

struct SiteAssociationDetailItem : Decodable, Sendable {
    var appID: String?
    var appIDs: [String]?
    
    func getBundleIds() -> [String] {
        var ans : [String] = []
        if let appID {
            let bundleID = Self.extractBundleID(from: appID)
            if !bundleID.isEmpty {
                ans.append(bundleID)
            }
        }
        if let appIDs {
            for appID in appIDs {
                let bundleID = Self.extractBundleID(from: appID)
                if !bundleID.isEmpty {
                    ans.append(bundleID)
                }
            }
        }
        return ans
    }

    private static func extractBundleID(from appID: String) -> String {
        guard let dot = appID.firstIndex(of: ".") else {
            return ""
        }
        return String(appID[appID.index(after: dot)...])
    }
}

struct AppLinks : Decodable, Sendable {
    var details : [SiteAssociationDetailItem]?

    enum CodingKeys: String, CodingKey {
        case details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? container.decode([SiteAssociationDetailItem].self, forKey: .details) {
            details = array
            return
        }
        if let dictionary = try? container.decode([String: SiteAssociationDetailItem].self, forKey: .details) {
            details = dictionary.map { appID, item in
                var item = item
                if item.appID == nil {
                    item.appID = appID
                }
                return item
            }
            return
        }
        details = nil
    }
}

struct SiteAssociation : Decodable, Sendable {
    var applinks: AppLinks?
}


struct JITStreamerEBLaunchAppResponse : Codable, Sendable {
    let ok: Bool
    let launching: Bool
    let position: Int?
    let error: String?
}

struct JITStreamerEBStatusResponse : Codable, Sendable {
    let ok: Bool
    let done: Bool
    let position: Int?
    let error: String?
}

struct JITStreamerEBMountResponse : Codable, Sendable {
    let ok: Bool
    let mounting: Bool
    let error: String?
}



extension NSNotification {
    static let InstallAppNotification = Notification.Name.init("InstallAppNotification")
}

public enum LCTabIdentifier: Hashable, Sendable {
    case sources
    case apps
    case tweaks
    case settings
}


enum BatchMoveError: LocalizedError, Sendable {
    case emptySource(URL)
    case sourceDoesNotExist(URL)
    case sourceIsNotReachable(URL, underlying: Error)
    case sourceParentIsNotWritable(URL)
    case destinationAlreadyExists(URL)
    case destinationParentDoesNotExist(URL)
    case destinationParentIsNotDirectory(URL)
    case destinationParentIsNotWritable(URL)
    case duplicateSource(URL)
    case duplicateDestination(URL)
    case sourceEqualsDestination(URL)
    case moveWouldPlaceDirectoryInsideItself(source: URL, destination: URL)
    case moveFailed(source: URL, destination: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .emptySource(let url):
            return "Source URL is invalid: \(url)"
        case .sourceDoesNotExist(let url):
            return "Source does not exist: \(url.path)"
        case .sourceIsNotReachable(let url, let error):
            return "Source is not reachable: \(url.path). \(error)"
        case .sourceParentIsNotWritable(let url):
            return "Source parent is not writable: : \(url.path)"
        case .destinationAlreadyExists(let url):
            return "Destination already exists: \(url.path). Delete or rename this file/folder to continue."
        case .destinationParentDoesNotExist(let url):
            return "Destination parent directory does not exist: \(url.path)"
        case .destinationParentIsNotDirectory(let url):
            return "Destination parent is not a directory: \(url.path)"
        case .destinationParentIsNotWritable(let url):
            return "Destination parent is not writable: \(url.path)"
        case .duplicateSource(let url):
            return "Duplicate source URL in move list: \(url.path)"
        case .duplicateDestination(let url):
            return "Duplicate destination URL in move list: \(url.path)"
        case .sourceEqualsDestination(let url):
            return "Source and destination are the same: \(url.path)"
        case .moveWouldPlaceDirectoryInsideItself(let source, let destination):
            return "Cannot move directory \(source.path) inside itself at \(destination.path)"
        case .moveFailed(let source, let destination, let error):
            return "Failed to move \(source.path) to \(destination.path). \(error)"
        }
    }

}

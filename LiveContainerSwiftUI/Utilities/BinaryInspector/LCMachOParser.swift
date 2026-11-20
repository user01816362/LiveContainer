//
//  LCMachOParser.swift
//  LiveContainerSwiftUI
//
//  Hardened, bounds-checked Mach-O binary parser, `LC_CODE_SIGNATURE` and
//  entitlements decoder, bundle target discovery, and LiveContainer
//  Compatibility Doctor. Operates exclusively via POSIX `pread(2)` reads.
//

import CryptoKit
import Foundation
import MachO

/// Internal parsed context shared across ObjC, Swift, Symbol, and String analyzers.
struct LCMachOParsedSliceContext: Sendable {
    let overview: LCMachOOverviewResult
    let vmMap: LCMachOVMMap
    let chainedFixups: LCMachOChainedFixupsDecoder
    let symtabOffset: UInt64?
    let symtabCount: UInt32
    let strtabOffset: UInt64?
    let strtabSize: UInt32
    let exportsTrieOffset: UInt64?
    let exportsTrieSize: UInt32
}

/// Hardened nonisolated Mach-O binary parser and LiveContainer Compatibility Doctor.
enum LCMachOParser {
    private static let maxLoadCommands: UInt32 = 8192
    private static let maxSectionsPerSegment: UInt32 = 1024
    private static let maxFatSlices: UInt32 = 64

    // Custom LiveContainer marker for disabled TweakLoader command
    private static let lcDisabledTweakLoaderCmd: UInt32 = 0x114514

    // Code signature blob magics (big-endian)
    private static let csMagicEmbeddedSignature: UInt32 = 0xfade0cc0
    private static let csMagicCodeDirectory: UInt32 = 0xfade0c02
    private static let csMagicEntitlements: UInt32 = 0xfade7171
    private static let csMagicDEREntitlements: UInt32 = 0xfade7172
    private static let csMagicBlobWrapper: UInt32 = 0xfade0b01

    private static let csSlotCodeDirectory: UInt32 = 0
    private static let csSlotEntitlements: UInt32 = 5
    private static let csSlotDEREntitlements: UInt32 = 7
    private static let csSlotSignature: UInt32 = 0x10000

    // MARK: - Bundle Target Discovery

    /// Lists all inspectable Mach-O binaries inside an app bundle (main executable,
    /// embedded `.framework`s, `.dylib`s, and `PlugIns/*.appex` executables),
    /// including `.disabled`-suffixed tweak payloads.
    static func listBundleTargets(
        bundleURL: URL,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) -> [LCMachOTargetItem] {
        let scopeRoot = rootURL ?? bundleURL
        let result = try? LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            var targets: [LCMachOTargetItem] = []
            var seenPaths = Set<String>()
            let rootPrefix = bundleURL.path.hasSuffix("/") ? bundleURL.path : bundleURL.path + "/"

            if let mainExec = LCBoundedFileReader.resolveMachOExecutableURL(for: bundleURL) {
                seenPaths.insert(mainExec.standardizedFileURL.path)
                targets.append(LCMachOTargetItem(
                    id: "main:\(mainExec.path)",
                    displayName: mainExec.lastPathComponent,
                    relativePath: mainExec.lastPathComponent,
                    executableURL: mainExec,
                    bundleURL: bundleURL,
                    kind: .appExecutable
                ))
            }

            let fm = FileManager.default
            if let enumerator = fm.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let itemURL as URL in enumerator {
                    if Task.isCancelled { break }
                    let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
                    let isDir = values?.isDirectory ?? false
                    var baseName = itemURL.lastPathComponent
                    if baseName.hasSuffix(".disabled") {
                        baseName = String(baseName.dropLast(".disabled".count))
                    }
                    let ext = (baseName as NSString).pathExtension.lowercased()

                    if isDir && (ext == "framework" || ext == "appex") {
                        if let execURL = LCBoundedFileReader.resolveMachOExecutableURL(for: itemURL) {
                            let key = execURL.standardizedFileURL.path
                            if seenPaths.insert(key).inserted {
                                let rel = itemURL.path.hasPrefix(rootPrefix)
                                    ? String(itemURL.path.dropFirst(rootPrefix.count))
                                    : itemURL.lastPathComponent
                                targets.append(LCMachOTargetItem(
                                    id: "\(ext):\(rel)",
                                    displayName: itemURL.lastPathComponent,
                                    relativePath: rel,
                                    executableURL: execURL,
                                    bundleURL: itemURL,
                                    kind: ext == "framework" ? .framework : .plugin
                                ))
                            }
                        }
                        if ext == "framework" {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    if !isDir && ext == "dylib" && LCBoundedFileReader.isMachOFile(at: itemURL) {
                        let key = itemURL.standardizedFileURL.path
                        if seenPaths.insert(key).inserted {
                            let rel = itemURL.path.hasPrefix(rootPrefix)
                                ? String(itemURL.path.dropFirst(rootPrefix.count))
                                : itemURL.lastPathComponent
                            targets.append(LCMachOTargetItem(
                                id: "dylib:\(rel)",
                                displayName: itemURL.lastPathComponent,
                                relativePath: rel,
                                executableURL: itemURL,
                                bundleURL: bundleURL,
                                kind: .dylib
                            ))
                        }
                    }
                }
            }

            return targets
        }
        return result ?? []
    }

    // MARK: - Top-Level Entry Point

    /// Parses a Mach-O binary overview, segments, load commands, dependencies,
    /// code signature, entitlements, and LiveContainer compatibility checks.
    static func parseSliceContext(
        at url: URL,
        sliceIndex: Int? = nil,
        bundleRootURL: URL? = nil,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) throws -> LCMachOParsedSliceContext {
        let scopeRoot = rootURL ?? url
        return try LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: url)
            let slices = try enumerateSlices(reader: reader)
            guard !slices.isEmpty else {
                throw LCMachOInspectorError.notMachOFile
            }

            let chosenSlice: LCMachOArchitectureSlice
            if let sliceIndex {
                guard sliceIndex >= 0 && sliceIndex < slices.count else {
                    throw LCMachOInspectorError.invalidSliceIndex(sliceIndex)
                }
                chosenSlice = slices[sliceIndex]
            } else {
                // Prefer arm64, then arm64e, then any 64-bit slice, else first slice
                chosenSlice = slices.first(where: { $0.architectureName == "arm64" })
                    ?? slices.first(where: { $0.architectureName == "arm64e" })
                    ?? slices.first(where: { $0.is64Bit })
                    ?? slices[0]
            }

            return try parseSingleSlice(
                reader: reader,
                allSlices: slices,
                slice: chosenSlice,
                bundleRootURL: bundleRootURL,
                needsSecurityScope: needsSecurityScope
            )
        }
    }

    // MARK: - Fat & Thin Slice Enumeration

    static func enumerateSlices(reader: LCBoundedFileReader) throws -> [LCMachOArchitectureSlice] {
        guard reader.fileSize >= 4 else {
            throw LCMachOInspectorError.truncatedHeader(expected: 4, available: reader.fileSize)
        }
        let magicLE = try reader.readUInt32(offset: 0, bigEndian: false)

        switch magicLE {
        case 0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe:
            let is64 = (magicLE == 0xfeedfacf || magicLE == 0xcffaedfe)
            let swapped = (magicLE == 0xcefaedfe || magicLE == 0xcffaedfe)
            let headerSize: UInt64 = is64 ? 32 : 28
            guard reader.fileSize >= headerSize else {
                throw LCMachOInspectorError.truncatedHeader(expected: Int(headerSize), available: reader.fileSize)
            }
            let cpuType = try reader.readUInt32(offset: 4, bigEndian: swapped)
            let cpuSubtype = try reader.readUInt32(offset: 8, bigEndian: swapped)
            return [LCMachOArchitectureSlice(
                index: 0,
                cpuType: cpuType,
                cpuSubtype: cpuSubtype,
                architectureName: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
                fileOffset: 0,
                size: reader.fileSize,
                is64Bit: is64,
                isByteSwapped: swapped
            )]

        case 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca:
            let isFat64 = (magicLE == 0xcafebabf || magicLE == 0xbfbafeca)
            let fatBigEndian = (magicLE == 0xbebafeca || magicLE == 0xbfbafeca)
            guard reader.fileSize >= 8 else {
                throw LCMachOInspectorError.truncatedHeader(expected: 8, available: reader.fileSize)
            }
            let archCount = try reader.readUInt32(offset: 4, bigEndian: fatBigEndian)
            guard archCount >= 1 && archCount <= maxFatSlices else {
                throw LCMachOInspectorError.notMachOFile
            }
            let entrySize: UInt64 = isFat64 ? 32 : 20
            let tableEnd = 8 + UInt64(archCount) * entrySize
            guard tableEnd <= reader.fileSize else {
                throw LCMachOInspectorError.truncatedHeader(expected: Int(min(tableEnd, UInt64(Int.max))), available: reader.fileSize)
            }

            var slices: [LCMachOArchitectureSlice] = []
            for idx in 0..<Int(archCount) {
                let base = 8 + UInt64(idx) * entrySize
                let cpuType = try reader.readUInt32(offset: base, bigEndian: fatBigEndian)
                let cpuSubtype = try reader.readUInt32(offset: base + 4, bigEndian: fatBigEndian)
                let sliceOffset: UInt64
                let sliceSize: UInt64
                if isFat64 {
                    sliceOffset = try reader.readUInt64(offset: base + 8, bigEndian: fatBigEndian)
                    sliceSize = try reader.readUInt64(offset: base + 16, bigEndian: fatBigEndian)
                } else {
                    sliceOffset = UInt64(try reader.readUInt32(offset: base + 8, bigEndian: fatBigEndian))
                    sliceSize = UInt64(try reader.readUInt32(offset: base + 12, bigEndian: fatBigEndian))
                }
                let (sliceEnd, ov) = sliceOffset.addingReportingOverflow(sliceSize)
                guard !ov, sliceSize >= 28, sliceEnd <= reader.fileSize else { continue }
                let sliceMagic = try reader.readUInt32(offset: sliceOffset, bigEndian: false)
                guard sliceMagic == 0xfeedface || sliceMagic == 0xcefaedfe
                        || sliceMagic == 0xfeedfacf || sliceMagic == 0xcffaedfe else {
                    continue
                }
                let is64 = (sliceMagic == 0xfeedfacf || sliceMagic == 0xcffaedfe)
                let isSwapped = (sliceMagic == 0xcefaedfe || sliceMagic == 0xcffaedfe)
                slices.append(LCMachOArchitectureSlice(
                    index: slices.count,
                    cpuType: cpuType,
                    cpuSubtype: cpuSubtype,
                    architectureName: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
                    fileOffset: sliceOffset,
                    size: sliceSize,
                    is64Bit: is64,
                    isByteSwapped: isSwapped
                ))
            }
            return slices

        default:
            throw LCMachOInspectorError.notMachOFile
        }
    }

    // MARK: - Single Slice Parsing

    private static func parseSingleSlice(
        reader: LCBoundedFileReader,
        allSlices: [LCMachOArchitectureSlice],
        slice: LCMachOArchitectureSlice,
        bundleRootURL: URL?,
        needsSecurityScope: Bool
    ) throws -> LCMachOParsedSliceContext {
        let headerSize: UInt64 = slice.is64Bit ? 32 : 28
        guard slice.size >= headerSize else {
            throw LCMachOInspectorError.truncatedHeader(expected: Int(headerSize), available: slice.size)
        }

        let swapped = slice.isByteSwapped
        let base = slice.fileOffset
        let magic = try reader.readUInt32(offset: base, bigEndian: false)
        let cpuType = try reader.readUInt32(offset: base + 4, bigEndian: swapped)
        let cpuSubtype = try reader.readUInt32(offset: base + 8, bigEndian: swapped)
        let fileType = try reader.readUInt32(offset: base + 12, bigEndian: swapped)
        let ncmds = try reader.readUInt32(offset: base + 16, bigEndian: swapped)
        let sizeofcmds = try reader.readUInt32(offset: base + 20, bigEndian: swapped)
        let flags = try reader.readUInt32(offset: base + 24, bigEndian: swapped)

        var diagnostics: [String] = []
        let loadCmdsStart = headerSize
        let availableForCmds = slice.size - loadCmdsStart
        let effectiveCmdBytes = min(UInt64(sizeofcmds), availableForCmds)
        if UInt64(sizeofcmds) > availableForCmds {
            diagnostics.append("Header sizeofcmds (\(sizeofcmds)) exceeds slice size; clamped safely to \(availableForCmds) bytes.")
        }
        if ncmds > maxLoadCommands {
            diagnostics.append("Binary declares \(ncmds) load commands; capped safely to \(maxLoadCommands).")
        }

        let cmdData = try reader.readData(
            offset: base + loadCmdsStart,
            count: Int(min(effectiveCmdBytes, UInt64(LCBoundedFileReader.maxSingleReadBytes)))
        )

        var segments: [LCMachOSegmentInfo] = []
        var loadCommands: [LCMachOLoadCommandInfo] = []
        var dylibs: [LCMachODylibDependency] = []
        var rpaths: [String] = []

        var uuidString: String?
        var platformName: String?
        var minOSVersion: String?
        var sdkVersion: String?
        var sourceVersion: String?
        var entryPointOffset: UInt64?
        var cryptID: UInt32 = 0
        var hasChainedFixups = false
        var hasExportsTrie = false
        var hasCodeSignature = false
        var hasDisabledTweakLoaderMarker = false

        var codeSigDataOffset: UInt64?
        var codeSigDataSize: UInt64?
        var chainedFixupsOffset: UInt64?
        var chainedFixupsSize: UInt64?
        var symtabOffset: UInt64?
        var symtabCount: UInt32 = 0
        var strtabOffset: UInt64?
        var strtabSize: UInt32 = 0
        var exportsTrieOffset: UInt64?
        var exportsTrieSize: UInt32 = 0

        var cursor = 0
        let maxCount = Int(min(ncmds, maxLoadCommands))

        for cmdIndex in 0..<maxCount {
            if Task.isCancelled { break }
            guard cursor + 8 <= cmdData.count else {
                diagnostics.append("Load command stream ended early at command #\(cmdIndex).")
                break
            }
            let rawCmd = readU32(cmdData, at: cursor, bigEndian: swapped)
            let rawCmdSize = readU32(cmdData, at: cursor + 4, bigEndian: swapped)

            guard rawCmdSize >= 8, rawCmdSize % 4 == 0 else {
                diagnostics.append("Stopped load command walk at #\(cmdIndex): invalid cmdsize \(rawCmdSize).")
                break
            }
            let cmdSizeInt = Int(rawCmdSize)
            guard cursor + cmdSizeInt <= cmdData.count else {
                diagnostics.append("Stopped load command walk at #\(cmdIndex): command exceeds sizeofcmds.")
                break
            }

            let cmdSlice = Data(cmdData[cursor..<(cursor + cmdSizeInt)])
            let cmdFileOffset = base + loadCmdsStart + UInt64(cursor)
            var summary = ""

            switch rawCmd {
            case UInt32(LC_SEGMENT_64):
                if let seg = parseSegment64(cmdSlice, bigEndian: swapped) {
                    segments.append(seg)
                    summary = "\(seg.name) (\(seg.protectionString), \(seg.sections.count) sections)"
                }

            case UInt32(LC_SEGMENT):
                if let seg = parseSegment32(cmdSlice, bigEndian: swapped) {
                    segments.append(seg)
                    summary = "\(seg.name) (\(seg.protectionString), \(seg.sections.count) sections)"
                }

            case UInt32(LC_LOAD_DYLIB), UInt32(LC_LOAD_WEAK_DYLIB), UInt32(LC_REEXPORT_DYLIB),
                 UInt32(LC_LOAD_UPWARD_DYLIB), UInt32(LC_LAZY_LOAD_DYLIB), UInt32(LC_ID_DYLIB):
                if cmdSlice.count >= 24 {
                    let strOffset = Int(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let curVer = formatPackedVersion(readU32(cmdSlice, at: 16, bigEndian: swapped))
                    let compatVer = formatPackedVersion(readU32(cmdSlice, at: 20, bigEndian: swapped))
                    let path = strOffset < cmdSlice.count ? cmdSlice.lcReadCString(at: strOffset, maxLength: cmdSlice.count - strOffset) : ""
                    let kind = dylibKind(for: rawCmd)
                    dylibs.append(LCMachODylibDependency(
                        index: dylibs.count,
                        path: path,
                        kind: kind,
                        currentVersion: curVer,
                        compatibilityVersion: compatVer,
                        statusNote: nil,
                        isPotentiallyBroken: false
                    ))
                    summary = path
                }

            case UInt32(LC_RPATH):
                if cmdSlice.count >= 12 {
                    let strOffset = Int(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    if strOffset < cmdSlice.count {
                        let path = cmdSlice.lcReadCString(at: strOffset, maxLength: cmdSlice.count - strOffset)
                        rpaths.append(path)
                        summary = path
                    }
                }

            case UInt32(LC_UUID):
                if cmdSlice.count >= 24 {
                    let bytes = Array(cmdSlice[8..<24])
                    let uuid = UUID(uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3],
                        bytes[4], bytes[5], bytes[6], bytes[7],
                        bytes[8], bytes[9], bytes[10], bytes[11],
                        bytes[12], bytes[13], bytes[14], bytes[15]
                    ))
                    uuidString = uuid.uuidString
                    summary = uuid.uuidString
                }

            case UInt32(LC_BUILD_VERSION):
                if cmdSlice.count >= 24 {
                    let platform = readU32(cmdSlice, at: 8, bigEndian: swapped)
                    let minos = readU32(cmdSlice, at: 12, bigEndian: swapped)
                    let sdk = readU32(cmdSlice, at: 16, bigEndian: swapped)
                    platformName = platformDisplayName(platform)
                    minOSVersion = formatPackedVersion(minos)
                    sdkVersion = formatPackedVersion(sdk)
                    summary = "\(platformName ?? "Platform \(platform)") minOS \(minOSVersion ?? "?") SDK \(sdkVersion ?? "?")"
                }

            case UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_MACOSX),
                 UInt32(LC_VERSION_MIN_TVOS), UInt32(LC_VERSION_MIN_WATCHOS):
                if cmdSlice.count >= 16 {
                    let minVer = formatPackedVersion(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let sdkVer = formatPackedVersion(readU32(cmdSlice, at: 12, bigEndian: swapped))
                    if platformName == nil {
                        platformName = legacyPlatformName(for: rawCmd)
                    }
                    if minOSVersion == nil { minOSVersion = minVer }
                    if sdkVersion == nil { sdkVersion = sdkVer }
                    summary = "minOS \(minVer), SDK \(sdkVer)"
                }

            case UInt32(LC_SOURCE_VERSION):
                if cmdSlice.count >= 16 {
                    let raw = readU64(cmdSlice, at: 8, bigEndian: swapped)
                    let a = (raw >> 40) & 0xFFFFFF
                    let b = (raw >> 30) & 0x3FF
                    let c = (raw >> 20) & 0x3FF
                    let d = (raw >> 10) & 0x3FF
                    let e = raw & 0x3FF
                    let formatted = "\(a).\(b).\(c).\(d).\(e)"
                    sourceVersion = formatted
                    summary = formatted
                }

            case UInt32(LC_MAIN):
                if cmdSlice.count >= 16 {
                    let entryOff = readU64(cmdSlice, at: 8, bigEndian: swapped)
                    entryPointOffset = entryOff
                    summary = String(format: "entryoff 0x%llX", entryOff)
                }

            case UInt32(LC_ENCRYPTION_INFO), UInt32(LC_ENCRYPTION_INFO_64):
                if cmdSlice.count >= 20 {
                    let cid = readU32(cmdSlice, at: 16, bigEndian: swapped)
                    cryptID = cid
                    summary = cid == 0 ? "Decrypted (cryptid = 0)" : "Encrypted (cryptid = \(cid))"
                }

            case UInt32(LC_CODE_SIGNATURE):
                if cmdSlice.count >= 16 {
                    let off = UInt64(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let sz = UInt64(readU32(cmdSlice, at: 12, bigEndian: swapped))
                    hasCodeSignature = sz > 0
                    codeSigDataOffset = off
                    codeSigDataSize = sz
                    summary = String(format: "offset 0x%llX, %llu B", off, sz)
                }

            case UInt32(LC_DYLD_CHAINED_FIXUPS):
                if cmdSlice.count >= 16 {
                    let off = UInt64(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let sz = UInt64(readU32(cmdSlice, at: 12, bigEndian: swapped))
                    hasChainedFixups = sz > 0
                    chainedFixupsOffset = off
                    chainedFixupsSize = sz
                    summary = String(format: "offset 0x%llX, %llu B", off, sz)
                }

            case UInt32(LC_DYLD_EXPORTS_TRIE):
                if cmdSlice.count >= 16 {
                    let off = UInt64(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let sz = readU32(cmdSlice, at: 12, bigEndian: swapped)
                    hasExportsTrie = sz > 0
                    exportsTrieOffset = off
                    exportsTrieSize = sz
                    summary = String(format: "offset 0x%llX, %u B", off, sz)
                }

            case UInt32(LC_DYLD_INFO), UInt32(LC_DYLD_INFO_ONLY):
                if cmdSlice.count >= 48 {
                    let expOff = UInt64(readU32(cmdSlice, at: 40, bigEndian: swapped))
                    let expSz = readU32(cmdSlice, at: 44, bigEndian: swapped)
                    if exportsTrieOffset == nil && expSz > 0 {
                        exportsTrieOffset = expOff
                        exportsTrieSize = expSz
                        hasExportsTrie = true
                    }
                    summary = String(format: "export_off 0x%llX (%u B)", expOff, expSz)
                }

            case UInt32(LC_SYMTAB):
                if cmdSlice.count >= 24 {
                    let symOff = UInt64(readU32(cmdSlice, at: 8, bigEndian: swapped))
                    let nsyms = readU32(cmdSlice, at: 12, bigEndian: swapped)
                    let strOff = UInt64(readU32(cmdSlice, at: 16, bigEndian: swapped))
                    let strSz = readU32(cmdSlice, at: 20, bigEndian: swapped)
                    symtabOffset = symOff
                    symtabCount = nsyms
                    strtabOffset = strOff
                    strtabSize = strSz
                    summary = "\(nsyms) symbols, strtab \(strSz) B"
                }

            case lcDisabledTweakLoaderCmd:
                hasDisabledTweakLoaderMarker = true
                summary = "Disabled TweakLoader load command marker"

            default:
                summary = "\(rawCmdSize) B"
            }

            loadCommands.append(LCMachOLoadCommandInfo(
                index: cmdIndex,
                cmd: rawCmd,
                name: loadCommandName(rawCmd),
                cmdSize: rawCmdSize,
                fileOffset: cmdFileOffset,
                summary: summary
            ))

            cursor += cmdSizeInt
        }

        // Build VM map & Chained Fixups decoder
        let vmMap = LCMachOVMMap(sliceOffset: slice.fileOffset, sliceSize: slice.size, segments: segments)
        let fixupsDecoder: LCMachOChainedFixupsDecoder
        if let fOff = chainedFixupsOffset, let fSize = chainedFixupsSize, fSize > 0 {
            fixupsDecoder = LCMachOChainedFixupsDecoder(
                reader: reader,
                vmMap: vmMap,
                fixupsDataOffset: fOff,
                fixupsDataSize: fSize
            )
            diagnostics.append(contentsOf: fixupsDecoder.diagnostics)
        } else {
            fixupsDecoder = LCMachOChainedFixupsDecoder(vmMap: vmMap)
        }

        // Parse LC_CODE_SIGNATURE (SuperBlob, CodeDirectory, XML/DER Entitlements)
        let codeSign: LCMachOCodeSignInfo
        if let csOff = codeSigDataOffset, let csSz = codeSigDataSize, csSz > 0 {
            codeSign = parseCodeSignature(
                reader: reader,
                sliceOffset: slice.fileOffset,
                sliceSize: slice.size,
                relativeOffset: csOff,
                size: csSz,
                binaryURL: reader.url,
                probeKernelSignature: !needsSecurityScope && (slice.architectureName == "arm64" || slice.architectureName == "arm64e"),
                diagnostics: &diagnostics
            )
        } else {
            codeSign = .unsigned
        }

        // Inspect security flags & ObjC/Swift metadata presence
        let hasObjCMetadata = !vmMap.sections(named: "__objc_classlist").isEmpty
            || !vmMap.sections(named: "__objc_protolist").isEmpty
            || !vmMap.sections(named: "__objc_catlist").isEmpty
        let hasSwiftMetadata = !vmMap.sections(named: "__swift5_types").isEmpty
            || !vmMap.sections(named: "__swift5_proto").isEmpty
        let isRestricted = segments.contains(where: { $0.name == "__RESTRICT" })
            || segments.flatMap(\.sections).contains(where: { $0.sectionName == "__restrict" })

        let (usesARC, hasStackCanary) = probeHardeningSymbols(
            reader: reader,
            sliceOffset: slice.fileOffset,
            sliceSize: slice.size,
            strtabOffset: strtabOffset,
            strtabSize: strtabSize,
            importedSymbols: fixupsDecoder.importedSymbols
        )

        // Annotate linked dylibs with LiveContainer resolution health
        let annotatedDylibs = evaluateDylibDependencies(
            dylibs: dylibs,
            rpaths: rpaths,
            binaryURL: reader.url,
            bundleRootURL: bundleRootURL
        )

        let header = LCMachOHeaderInfo(
            magic: magic,
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            architectureName: slice.architectureName,
            fileType: fileType,
            fileTypeName: fileTypeName(fileType),
            numberOfCommands: ncmds,
            sizeOfCommands: sizeofcmds,
            flags: flags,
            flagNames: headerFlagNames(flags),
            is64Bit: slice.is64Bit,
            isPIE: (flags & UInt32(MH_PIE)) != 0,
            isEncrypted: cryptID != 0,
            cryptID: cryptID,
            uuid: uuidString,
            platformName: platformName,
            minOSVersion: minOSVersion,
            sdkVersion: sdkVersion,
            sourceVersion: sourceVersion,
            entryPointOffset: entryPointOffset,
            hasChainedFixups: hasChainedFixups,
            hasExportsTrie: hasExportsTrie,
            hasCodeSignature: hasCodeSignature,
            hasObjCMetadata: hasObjCMetadata,
            hasSwiftMetadata: hasSwiftMetadata,
            usesARC: usesARC,
            hasStackCanary: hasStackCanary,
            isRestricted: isRestricted,
            hasDisabledTweakLoaderMarker: hasDisabledTweakLoaderMarker
        )

        let findings = runCompatibilityDoctor(
            header: header,
            dylibs: annotatedDylibs,
            codeSign: codeSign
        )

        let overview = LCMachOOverviewResult(
            fileURL: reader.url,
            fileName: reader.url.lastPathComponent,
            fileSize: reader.fileSize,
            slices: allSlices,
            selectedSlice: slice,
            header: header,
            segments: segments,
            loadCommands: loadCommands,
            dylibs: annotatedDylibs,
            rpaths: rpaths,
            codeSign: codeSign,
            compatibilityFindings: findings,
            diagnostics: diagnostics
        )

        return LCMachOParsedSliceContext(
            overview: overview,
            vmMap: vmMap,
            chainedFixups: fixupsDecoder,
            symtabOffset: symtabOffset,
            symtabCount: symtabCount,
            strtabOffset: strtabOffset,
            strtabSize: strtabSize,
            exportsTrieOffset: exportsTrieOffset,
            exportsTrieSize: exportsTrieSize
        )
    }

    // MARK: - Segment & Section Parsers

    private static func parseSegment64(_ data: Data, bigEndian: Bool) -> LCMachOSegmentInfo? {
        guard data.count >= 72 else { return nil }
        let name = readFixedString(data, at: 8, maxLen: 16)
        let vmAddr = readU64(data, at: 24, bigEndian: bigEndian)
        let vmSize = readU64(data, at: 32, bigEndian: bigEndian)
        let fileOff = readU64(data, at: 40, bigEndian: bigEndian)
        let fileSize = readU64(data, at: 48, bigEndian: bigEndian)
        let maxProt = readU32(data, at: 56, bigEndian: bigEndian)
        let initProt = readU32(data, at: 60, bigEndian: bigEndian)
        let nsects = min(readU32(data, at: 64, bigEndian: bigEndian), maxSectionsPerSegment)

        var sections: [LCMachOSectionInfo] = []
        sections.reserveCapacity(Int(nsects))
        for i in 0..<Int(nsects) {
            let sOff = 72 + i * 80
            guard sOff + 80 <= data.count else { break }
            let sectName = readFixedString(data, at: sOff, maxLen: 16)
            let segName = readFixedString(data, at: sOff + 16, maxLen: 16)
            let addr = readU64(data, at: sOff + 32, bigEndian: bigEndian)
            let size = readU64(data, at: sOff + 40, bigEndian: bigEndian)
            let offset = UInt64(readU32(data, at: sOff + 48, bigEndian: bigEndian))
            let flags = readU32(data, at: sOff + 64, bigEndian: bigEndian)
            sections.append(LCMachOSectionInfo(
                sectionName: sectName,
                segmentName: segName,
                vmAddress: addr,
                size: size,
                fileOffset: offset,
                flags: flags
            ))
        }

        return LCMachOSegmentInfo(
            name: name,
            vmAddress: vmAddr,
            vmSize: vmSize,
            fileOffset: fileOff,
            fileSize: fileSize,
            maxProtection: maxProt,
            initProtection: initProt,
            protectionString: formatProtection(initProt),
            sections: sections
        )
    }

    private static func parseSegment32(_ data: Data, bigEndian: Bool) -> LCMachOSegmentInfo? {
        guard data.count >= 56 else { return nil }
        let name = readFixedString(data, at: 8, maxLen: 16)
        let vmAddr = UInt64(readU32(data, at: 24, bigEndian: bigEndian))
        let vmSize = UInt64(readU32(data, at: 28, bigEndian: bigEndian))
        let fileOff = UInt64(readU32(data, at: 32, bigEndian: bigEndian))
        let fileSize = UInt64(readU32(data, at: 36, bigEndian: bigEndian))
        let maxProt = readU32(data, at: 40, bigEndian: bigEndian)
        let initProt = readU32(data, at: 44, bigEndian: bigEndian)
        let nsects = min(readU32(data, at: 48, bigEndian: bigEndian), maxSectionsPerSegment)

        var sections: [LCMachOSectionInfo] = []
        sections.reserveCapacity(Int(nsects))
        for i in 0..<Int(nsects) {
            let sOff = 56 + i * 68
            guard sOff + 68 <= data.count else { break }
            let sectName = readFixedString(data, at: sOff, maxLen: 16)
            let segName = readFixedString(data, at: sOff + 16, maxLen: 16)
            let addr = UInt64(readU32(data, at: sOff + 32, bigEndian: bigEndian))
            let size = UInt64(readU32(data, at: sOff + 36, bigEndian: bigEndian))
            let offset = UInt64(readU32(data, at: sOff + 40, bigEndian: bigEndian))
            let flags = readU32(data, at: sOff + 56, bigEndian: bigEndian)
            sections.append(LCMachOSectionInfo(
                sectionName: sectName,
                segmentName: segName,
                vmAddress: addr,
                size: size,
                fileOffset: offset,
                flags: flags
            ))
        }

        return LCMachOSegmentInfo(
            name: name,
            vmAddress: vmAddr,
            vmSize: vmSize,
            fileOffset: fileOff,
            fileSize: fileSize,
            maxProtection: maxProt,
            initProtection: initProt,
            protectionString: formatProtection(initProt),
            sections: sections
        )
    }

    // MARK: - Code Signature & Entitlements Parser

    private static let csSlotAlternateCodeDirectoryBase: UInt32 = 0x1000
    private static let csSlotAlternateCodeDirectoryMax: UInt32 = 0x1005

    private static func parseCodeSignature(
        reader: LCBoundedFileReader,
        sliceOffset: UInt64,
        sliceSize: UInt64,
        relativeOffset: UInt64,
        size: UInt64,
        binaryURL: URL,
        probeKernelSignature: Bool,
        diagnostics: inout [String]
    ) -> LCMachOCodeSignInfo {
        guard size >= 12, size <= UInt64(LCBoundedFileReader.maxSingleReadBytes),
              let data = try? reader.readSliceData(
                  sliceOffset: sliceOffset,
                  sliceSize: sliceSize,
                  relativeOffset: relativeOffset,
                  count: Int(size)
              ) else {
            diagnostics.append("LC_CODE_SIGNATURE blob exceeds slice bounds or safe read cap.")
            return .unsigned
        }

        let superMagic = readU32(data, at: 0, bigEndian: true)
        guard superMagic == csMagicEmbeddedSignature else {
            return .unsigned
        }
        let blobCount = min(Int(readU32(data, at: 8, bigEndian: true)), 64)

        var identifier: String?
        var teamIdentifier: String?
        var cdHashHex: String?
        var hashTypeName: String?
        var selectedHashRank: UInt8 = 0
        var csFlags: UInt32 = 0
        var entitlementsXML: String?
        var entitlementsSummary: [(key: String, value: String)] = []
        var hasDER = false
        var derSize = 0
        var hasCMS = false
        var cmsSize = 0

        for idx in 0..<blobCount {
            let indexPos = 12 + idx * 8
            guard indexPos + 8 <= data.count else { break }
            let slotType = readU32(data, at: indexPos, bigEndian: true)
            let blobOffset = Int(readU32(data, at: indexPos + 4, bigEndian: true))
            guard blobOffset >= 12, blobOffset + 8 <= data.count else { continue }

            let blobMagic = readU32(data, at: blobOffset, bigEndian: true)
            let blobLen = Int(readU32(data, at: blobOffset + 4, bigEndian: true))
            guard blobLen >= 8, blobOffset + blobLen <= data.count else { continue }

            let isCodeDirSlot = slotType == csSlotCodeDirectory
                || (slotType >= csSlotAlternateCodeDirectoryBase && slotType < csSlotAlternateCodeDirectoryMax)

            if isCodeDirSlot && blobMagic == csMagicCodeDirectory && blobLen >= 44 {
                let version = readU32(data, at: blobOffset + 8, bigEndian: true)
                let flags = readU32(data, at: blobOffset + 12, bigEndian: true)
                let identOffset = Int(readU32(data, at: blobOffset + 20, bigEndian: true))
                let hashType = data[blobOffset + 37]
                // Prefer SHA-256 / SHA-384 alternate CodeDirectory over SHA-1 primary
                let hashRank: UInt8 = (hashType == 2 || hashType == 3) ? 3 : (hashType == 4 ? 4 : 1)
                if hashRank >= selectedHashRank {
                    selectedHashRank = hashRank
                    csFlags = flags
                    hashTypeName = codeSignHashName(hashType)

                    if identOffset > 0 && blobOffset + identOffset < blobOffset + blobLen {
                        identifier = data.lcReadCString(at: blobOffset + identOffset, maxLength: blobLen - identOffset)
                    }
                    if version >= 0x20200, blobLen >= 52 {
                        let teamOffset = Int(readU32(data, at: blobOffset + 48, bigEndian: true))
                        if teamOffset > 0 && blobOffset + teamOffset < blobOffset + blobLen {
                            let rawTeam = data.lcReadCString(at: blobOffset + teamOffset, maxLength: blobLen - teamOffset)
                            if !rawTeam.isEmpty { teamIdentifier = rawTeam }
                        }
                    }
                    let cdSlice = data[blobOffset..<(blobOffset + blobLen)]
                    switch hashType {
                    case 1:
                        cdHashHex = Insecure.SHA1.hash(data: cdSlice).map { String(format: "%02x", $0) }.joined()
                    case 4:
                        cdHashHex = SHA384.hash(data: cdSlice).prefix(20).map { String(format: "%02x", $0) }.joined()
                    default:
                        cdHashHex = SHA256.hash(data: cdSlice).prefix(20).map { String(format: "%02x", $0) }.joined()
                    }
                }
            } else if slotType == csSlotEntitlements && blobMagic == csMagicEntitlements && blobLen > 8 {
                let xmlData = Data(data[(blobOffset + 8)..<(blobOffset + blobLen)])
                entitlementsXML = String(data: xmlData, encoding: .utf8)
                if let plist = try? PropertyListSerialization.propertyList(from: xmlData, format: nil) as? [String: Any] {
                    entitlementsSummary = plist.keys.sorted().map { key in
                        (key: key, value: summarizeEntitlementValue(plist[key]))
                    }
                }
            } else if slotType == csSlotDEREntitlements && blobMagic == csMagicDEREntitlements && blobLen > 8 {
                hasDER = true
                derSize = blobLen - 8
            } else if slotType == csSlotSignature && blobMagic == csMagicBlobWrapper {
                cmsSize = max(0, blobLen - 8)
                hasCMS = cmsSize > 0
            }
        }

        let isAdHoc = (csFlags & 0x0002) != 0
        let kernelValid: Bool?
        if probeKernelSignature {
            kernelValid = binaryURL.path.withCString { checkCodeSignature($0) }
        } else {
            kernelValid = nil
        }

        return LCMachOCodeSignInfo(
            isSigned: identifier != nil || hasCMS || isAdHoc,
            isAdHoc: isAdHoc,
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            cdHashHex: cdHashHex,
            hashTypeName: hashTypeName,
            flags: csFlags,
            flagNames: codeSignFlagNames(csFlags),
            entitlementsXML: entitlementsXML,
            entitlementsSummary: entitlementsSummary,
            hasDEREntitlements: hasDER,
            derEntitlementsSize: derSize,
            hasCMSSignature: hasCMS,
            cmsSignatureSize: cmsSize,
            kernelSignatureValid: kernelValid
        )
    }

    // MARK: - Hardening Probe & Compatibility Doctor

    private static func probeHardeningSymbols(
        reader: LCBoundedFileReader,
        sliceOffset: UInt64,
        sliceSize: UInt64,
        strtabOffset: UInt64?,
        strtabSize: UInt32,
        importedSymbols: [String]
    ) -> (usesARC: Bool, hasStackCanary: Bool) {
        var usesARC = importedSymbols.contains { $0 == "_objc_release" || $0 == "_objc_retain" || $0 == "_objc_storeStrong" }
        var hasCanary = importedSymbols.contains { $0 == "___stack_chk_fail" || $0 == "___stack_chk_guard" }
        if usesARC && hasCanary {
            return (true, true)
        }
        guard let strtabOffset, strtabSize > 0, strtabOffset < sliceSize else {
            return (usesARC, hasCanary)
        }
        let availableInSlice = sliceSize - strtabOffset
        let readLen = Int(min(UInt64(strtabSize), min(availableInSlice, 4 * 1024 * 1024)))
        guard let data = try? reader.readSliceData(
            sliceOffset: sliceOffset,
            sliceSize: sliceSize,
            relativeOffset: strtabOffset,
            count: readLen
        ) else {
            return (usesARC, hasCanary)
        }
        if !usesARC {
            usesARC = data.range(of: Data("_objc_release".utf8)) != nil
        }
        if !hasCanary {
            hasCanary = data.range(of: Data("___stack_chk_fail".utf8)) != nil
        }
        return (usesARC, hasCanary)
    }

    private static func evaluateDylibDependencies(
        dylibs: [LCMachODylibDependency],
        rpaths: [String],
        binaryURL: URL,
        bundleRootURL: URL?
    ) -> [LCMachODylibDependency] {
        let fm = FileManager.default
        let binaryDir = binaryURL.deletingLastPathComponent()

        return dylibs.map { dep in
            guard dep.kind != .id else { return dep }
            let path = dep.path

            // Detect jailbreak-only paths or tweak substrate dependencies
            if path.hasPrefix("/var/jb/") || path.hasPrefix("/Library/MobileSubstrate/")
                || path.contains("CydiaSubstrate") || path.contains("libellekit") || path.contains("libhooker") {
                return LCMachODylibDependency(
                    index: dep.index,
                    path: path,
                    kind: dep.kind,
                    currentVersion: dep.currentVersion,
                    compatibilityVersion: dep.compatibilityVersion,
                    statusNote: "Jailbreak substrate path — LiveContainer redirects CydiaSubstrate/ElleKit via TweakLoader if supported; otherwise may fail to load.",
                    isPotentiallyBroken: true
                )
            }

            // Skip Apple system frameworks, usr libraries, and iOS dyld-shared-cache Swift stdlib shims
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") || path.hasPrefix("@rpath/libswift") {
                return dep
            }

            // Check embedded bundle references when bundleRootURL is available
            if let bundleRootURL {
                let resolvedCandidates: [URL]
                if path.hasPrefix("@executable_path/") {
                    let tail = String(path.dropFirst("@executable_path/".count))
                    resolvedCandidates = [bundleRootURL.appendingPathComponent(tail)]
                } else if path.hasPrefix("@loader_path/") {
                    let tail = String(path.dropFirst("@loader_path/".count))
                    resolvedCandidates = [binaryDir.appendingPathComponent(tail)]
                } else if path.hasPrefix("@rpath/") {
                    let tail = String(path.dropFirst("@rpath/".count))
                    var candidates: [URL] = [
                        bundleRootURL.appendingPathComponent("Frameworks").appendingPathComponent(tail),
                        binaryDir.appendingPathComponent("Frameworks").appendingPathComponent(tail),
                        binaryDir.appendingPathComponent(tail),
                    ]
                    for rp in rpaths {
                        if rp == "@executable_path" {
                            candidates.append(bundleRootURL.appendingPathComponent(tail))
                        } else if rp.hasPrefix("@executable_path/") {
                            let rpTail = String(rp.dropFirst("@executable_path/".count))
                            candidates.append(bundleRootURL.appendingPathComponent(rpTail).appendingPathComponent(tail))
                        } else if rp == "@loader_path" {
                            candidates.append(binaryDir.appendingPathComponent(tail))
                        } else if rp.hasPrefix("@loader_path/") {
                            let rpTail = String(rp.dropFirst("@loader_path/".count))
                            candidates.append(binaryDir.appendingPathComponent(rpTail).appendingPathComponent(tail))
                        }
                    }
                    resolvedCandidates = candidates
                } else {
                    resolvedCandidates = []
                }

                if !resolvedCandidates.isEmpty {
                    let exists = resolvedCandidates.contains { fm.fileExists(atPath: $0.standardizedFileURL.path) }
                    if !exists {
                        let isWeak = dep.kind == .weak
                        return LCMachODylibDependency(
                            index: dep.index,
                            path: path,
                            kind: dep.kind,
                            currentVersion: dep.currentVersion,
                            compatibilityVersion: dep.compatibilityVersion,
                            statusNote: isWeak ? "Weak dependency not present in bundle." : "Missing from app bundle — may crash dyld at launch.",
                            isPotentiallyBroken: !isWeak
                        )
                    }
                }
            }

            return dep
        }
    }

    private static func runCompatibilityDoctor(
        header: LCMachOHeaderInfo,
        dylibs: [LCMachODylibDependency],
        codeSign: LCMachOCodeSignInfo
    ) -> [LCMachOCompatibilityFinding] {
        var findings: [LCMachOCompatibilityFinding] = []

        // 1. FairPlay encryption
        if header.isEncrypted {
            findings.append(LCMachOCompatibilityFinding(
                id: "encryption",
                severity: .error,
                title: "FairPlay Encrypted (cryptid = \(header.cryptID))",
                detail: "Encrypted App Store binaries cannot be loaded by LiveContainer or have their metadata decoded."
            ))
        } else {
            findings.append(LCMachOCompatibilityFinding(
                id: "encryption",
                severity: .ok,
                title: "Unencrypted Binary",
                detail: "Mach-O pages are decrypted (cryptid = 0) and ready for guest loading and inspection."
            ))
        }

        // 2. Architecture
        if header.architectureName == "arm64" {
            findings.append(LCMachOCompatibilityFinding(
                id: "arch",
                severity: .ok,
                title: "Native arm64 Architecture",
                detail: "Standard iOS arm64 ABI — fully compatible with LiveContainer's dyld guest loader."
            ))
        } else if header.architectureName == "arm64e" {
            findings.append(LCMachOCompatibilityFinding(
                id: "arch",
                severity: .warning,
                title: "arm64e Pointer-Auth ABI",
                detail: "arm64e binaries require PAC-compatible signing/ABI alignment and may fail on non-arm64e setups."
            ))
        } else if !header.is64Bit {
            findings.append(LCMachOCompatibilityFinding(
                id: "arch",
                severity: .warning,
                title: "32-Bit Architecture (\(header.architectureName))",
                detail: "Requires a configured 32-bit emulator app in LiveContainer App Settings."
            ))
        } else {
            findings.append(LCMachOCompatibilityFinding(
                id: "arch",
                severity: .warning,
                title: "Non-iOS Architecture (\(header.architectureName))",
                detail: "This slice targets \(header.architectureName) rather than arm64."
            ))
        }

        // 3. Mach-O file type & LiveContainer patch status
        if header.fileType == UInt32(MH_EXECUTE) {
            findings.append(LCMachOCompatibilityFinding(
                id: "filetype",
                severity: .warning,
                title: "Unpatched MH_EXECUTE Binary",
                detail: "LiveContainer patches guest executables to MH_DYLIB at launch/install time so dlopen() can load them."
            ))
        } else if header.fileType == UInt32(MH_DYLIB) {
            findings.append(LCMachOCompatibilityFinding(
                id: "filetype",
                severity: .ok,
                title: "MH_DYLIB Loadable Image",
                detail: "Binary is structured as a dynamic library (or LiveContainer-patched guest executable)."
            ))
        }

        // 4. TweakLoader status
        let hasTweakLoader = dylibs.contains { $0.path.localizedCaseInsensitiveContains("TweakLoader") }
        if hasTweakLoader {
            findings.append(LCMachOCompatibilityFinding(
                id: "tweakloader",
                severity: .ok,
                title: "TweakLoader Linked",
                detail: "TweakLoader.dylib is linked into this binary for tweak injection, spoof profiles, and live debugging."
            ))
        } else if header.hasDisabledTweakLoaderMarker {
            findings.append(LCMachOCompatibilityFinding(
                id: "tweakloader",
                severity: .warning,
                title: "TweakLoader Injection Disabled",
                detail: "Detected LiveContainer disabled-TweakLoader marker (0x114514). Tweaks, spoof profiles, and debug hooks are bypassed."
            ))
        }

        // 5. Broken/jailbreak dylib links
        let broken = dylibs.filter(\.isPotentiallyBroken)
        if !broken.isEmpty {
            let names = broken.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            findings.append(LCMachOCompatibilityFinding(
                id: "dylibs",
                severity: .warning,
                title: "\(broken.count) Dependency Warning\(broken.count == 1 ? "" : "s")",
                detail: "Inspect Linked Dylibs: \(names)\(broken.count > 3 ? "…" : "")."
            ))
        }

        // 6. Code signature
        if !codeSign.isSigned {
            findings.append(LCMachOCompatibilityFinding(
                id: "codesign",
                severity: .warning,
                title: "Unsigned Binary",
                detail: "No LC_CODE_SIGNATURE found. Sign with your certificate or LiveContainer's signer before launching."
            ))
        } else if let valid = codeSign.kernelSignatureValid {
            findings.append(LCMachOCompatibilityFinding(
                id: "codesign",
                severity: valid ? .ok : .warning,
                title: valid ? "Valid Device Code Signature" : "Code Signature Needs Re-signing",
                detail: valid
                    ? "Verified against this device's active signing identity\(codeSign.teamIdentifier.map { " (Team \($0))" } ?? "")."
                    : "Current signature does not match LiveContainer's active certificate. Use Re-sign if launch fails."
            ))
        } else if codeSign.isAdHoc {
            findings.append(LCMachOCompatibilityFinding(
                id: "codesign",
                severity: .warning,
                title: "Ad-Hoc Signed",
                detail: "Contains an ad-hoc code directory without a CMS certificate chain."
            ))
        }

        return findings
    }

    // MARK: - Formatting & Lookup Helpers

    private static func readU32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        let raw = data.lcReadUInt32(at: offset) ?? 0
        return bigEndian ? raw.bigEndian : UInt32(littleEndian: raw)
    }

    private static func readU64(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt64 {
        let raw = data.lcReadUInt64(at: offset) ?? 0
        return bigEndian ? raw.bigEndian : UInt64(littleEndian: raw)
    }

    private static func readFixedString(_ data: Data, at offset: Int, maxLen: Int) -> String {
        guard offset >= 0, offset < data.count, maxLen > 0 else { return "" }
        let safeLen = min(maxLen, data.count - offset)
        let start = data.startIndex + offset
        let slice = data[start..<(start + safeLen)]
        if let zero = slice.firstIndex(of: 0) {
            return String(decoding: slice[..<zero], as: UTF8.self)
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func formatPackedVersion(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFFFF
        let minor = (raw >> 8) & 0xFF
        let patch = raw & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    private static func formatProtection(_ prot: UInt32) -> String {
        let r = (prot & 1) != 0 ? "r" : "-"
        let w = (prot & 2) != 0 ? "w" : "-"
        let x = (prot & 4) != 0 ? "x" : "-"
        return "\(r)\(w)\(x)"
    }

    private static func summarizeEntitlementValue(_ value: Any?) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let s as String:
            return s
        case let arr as [Any]:
            return arr.map { String(describing: $0) }.joined(separator: ", ")
        case let dict as [String: Any]:
            return "\(dict.count) keys"
        case let v?:
            return String(describing: v)
        case nil:
            return ""
        }
    }

    static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let maskedSub = cpuSubtype & 0x00FF_FFFF
        switch Int32(bitPattern: cpuType) {
        case CPU_TYPE_ARM64:
            if maskedSub == UInt32(CPU_SUBTYPE_ARM64E) { return "arm64e" }
            return "arm64"
        case CPU_TYPE_ARM64_32:
            return "arm64_32"
        case CPU_TYPE_ARM:
            switch Int32(maskedSub) {
            case CPU_SUBTYPE_ARM_V7S: return "armv7s"
            case CPU_SUBTYPE_ARM_V7K: return "armv7k"
            case CPU_SUBTYPE_ARM_V7: return "armv7"
            default: return "arm(\(maskedSub))"
            }
        case CPU_TYPE_X86_64:
            return "x86_64"
        case CPU_TYPE_X86:
            return "i386"
        default:
            return String(format: "cpu_0x%X", cpuType)
        }
    }

    private static func fileTypeName(_ fileType: UInt32) -> String {
        switch Int32(bitPattern: fileType) {
        case MH_OBJECT: return "MH_OBJECT (Relocatable)"
        case MH_EXECUTE: return "MH_EXECUTE (Executable)"
        case MH_DYLIB: return "MH_DYLIB (Dynamic Library)"
        case MH_DYLINKER: return "MH_DYLINKER"
        case MH_BUNDLE: return "MH_BUNDLE (Loadable Bundle)"
        case MH_DSYM: return "MH_DSYM (Debug Symbols)"
        case MH_KEXT_BUNDLE: return "MH_KEXT_BUNDLE"
        default: return "Type \(fileType)"
        }
    }

    private static func headerFlagNames(_ flags: UInt32) -> [String] {
        let mapping: [(UInt32, String)] = [
            (UInt32(MH_NOUNDEFS), "NOUNDEFS"),
            (UInt32(MH_DYLDLINK), "DYLDLINK"),
            (UInt32(MH_TWOLEVEL), "TWOLEVEL"),
            (UInt32(MH_PIE), "PIE"),
            (UInt32(MH_NO_HEAP_EXECUTION), "NO_HEAP_EXEC"),
            (UInt32(MH_APP_EXTENSION_SAFE), "APP_EXT_SAFE"),
            (UInt32(MH_HAS_TLV_DESCRIPTORS), "TLV"),
            (UInt32(MH_WEAK_DEFINES), "WEAK_DEFINES"),
            (UInt32(MH_BINDS_TO_WEAK), "BINDS_TO_WEAK"),
            (UInt32(MH_ALLOW_STACK_EXECUTION), "ALLOW_STACK_EXEC"),
        ]
        return mapping.compactMap { (flags & $0.0) != 0 ? $0.1 : nil }
    }

    private static func dylibKind(for cmd: UInt32) -> LCMachODylibKind {
        switch cmd {
        case UInt32(LC_ID_DYLIB): return .id
        case UInt32(LC_LOAD_WEAK_DYLIB): return .weak
        case UInt32(LC_REEXPORT_DYLIB): return .reexport
        case UInt32(LC_LOAD_UPWARD_DYLIB): return .upward
        case UInt32(LC_LAZY_LOAD_DYLIB): return .lazy
        default: return .required
        }
    }

    private static func platformDisplayName(_ platform: UInt32) -> String {
        switch platform {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 5: return "bridgeOS"
        case 6: return "Mac Catalyst"
        case 7: return "iOS Simulator"
        case 8: return "tvOS Simulator"
        case 9: return "watchOS Simulator"
        case 11: return "visionOS"
        case 12: return "visionOS Simulator"
        default: return "Platform \(platform)"
        }
    }

    private static func legacyPlatformName(for cmd: UInt32) -> String {
        switch cmd {
        case UInt32(LC_VERSION_MIN_IPHONEOS): return "iOS"
        case UInt32(LC_VERSION_MIN_MACOSX): return "macOS"
        case UInt32(LC_VERSION_MIN_TVOS): return "tvOS"
        case UInt32(LC_VERSION_MIN_WATCHOS): return "watchOS"
        default: return "Unknown"
        }
    }

    private static func codeSignHashName(_ hashType: UInt8) -> String {
        switch hashType {
        case 1: return "SHA-1"
        case 2: return "SHA-256"
        case 3: return "SHA-256 (Truncated)"
        case 4: return "SHA-384"
        default: return "Type \(hashType)"
        }
    }

    private static func codeSignFlagNames(_ flags: UInt32) -> [String] {
        let mapping: [(UInt32, String)] = [
            (0x0000_0002, "ADHOC"),
            (0x0000_0200, "KILL"),
            (0x0000_0800, "RESTRICT"),
            (0x0000_1000, "ENFORCEMENT"),
            (0x0000_2000, "LIBRARY_VALIDATION"),
            (0x0001_0000, "RUNTIME"),
            (0x0002_0000, "LINKER_SIGNED"),
        ]
        return mapping.compactMap { (flags & $0.0) != 0 ? $0.1 : nil }
    }

    private static func loadCommandName(_ cmd: UInt32) -> String {
        switch cmd {
        case UInt32(LC_SEGMENT): return "LC_SEGMENT"
        case UInt32(LC_SEGMENT_64): return "LC_SEGMENT_64"
        case UInt32(LC_SYMTAB): return "LC_SYMTAB"
        case UInt32(LC_DYSYMTAB): return "LC_DYSYMTAB"
        case UInt32(LC_LOAD_DYLIB): return "LC_LOAD_DYLIB"
        case UInt32(LC_ID_DYLIB): return "LC_ID_DYLIB"
        case UInt32(LC_LOAD_DYLINKER): return "LC_LOAD_DYLINKER"
        case UInt32(LC_LOAD_WEAK_DYLIB): return "LC_LOAD_WEAK_DYLIB"
        case UInt32(LC_REEXPORT_DYLIB): return "LC_REEXPORT_DYLIB"
        case UInt32(LC_LOAD_UPWARD_DYLIB): return "LC_LOAD_UPWARD_DYLIB"
        case UInt32(LC_LAZY_LOAD_DYLIB): return "LC_LAZY_LOAD_DYLIB"
        case UInt32(LC_UUID): return "LC_UUID"
        case UInt32(LC_RPATH): return "LC_RPATH"
        case UInt32(LC_CODE_SIGNATURE): return "LC_CODE_SIGNATURE"
        case UInt32(LC_SEGMENT_SPLIT_INFO): return "LC_SEGMENT_SPLIT_INFO"
        case UInt32(LC_ENCRYPTION_INFO): return "LC_ENCRYPTION_INFO"
        case UInt32(LC_ENCRYPTION_INFO_64): return "LC_ENCRYPTION_INFO_64"
        case UInt32(LC_DYLD_INFO): return "LC_DYLD_INFO"
        case UInt32(LC_DYLD_INFO_ONLY): return "LC_DYLD_INFO_ONLY"
        case UInt32(LC_VERSION_MIN_MACOSX): return "LC_VERSION_MIN_MACOSX"
        case UInt32(LC_VERSION_MIN_IPHONEOS): return "LC_VERSION_MIN_IPHONEOS"
        case UInt32(LC_VERSION_MIN_TVOS): return "LC_VERSION_MIN_TVOS"
        case UInt32(LC_VERSION_MIN_WATCHOS): return "LC_VERSION_MIN_WATCHOS"
        case UInt32(LC_FUNCTION_STARTS): return "LC_FUNCTION_STARTS"
        case UInt32(LC_MAIN): return "LC_MAIN"
        case UInt32(LC_DATA_IN_CODE): return "LC_DATA_IN_CODE"
        case UInt32(LC_SOURCE_VERSION): return "LC_SOURCE_VERSION"
        case UInt32(LC_BUILD_VERSION): return "LC_BUILD_VERSION"
        case UInt32(LC_DYLD_EXPORTS_TRIE): return "LC_DYLD_EXPORTS_TRIE"
        case UInt32(LC_DYLD_CHAINED_FIXUPS): return "LC_DYLD_CHAINED_FIXUPS"
        case lcDisabledTweakLoaderCmd: return "LC_DISABLED_TWEAKLOADER"
        default: return String(format: "LC_0x%X", cmd)
        }
    }
}

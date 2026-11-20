//
//  LCMachOChainedFixups.swift
//  LiveContainerSwiftUI
//
//  Virtual-address <-> file-offset mapper and modern `LC_DYLD_CHAINED_FIXUPS`
//  rebase/bind pointer decoder supporting iOS 15–27 arm64 and arm64e binaries.
//

import Foundation

/// Overflow-safe bidirectional virtual-address to file-offset mapper built from
/// a Mach-O slice's `LC_SEGMENT_64` / `LC_SEGMENT` load commands.
struct LCMachOVMMap: Sendable {
    struct SegmentSpan: Sendable {
        let index: Int
        let name: String
        let vmStart: UInt64
        let vmEnd: UInt64
        let sliceFileOffset: UInt64
        let fileSize: UInt64
    }

    let sliceOffset: UInt64
    let sliceSize: UInt64
    let preferredLoadAddress: UInt64
    let segments: [SegmentSpan]
    let sections: [LCMachOSectionInfo]

    init(sliceOffset: UInt64, sliceSize: UInt64, segments: [LCMachOSegmentInfo]) {
        self.sliceOffset = sliceOffset
        self.sliceSize = sliceSize

        var spans: [SegmentSpan] = []
        var allSections: [LCMachOSectionInfo] = []
        var textBase: UInt64?

        for (idx, seg) in segments.enumerated() {
            if seg.name == "__TEXT", textBase == nil {
                textBase = seg.vmAddress
            }
            allSections.append(contentsOf: seg.sections)
            guard seg.fileSize > 0 else { continue }
            let (vmEnd, overflow) = seg.vmAddress.addingReportingOverflow(seg.vmSize)
            let clampedVMEnd = overflow ? UInt64.max : vmEnd
            spans.append(SegmentSpan(
                index: idx,
                name: seg.name,
                vmStart: seg.vmAddress,
                vmEnd: clampedVMEnd,
                sliceFileOffset: seg.fileOffset,
                fileSize: seg.fileSize
            ))
        }

        self.preferredLoadAddress = textBase ?? 0
        self.segments = spans
        self.sections = allSections
    }

    /// Converts a Mach-O virtual memory address into an absolute file offset
    /// (including `sliceOffset`), returning `nil` if unmapped or out of bounds.
    func fileOffset(forVMAddress vmAddress: UInt64) -> UInt64? {
        for span in segments {
            guard vmAddress >= span.vmStart && vmAddress < span.vmEnd else { continue }
            let delta = vmAddress - span.vmStart
            guard delta < span.fileSize else { return nil }
            let (relOffset, ov1) = span.sliceFileOffset.addingReportingOverflow(delta)
            guard !ov1, relOffset < sliceSize else { return nil }
            let (absOffset, ov2) = sliceOffset.addingReportingOverflow(relOffset)
            guard !ov2 else { return nil }
            return absOffset
        }
        return nil
    }

    /// Converts a slice-relative file offset into its mapped virtual memory address.
    func vmAddress(forSliceFileOffset relOffset: UInt64) -> UInt64? {
        for span in segments {
            let (fileEnd, ov) = span.sliceFileOffset.addingReportingOverflow(span.fileSize)
            guard !ov else { continue }
            if relOffset >= span.sliceFileOffset && relOffset < fileEnd {
                let delta = relOffset - span.sliceFileOffset
                let (vm, vmOv) = span.vmStart.addingReportingOverflow(delta)
                return vmOv ? nil : vm
            }
        }
        return nil
    }

    /// Returns whether `vmAddress` falls inside any file-backed segment.
    func contains(vmAddress: UInt64) -> Bool {
        fileOffset(forVMAddress: vmAddress) != nil
    }

    /// Returns the segment index containing `vmAddress`, if any.
    func segmentIndex(forVMAddress vmAddress: UInt64) -> Int? {
        segments.first(where: { vmAddress >= $0.vmStart && vmAddress < $0.vmEnd })?.index
    }

    /// Finds the first section matching `sectionName` (and optionally `segmentName`).
    func section(named sectionName: String, inSegment segmentName: String? = nil) -> LCMachOSectionInfo? {
        sections.first { sec in
            sec.sectionName == sectionName && (segmentName == nil || sec.segmentName == segmentName)
        }
    }

    /// Finds all sections whose name matches `sectionName` across `__DATA`, `__DATA_CONST`, `__DATA_DIRTY`, etc.
    func sections(named sectionName: String) -> [LCMachOSectionInfo] {
        sections.filter { $0.sectionName == sectionName }
    }
}

/// Decoded result of a 64-bit pointer stored inside `__DATA` / `__DATA_CONST`.
enum LCResolvedPointer: Sendable {
    case null
    case rebase(vmAddress: UInt64)
    case bind(symbolName: String)
    case raw(UInt64)

    var vmAddress: UInt64? {
        switch self {
        case let .rebase(addr): return addr
        case let .raw(addr): return addr
        case .null, .bind: return nil
        }
    }
}

/// Parses `LC_DYLD_CHAINED_FIXUPS` pointer formats and imported symbol tables,
/// decoding modern iOS 15–27 chained rebase/bind pointers cleanly.
struct LCMachOChainedFixupsDecoder: Sendable {
    // dyld_chained_ptr_format constants from <mach-o/fixup-chains.h>
    private static let ptrArm64e: UInt16 = 1
    private static let ptr64: UInt16 = 2
    private static let ptr32: UInt16 = 3
    private static let ptr32Cache: UInt16 = 4
    private static let ptr32Firmware: UInt16 = 5
    private static let ptr64Offset: UInt16 = 6
    private static let ptrArm64eOffset: UInt16 = 7        // DYLD_CHAINED_PTR_ARM64E_USERLAND
    private static let ptr64KernelCache: UInt16 = 8
    private static let ptrArm64eKernel: UInt16 = 9
    private static let ptrArm64eFirmware: UInt16 = 10
    private static let ptrArm64eUserland24: UInt16 = 12

    // dyld_chained_import_format constants
    private static let importFormatBasic: UInt32 = 1
    private static let importFormatAddend: UInt32 = 2
    private static let importFormatAddend64: UInt32 = 3

    private static let maxImportCount: UInt32 = 65_536

    let vmMap: LCMachOVMMap
    let hasChainedFixups: Bool
    let segmentPointerFormats: [Int: UInt16]
    let defaultPointerFormat: UInt16?
    let importedSymbols: [String]
    let diagnostics: [String]

    init(vmMap: LCMachOVMMap) {
        self.vmMap = vmMap
        self.hasChainedFixups = false
        self.segmentPointerFormats = [:]
        self.defaultPointerFormat = nil
        self.importedSymbols = []
        self.diagnostics = []
    }

    init(
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixupsDataOffset: UInt64,
        fixupsDataSize: UInt64
    ) {
        self.vmMap = vmMap
        var diag: [String] = []
        var formats: [Int: UInt16] = [:]
        var imports: [String] = []

        let absOffset = vmMap.sliceOffset + fixupsDataOffset
        guard fixupsDataSize >= 28,
              fixupsDataSize <= UInt64(LCBoundedFileReader.maxSingleReadBytes),
              let payload = try? reader.readData(offset: absOffset, count: Int(fixupsDataSize)) else {
            self.hasChainedFixups = false
            self.segmentPointerFormats = [:]
            self.defaultPointerFormat = nil
            self.importedSymbols = []
            self.diagnostics = ["LC_DYLD_CHAINED_FIXUPS payload could not be read cleanly."]
            return
        }

        let startsOffset = Int(payload.lcReadUInt32(at: 4) ?? 0)
        let importsOffset = Int(payload.lcReadUInt32(at: 8) ?? 0)
        let symbolsOffset = Int(payload.lcReadUInt32(at: 12) ?? 0)
        let importsCount = payload.lcReadUInt32(at: 16) ?? 0
        let importsFormat = payload.lcReadUInt32(at: 20) ?? 0

        // Parse dyld_chained_starts_in_image -> per-segment pointer_format
        if startsOffset > 0, startsOffset + 4 <= payload.count,
           let segCount = payload.lcReadUInt32(at: startsOffset),
           segCount <= 256 {
            for segIdx in 0..<Int(segCount) {
                let entryPos = startsOffset + 4 + segIdx * 4
                guard let segInfoRel = payload.lcReadUInt32(at: entryPos), segInfoRel != 0 else {
                    continue
                }
                let segInfoPos = startsOffset + Int(segInfoRel)
                // dyld_chained_starts_in_segment:
                // 0: size (u32), 4: page_size (u16), 6: pointer_format (u16)
                if segInfoPos + 8 <= payload.count,
                   let pointerFormat = payload.lcReadUInt16(at: segInfoPos + 6) {
                    formats[segIdx] = pointerFormat
                }
            }
        }

        // Parse imported symbol table for bind resolution (e.g. superclass imports like _OBJC_CLASS_$_UIViewController)
        let cappedImports = min(importsCount, Self.maxImportCount)
        if cappedImports < importsCount {
            diag.append("Chained fixups import table truncated to \(cappedImports) of \(importsCount) entries.")
        }
        if cappedImports > 0, importsOffset > 0, symbolsOffset > 0, symbolsOffset < payload.count {
            imports.reserveCapacity(Int(cappedImports))
            for idx in 0..<Int(cappedImports) {
                let nameOffset: UInt32?
                switch importsFormat {
                case Self.importFormatBasic:
                    // bitfield: lib_ordinal:8, weak_import:1, name_offset:23
                    if let raw = payload.lcReadUInt32(at: importsOffset + idx * 4) {
                        nameOffset = (raw >> 9) & 0x7FFFFF
                    } else {
                        nameOffset = nil
                    }
                case Self.importFormatAddend:
                    // 8 bytes per entry: u32 (same bitfield) + s32 addend
                    if let raw = payload.lcReadUInt32(at: importsOffset + idx * 8) {
                        nameOffset = (raw >> 9) & 0x7FFFFF
                    } else {
                        nameOffset = nil
                    }
                case Self.importFormatAddend64:
                    // 16 bytes per entry: u64 (lib_ordinal:16, weak:1, reserved:15, name_offset:32) + s64 addend
                    if let raw = payload.lcReadUInt64(at: importsOffset + idx * 16) {
                        nameOffset = UInt32((raw >> 32) & 0xFFFFFFFF)
                    } else {
                        nameOffset = nil
                    }
                default:
                    nameOffset = nil
                }

                if let nOff = nameOffset {
                    let strPos = symbolsOffset + Int(nOff)
                    if strPos >= symbolsOffset && strPos < payload.count {
                        imports.append(payload.lcReadCString(at: strPos, maxLength: 512))
                    } else {
                        imports.append("")
                    }
                } else {
                    imports.append("")
                }
            }
        }

        self.hasChainedFixups = !formats.isEmpty || !imports.isEmpty
        self.segmentPointerFormats = formats
        self.defaultPointerFormat = formats.values.first
        self.importedSymbols = imports
        self.diagnostics = diag
    }

    /// Decodes a raw 64-bit pointer stored at `storageVMAddress` into either a
    /// valid mapped VM address (`.rebase`), an imported symbol name (`.bind`),
    /// `.null`, or `.raw` fallback.
    func resolvePointer(rawValue: UInt64, atVMAddress storageVMAddress: UInt64? = nil) -> LCResolvedPointer {
        if rawValue == 0 {
            return .null
        }

        // Fast path: if the binary does not use chained fixups and the value is directly mapped
        if !hasChainedFixups {
            if vmMap.contains(vmAddress: rawValue) {
                return .rebase(vmAddress: rawValue)
            }
            // Strip top PAC/TBI tag bits (top 16 bits) as a safe fallback for signed pointers
            let stripped = rawValue & 0x0000_7FFF_FFFF_FFFF
            if vmMap.contains(vmAddress: stripped) {
                return .rebase(vmAddress: stripped)
            }
            return .raw(rawValue)
        }

        let pointerFormat: UInt16?
        if let storageVMAddress, let segIdx = vmMap.segmentIndex(forVMAddress: storageVMAddress) {
            pointerFormat = segmentPointerFormats[segIdx] ?? defaultPointerFormat
        } else {
            pointerFormat = defaultPointerFormat
        }

        if let format = pointerFormat {
            if let decoded = decodeChainedPointer(rawValue: rawValue, format: format) {
                return decoded
            }
        }

        // Fallback: direct VM mapping check or PAC-stripped check
        if vmMap.contains(vmAddress: rawValue) {
            return .rebase(vmAddress: rawValue)
        }
        let stripped = rawValue & 0x0000_7FFF_FFFF_FFFF
        if vmMap.contains(vmAddress: stripped) {
            return .rebase(vmAddress: stripped)
        }
        return .raw(rawValue)
    }

    private func decodeChainedPointer(rawValue: UInt64, format: UInt16) -> LCResolvedPointer? {
        switch format {
        case Self.ptr64:
            let isBind = (rawValue >> 63) & 1 != 0
            if isBind {
                let ordinal = Int(rawValue & 0x00FF_FFFF)
                if ordinal >= 0 && ordinal < importedSymbols.count && !importedSymbols[ordinal].isEmpty {
                    return .bind(symbolName: importedSymbols[ordinal])
                }
                return nil
            } else {
                let target = rawValue & 0x0000_000F_FFFF_FFFF // low 36 bits
                let high8 = (rawValue >> 36) & 0xFF
                let combined = target | (high8 << 56)
                if vmMap.contains(vmAddress: combined) {
                    return .rebase(vmAddress: combined)
                }
                if vmMap.contains(vmAddress: target) {
                    return .rebase(vmAddress: target)
                }
                let withBase = vmMap.preferredLoadAddress &+ target
                if vmMap.contains(vmAddress: withBase) {
                    return .rebase(vmAddress: withBase)
                }
                return nil
            }

        case Self.ptr64Offset:
            let isBind = (rawValue >> 63) & 1 != 0
            if isBind {
                let ordinal = Int(rawValue & 0x00FF_FFFF)
                if ordinal >= 0 && ordinal < importedSymbols.count && !importedSymbols[ordinal].isEmpty {
                    return .bind(symbolName: importedSymbols[ordinal])
                }
                return nil
            } else {
                let offset = rawValue & 0x0000_000F_FFFF_FFFF // low 36 bits offset from preferred base
                let candidate = vmMap.preferredLoadAddress &+ offset
                if vmMap.contains(vmAddress: candidate) {
                    return .rebase(vmAddress: candidate)
                }
                if vmMap.contains(vmAddress: offset) {
                    return .rebase(vmAddress: offset)
                }
                return nil
            }

        case Self.ptrArm64e, Self.ptrArm64eOffset, Self.ptrArm64eUserland24, Self.ptrArm64eKernel, Self.ptrArm64eFirmware:
            let isAuth = (rawValue >> 63) & 1 != 0
            let isBind = (rawValue >> 62) & 1 != 0
            if isBind {
                let ordinalMask: UInt64 = (format == Self.ptrArm64eUserland24) ? 0x00FF_FFFF : 0xFFFF
                let ordinal = Int(rawValue & ordinalMask)
                if ordinal >= 0 && ordinal < importedSymbols.count && !importedSymbols[ordinal].isEmpty {
                    return .bind(symbolName: importedSymbols[ordinal])
                }
                return nil
            }
            if isAuth {
                // dyld_chained_ptr_arm64e_auth_rebase: low 32 bits = offset from preferred load address
                let target32 = rawValue & 0xFFFF_FFFF
                let candidate = vmMap.preferredLoadAddress &+ target32
                if vmMap.contains(vmAddress: candidate) {
                    return .rebase(vmAddress: candidate)
                }
                if vmMap.contains(vmAddress: target32) {
                    return .rebase(vmAddress: target32)
                }
                return nil
            } else {
                // dyld_chained_ptr_arm64e_rebase: low 43 bits = target (direct or offset for USERLAND/USERLAND24)
                let target43 = rawValue & 0x0000_07FF_FFFF_FFFF
                if format == Self.ptrArm64eOffset || format == Self.ptrArm64eUserland24 {
                    let candidate = vmMap.preferredLoadAddress &+ target43
                    if vmMap.contains(vmAddress: candidate) {
                        return .rebase(vmAddress: candidate)
                    }
                }
                if vmMap.contains(vmAddress: target43) {
                    return .rebase(vmAddress: target43)
                }
                let withBase = vmMap.preferredLoadAddress &+ target43
                if vmMap.contains(vmAddress: withBase) {
                    return .rebase(vmAddress: withBase)
                }
                return nil
            }

        default:
            return nil
        }
    }
}

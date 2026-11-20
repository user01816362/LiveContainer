//
//  LCMachOSwiftAndSymbols.swift
//  LiveContainerSwiftUI
//
//  Runtime Swift/C++ demangler via `dlsym(RTLD_DEFAULT, ...)`, Swift 5+
//  metadata section reader (`__swift5_types`, `__swift5_fieldmd`, `__swift5_proto`),
//  `LC_DYLD_EXPORTS_TRIE` ULEB128 walker, bounded `LC_SYMTAB` parser, and
//  categorized `__cstring` string extractor.
//

import Darwin
import Foundation
import MachO

// MARK: - Runtime Swift & C++ Demangler

/// Zero-dependency runtime symbol demangler using the host iOS Swift and C++ ABI runtimes.
enum LCDemangler {
    private typealias SwiftDemangleFn = @convention(c) (
        UnsafePointer<CChar>?,
        Int,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private typealias CxaDemangleFn = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?,
        UnsafeMutablePointer<Int32>?
    ) -> UnsafeMutablePointer<CChar>?

    /// Equivalent to C macro `RTLD_DEFAULT` (`(void *)-2`), which Swift cannot import directly.
    private static var rtldDefault: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    private static let swiftDemangleSym: SwiftDemangleFn? = {
        guard let ptr = dlsym(rtldDefault, "swift_demangle") else { return nil }
        return unsafeBitCast(ptr, to: SwiftDemangleFn.self)
    }()

    private static let cxaDemangleSym: CxaDemangleFn? = {
        guard let ptr = dlsym(rtldDefault, "__cxa_demangle") else { return nil }
        return unsafeBitCast(ptr, to: CxaDemangleFn.self)
    }()

    /// Demangles Swift (`$s`, `_$s`, `_T`, `$S`) or Itanium C++ (`_Z`, `__Z`) symbols when possible.
    static func demangleIfNeeded(_ symbol: String) -> String {
        guard !symbol.isEmpty else { return symbol }

        if isSwiftMangled(symbol), let fn = swiftDemangleSym {
            let input = symbol.hasPrefix("_$s") || symbol.hasPrefix("_$S")
                ? String(symbol.dropFirst())
                : symbol
            if let demangled = input.withCString({ cstr -> String? in
                guard let out = fn(cstr, strlen(cstr), nil, nil, 0) else { return nil }
                defer { free(out) }
                return String(cString: out)
            }), !demangled.isEmpty {
                return demangled
            }
        }

        if isCxxMangled(symbol), let fn = cxaDemangleSym {
            let input = symbol.hasPrefix("__Z") ? String(symbol.dropFirst()) : symbol
            if let demangled = input.withCString({ cstr -> String? in
                var status: Int32 = 0
                guard let out = fn(cstr, nil, nil, &status) else { return nil }
                defer { free(out) }
                return status == 0 ? String(cString: out) : nil
            }), !demangled.isEmpty {
                return demangled
            }
        }

        return symbol
    }

    static func isSwiftMangled(_ symbol: String) -> Bool {
        symbol.hasPrefix("$s") || symbol.hasPrefix("_$s")
            || symbol.hasPrefix("$S") || symbol.hasPrefix("_$S")
            || symbol.hasPrefix("_T0") || symbol.hasPrefix("_Tt")
            || symbol.hasPrefix("$e") || symbol.hasPrefix("_$e")
    }

    static func isCxxMangled(_ symbol: String) -> Bool {
        symbol.hasPrefix("_Z") || symbol.hasPrefix("__Z")
    }
}

// MARK: - Swift Metadata Parser

/// Reads Swift nominal type descriptors (`__swift5_types`), protocols
/// (`__swift5_proto`), and field descriptors (`__swift5_fieldmd`).
enum LCMachOSwiftParser {
    private static let maxTypes = 15_000
    private static let maxProtocols = 5_000
    private static let maxFieldsPerType = 512

    static func parseMetadata(
        context: LCMachOParsedSliceContext,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) throws -> LCSwiftMetadataResult {
        if context.overview.header.isEncrypted {
            throw LCMachOInspectorError.encryptedBinaryCannotDump
        }
        guard !context.overview.selectedSlice.isByteSwapped else {
            return LCSwiftMetadataResult(types: [], diagnostics: ["Byte-swapped slices are not supported for Swift metadata."], wasTruncated: false)
        }

        let scopeRoot = rootURL ?? context.overview.fileURL
        return try LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: context.overview.fileURL)
            let vmMap = context.vmMap
            var types: [LCSwiftTypeInfo] = []
            var diagnostics: [String] = []
            var truncated = false
            var seenAddresses = Set<UInt64>()

            // 1. __swift5_types: array of 32-bit signed relative pointers to TargetTypeContextDescriptor
            for section in vmMap.sections(named: "__swift5_types") {
                guard section.size >= 4, section.size <= UInt64(LCBoundedFileReader.maxSingleReadBytes) else { continue }
                guard let relData = try? reader.readSliceData(
                    sliceOffset: vmMap.sliceOffset,
                    sliceSize: vmMap.sliceSize,
                    relativeOffset: section.fileOffset,
                    count: Int(section.size)
                ) else { continue }

                let count = relData.count / 4
                for i in 0..<count {
                    if Task.isCancelled { break }
                    if types.count >= maxTypes {
                        truncated = true
                        diagnostics.append("Swift type list capped at \(maxTypes) types.")
                        break
                    }
                    guard let rel = relData.lcReadInt32(at: i * 4), rel != 0 else { continue }
                    let entryVM = section.vmAddress &+ UInt64(i * 4)
                    let descVM = addSigned(entryVM, offset: rel)
                    guard seenAddresses.insert(descVM).inserted else { continue }
                    if let parsed = parseTypeDescriptor(at: descVM, reader: reader, vmMap: vmMap) {
                        types.append(parsed)
                    }
                }
            }

            // 2. __swift5_proto: array of 32-bit signed relative pointers to TargetProtocolDescriptor
            var protoCount = 0
            for section in vmMap.sections(named: "__swift5_proto") {
                guard section.size >= 4, section.size <= UInt64(LCBoundedFileReader.maxSingleReadBytes) else { continue }
                guard let relData = try? reader.readSliceData(
                    sliceOffset: vmMap.sliceOffset,
                    sliceSize: vmMap.sliceSize,
                    relativeOffset: section.fileOffset,
                    count: Int(section.size)
                ) else { continue }

                let count = relData.count / 4
                for i in 0..<count {
                    if Task.isCancelled { break }
                    if protoCount >= maxProtocols {
                        truncated = true
                        diagnostics.append("Swift protocol list capped at \(maxProtocols) protocols.")
                        break
                    }
                    guard let rel = relData.lcReadInt32(at: i * 4), rel != 0 else { continue }
                    let entryVM = section.vmAddress &+ UInt64(i * 4)
                    let descVM = addSigned(entryVM, offset: rel)
                    guard seenAddresses.insert(descVM).inserted else { continue }
                    if let proto = parseProtocolDescriptor(at: descVM, reader: reader, vmMap: vmMap) {
                        types.append(proto)
                        protoCount += 1
                    }
                }
            }

            return LCSwiftMetadataResult(
                types: types.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                diagnostics: diagnostics,
                wasTruncated: truncated
            )
        }
    }

    private static func parseTypeDescriptor(
        at descVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap
    ) -> LCSwiftTypeInfo? {
        // TargetTypeContextDescriptor:
        // 0: flags (u32), 4: parent (s32 rel), 8: name (s32 rel),
        // 12: accessFunctionPtr (s32 rel), 16: fieldDescriptor (s32 rel)
        guard let off = vmMap.fileOffset(forVMAddress: descVM),
              let data = try? reader.readData(offset: off, count: 20) else {
            return nil
        }

        let flags = data.lcReadUInt32(at: 0) ?? 0
        let kindBits = flags & 0x1F
        let kind: LCSwiftTypeKind
        switch kindBits {
        case 16: kind = .classType
        case 17: kind = .structType
        case 18: kind = .enumType
        default: return nil
        }

        guard let nameRel = data.lcReadInt32(at: 8), nameRel != 0 else { return nil }
        let nameVM = addSigned(descVM &+ 8, offset: nameRel)
        guard let nameOff = vmMap.fileOffset(forVMAddress: nameVM),
              let rawName = try? reader.readCString(offset: nameOff, maxLength: 256),
              !rawName.isEmpty,
              isPrintableIdentifier(rawName) else {
            return nil
        }

        // Resolve parent chain (up to 4 levels) for qualified names like Module.Outer.Inner
        var qualifiedParts = [rawName]
        var currentParentBase = descVM &+ 4
        var currentParentRel = data.lcReadInt32(at: 4) ?? 0
        for _ in 0..<4 {
            guard currentParentRel != 0 else { break }
            // TargetRelativeContextPointer uses bit 0 to indicate an indirect pointer
            let isIndirect = (currentParentRel & 1) != 0
            let alignedRel = currentParentRel & ~1
            let rawParentVM = addSigned(currentParentBase, offset: alignedRel)
            let parentVM: UInt64
            if isIndirect {
                guard let ptrOff = vmMap.fileOffset(forVMAddress: rawParentVM),
                      let deref = try? reader.readUInt64(offset: ptrOff) else {
                    break
                }
                parentVM = deref & 0x0000_7FFF_FFFF_FFFF
            } else {
                parentVM = rawParentVM
            }
            guard let pOff = vmMap.fileOffset(forVMAddress: parentVM),
                  let pData = try? reader.readData(offset: pOff, count: 12) else {
                break
            }
            let pFlags = pData.lcReadUInt32(at: 0) ?? 0
            let pKind = pFlags & 0x1F
            // Module (0), Extension (1), Class (16), Struct (17), Enum (18)
            guard pKind == 0 || pKind == 16 || pKind == 17 || pKind == 18 else { break }
            if let pNameRel = pData.lcReadInt32(at: 8), pNameRel != 0 {
                let pNameVM = addSigned(parentVM &+ 8, offset: pNameRel)
                if let pNameOff = vmMap.fileOffset(forVMAddress: pNameVM),
                   let pName = try? reader.readCString(offset: pNameOff, maxLength: 128),
                   !pName.isEmpty, isPrintableIdentifier(pName) {
                    qualifiedParts.insert(pName, at: 0)
                }
            }
            if pKind == 0 { break } // Reached module root
            currentParentBase = parentVM &+ 4
            currentParentRel = pData.lcReadInt32(at: 4) ?? 0
        }

        var fields: [LCSwiftFieldInfo] = []
        if let fieldRel = data.lcReadInt32(at: 16), fieldRel != 0 {
            let fieldDescVM = addSigned(descVM &+ 16, offset: fieldRel)
            fields = parseFieldDescriptor(at: fieldDescVM, reader: reader, vmMap: vmMap)
        }

        return LCSwiftTypeInfo(
            name: qualifiedParts.joined(separator: "."),
            kind: kind,
            vmAddress: descVM,
            fields: fields
        )
    }

    private static func parseProtocolDescriptor(
        at descVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap
    ) -> LCSwiftTypeInfo? {
        guard let off = vmMap.fileOffset(forVMAddress: descVM),
              let data = try? reader.readData(offset: off, count: 12) else {
            return nil
        }
        guard let nameRel = data.lcReadInt32(at: 8), nameRel != 0 else { return nil }
        let nameVM = addSigned(descVM &+ 8, offset: nameRel)
        guard let nameOff = vmMap.fileOffset(forVMAddress: nameVM),
              let name = try? reader.readCString(offset: nameOff, maxLength: 256),
              !name.isEmpty, isPrintableIdentifier(name) else {
            return nil
        }
        return LCSwiftTypeInfo(name: name, kind: .protocolType, vmAddress: descVM, fields: [])
    }

    private static func parseFieldDescriptor(
        at fieldDescVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap
    ) -> [LCSwiftFieldInfo] {
        // FieldDescriptor:
        // 0: mangledTypeName (s32), 4: superclass (s32), 8: kind (u16),
        // 10: fieldRecordSize (u16), 12: numFields (u32)
        guard let off = vmMap.fileOffset(forVMAddress: fieldDescVM),
              let header = try? reader.readData(offset: off, count: 16) else {
            return []
        }
        let recordSize = Int(header.lcReadUInt16(at: 10) ?? 12)
        let numFields = Int(min(header.lcReadUInt32(at: 12) ?? 0, UInt32(maxFieldsPerType)))
        guard recordSize >= 12, numFields > 0,
              numFields * recordSize <= LCBoundedFileReader.maxSingleReadBytes,
              let records = try? reader.readData(offset: off + 16, count: numFields * recordSize) else {
            return []
        }

        var result: [LCSwiftFieldInfo] = []
        result.reserveCapacity(numFields)
        for idx in 0..<numFields {
            let recOff = idx * recordSize
            let recVM = fieldDescVM &+ 16 &+ UInt64(recOff)
            let flags = records.lcReadUInt32(at: recOff) ?? 0
            let typeNameRel = records.lcReadInt32(at: recOff + 4) ?? 0
            let fieldNameRel = records.lcReadInt32(at: recOff + 8) ?? 0

            guard fieldNameRel != 0 else { continue }
            let nameVM = addSigned(recVM &+ 8, offset: fieldNameRel)
            guard let nameFileOff = vmMap.fileOffset(forVMAddress: nameVM),
                  let fieldName = try? reader.readCString(offset: nameFileOff, maxLength: 256),
                  !fieldName.isEmpty else {
                continue
            }

            var typeDisplay = "Any"
            if typeNameRel != 0 {
                let typeVM = addSigned(recVM &+ 4, offset: typeNameRel)
                if let typeFileOff = vmMap.fileOffset(forVMAddress: typeVM),
                   let rawBytes = try? reader.readUpTo(offset: typeFileOff, maxCount: 256),
                   !rawBytes.isEmpty {
                    // Swift symbolic references start with 0x01..0x17 followed by a 4-byte relative offset.
                    // Avoid misdecoding binary symbolic references as raw UTF-8 strings.
                    if let firstByte = rawBytes.first, firstByte >= 0x01 && firstByte <= 0x17 {
                        typeDisplay = resolveSymbolicSwiftType(at: typeVM, bytes: rawBytes, reader: reader, vmMap: vmMap) ?? "SwiftType"
                    } else if let zeroIdx = rawBytes.firstIndex(of: 0) {
                        let slice = rawBytes[..<zeroIdx]
                        if slice.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                           let rawMangled = String(data: slice, encoding: .ascii),
                           !rawMangled.isEmpty {
                            let candidate = "$s" + rawMangled + "D"
                            let demangled = LCDemangler.demangleIfNeeded(candidate)
                            typeDisplay = demangled != candidate ? demangled : rawMangled
                        }
                    }
                }
            }

            result.append(LCSwiftFieldInfo(
                name: fieldName,
                typeName: typeDisplay,
                isMutable: (flags & 0x2) != 0,
                isIndirect: (flags & 0x1) != 0
            ))
        }
        return result
    }

    private static func resolveSymbolicSwiftType(
        at typeVM: UInt64,
        bytes: Data,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap
    ) -> String? {
        guard bytes.count >= 5, let kind = bytes.first, (kind == 0x01 || kind == 0x02),
              let rel = bytes.lcReadInt32(at: 1) else {
            return nil
        }
        let targetVM = addSigned(typeVM &+ 1, offset: rel)
        let descVM: UInt64
        if kind == 0x02 {
            guard let ptrOff = vmMap.fileOffset(forVMAddress: targetVM),
                  let deref = try? reader.readUInt64(offset: ptrOff) else {
                return nil
            }
            descVM = deref & 0x0000_7FFF_FFFF_FFFF
        } else {
            descVM = targetVM
        }
        guard let descOff = vmMap.fileOffset(forVMAddress: descVM),
              let descData = try? reader.readData(offset: descOff, count: 12),
              let nameRel = descData.lcReadInt32(at: 8), nameRel != 0 else {
            return nil
        }
        let nameVM = addSigned(descVM &+ 8, offset: nameRel)
        guard let nameOff = vmMap.fileOffset(forVMAddress: nameVM),
              let name = try? reader.readCString(offset: nameOff, maxLength: 128),
              !name.isEmpty, isPrintableIdentifier(name) else {
            return nil
        }
        return name
    }

    private static func addSigned(_ base: UInt64, offset: Int32) -> UInt64 {
        let delta = Int64(offset)
        return delta >= 0 ? (base &+ UInt64(delta)) : (base &- UInt64(-delta))
    }

    private static func isPrintableIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
    }
}

// MARK: - Exports Trie & Symbol Table Parser

/// Extracts exported symbols from `LC_DYLD_EXPORTS_TRIE` and symbol table
/// entries from `LC_SYMTAB`, demangling Swift and C++ names automatically.
enum LCMachOSymbolsParser {
    private static let maxExports = 50_000
    private static let maxSymtabSymbols = 100_000
    private static let maxTrieDepth = 64

    static func parseSymbols(
        context: LCMachOParsedSliceContext,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) throws -> LCMachOSymbolsResult {
        let scopeRoot = rootURL ?? context.overview.fileURL
        return try LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: context.overview.fileURL)
            let sliceOffset = context.overview.selectedSlice.fileOffset
            let sliceSize = context.overview.selectedSlice.size
            let preferredBase = context.vmMap.preferredLoadAddress
            var symbols: [LCMachOSymbolInfo] = []
            var seenKeys = Set<String>()
            var diagnostics: [String] = []
            var truncated = false

            guard !context.overview.selectedSlice.isByteSwapped else {
                return LCMachOSymbolsResult(symbols: [], exportCount: 0, symtabCount: 0, wasTruncated: false, diagnostics: ["Byte-swapped slices are not supported for symbol decoding."])
            }

            // 1. LC_DYLD_EXPORTS_TRIE (modern iOS 15–27 exports)
            var exportCount = 0
            if let expOff = context.exportsTrieOffset, context.exportsTrieSize > 0, expOff < sliceSize {
                let avail = sliceSize - expOff
                let size = Int(min(UInt64(context.exportsTrieSize), min(avail, UInt64(LCBoundedFileReader.maxSingleReadBytes))))
                if let trieData = try? reader.readSliceData(
                    sliceOffset: sliceOffset,
                    sliceSize: sliceSize,
                    relativeOffset: expOff,
                    count: size
                ) {
                    let exports = walkExportsTrie(
                        data: trieData,
                        preferredBase: preferredBase,
                        truncated: &truncated,
                        diagnostics: &diagnostics
                    )
                    exportCount = exports.count
                    for item in exports {
                        let key = "E:\(item.rawName):\(item.address)"
                        if seenKeys.insert(key).inserted {
                            symbols.append(item)
                        }
                    }
                }
            }

            // 2. LC_SYMTAB (nlist_64 / nlist)
            var symtabParsed = 0
            if let symOff = context.symtabOffset,
               let strOff = context.strtabOffset,
               context.symtabCount > 0,
               context.strtabSize > 0,
               symOff < sliceSize,
               strOff < sliceSize {
                let is64 = context.overview.selectedSlice.is64Bit
                let entrySize = is64 ? 16 : 12
                let maxByReadCap = LCBoundedFileReader.maxSingleReadBytes / entrySize
                let maxBySlice = Int(min((sliceSize - symOff) / UInt64(entrySize), UInt64(Int.max)))
                let countToRead = min(Int(context.symtabCount), min(maxSymtabSymbols, min(maxByReadCap, maxBySlice)))
                if countToRead < Int(context.symtabCount) {
                    truncated = true
                    diagnostics.append("Symbol table capped at \(countToRead) of \(context.symtabCount) entries.")
                }

                let strReadSize = Int(min(UInt64(context.strtabSize), min(sliceSize - strOff, UInt64(LCBoundedFileReader.maxSingleReadBytes))))
                if countToRead > 0, strReadSize > 0,
                   let symData = try? reader.readSliceData(
                       sliceOffset: sliceOffset,
                       sliceSize: sliceSize,
                       relativeOffset: symOff,
                       count: countToRead * entrySize
                   ),
                   let strData = try? reader.readSliceData(
                       sliceOffset: sliceOffset,
                       sliceSize: sliceSize,
                       relativeOffset: strOff,
                       count: strReadSize
                   ) {
                    symbols.reserveCapacity(symbols.count + countToRead)
                    for i in 0..<countToRead {
                        if Task.isCancelled { break }
                        let pos = i * entrySize
                        guard let strx = symData.lcReadUInt32(at: pos), strx > 0 else { continue }
                        let nType = symData[pos + 4]
                        // Skip STAB debug records (N_STAB = 0xe0)
                        if (nType & 0xE0) != 0 { continue }

                        let strIdx = Int(strx)
                        guard strIdx < strData.count else { continue }
                        let rawName = strData.lcReadCString(at: strIdx, maxLength: 512)
                        guard !rawName.isEmpty else { continue }

                        let addr: UInt64
                        if is64 {
                            addr = symData.lcReadUInt64(at: pos + 8) ?? 0
                        } else {
                            addr = UInt64(symData.lcReadUInt32(at: pos + 8) ?? 0)
                        }

                        let typeField = nType & 0x0E // N_TYPE
                        let isExt = (nType & 0x01) != 0 // N_EXT
                        let scope: LCMachOSymbolScope
                        if typeField == 0x00 { // N_UNDF
                            scope = .undefined
                        } else if isExt {
                            scope = .external
                        } else {
                            scope = .local
                        }

                        let key = "\(scope.rawValue):\(rawName):\(addr)"
                        guard seenKeys.insert(key).inserted else { continue }
                        let demangled = LCDemangler.demangleIfNeeded(rawName)
                        let isSwift = LCDemangler.isSwiftMangled(rawName)
                        let isObjC = rawName.contains("OBJC_") || rawName.hasPrefix("-[") || rawName.hasPrefix("+[")
                        symbols.append(LCMachOSymbolInfo(
                            id: key,
                            rawName: rawName,
                            demangledName: demangled,
                            address: addr,
                            scope: scope,
                            isSwift: isSwift,
                            isObjC: isObjC
                        ))
                        symtabParsed += 1
                    }
                }
            }

            return LCMachOSymbolsResult(
                symbols: symbols,
                exportCount: exportCount,
                symtabCount: symtabParsed,
                wasTruncated: truncated,
                diagnostics: diagnostics
            )
        }
    }

    private static func walkExportsTrie(
        data: Data,
        preferredBase: UInt64,
        truncated: inout Bool,
        diagnostics: inout [String]
    ) -> [LCMachOSymbolInfo] {
        guard !data.isEmpty else { return [] }
        var results: [LCMachOSymbolInfo] = []
        var stack: [(offset: Int, prefix: String, depth: Int)] = [(0, "", 0)]
        var visitedOffsets = Set<Int>()

        while let frame = stack.popLast() {
            if Task.isCancelled { break }
            if results.count >= maxExports {
                truncated = true
                diagnostics.append("Exports trie capped at \(maxExports) symbols.")
                break
            }
            guard frame.offset >= 0, frame.offset < data.count, frame.depth <= maxTrieDepth else { continue }
            guard visitedOffsets.insert(frame.offset).inserted else { continue }

            var cursor = frame.offset
            guard let rawTerminalSize = readULEB128(data, cursor: &cursor, limit: data.count),
                  let termSize = Int(exactly: rawTerminalSize),
                  termSize <= data.count - cursor else {
                continue
            }
            let childrenStart = cursor + termSize

            if termSize > 0 && !frame.prefix.isEmpty {
                var termCursor = cursor
                let flags = readULEB128(data, cursor: &termCursor, limit: childrenStart) ?? 0
                let kind = flags & 0x03
                let isReexport = (flags & 0x08) != 0
                let isStubAndResolver = (flags & 0x10) != 0
                var address: UInt64 = 0
                if !isReexport {
                    let rawVal = readULEB128(data, cursor: &termCursor, limit: childrenStart) ?? 0
                    if kind == 2 { // EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE (already absolute)
                        address = rawVal
                    } else if isStubAndResolver {
                        address = preferredBase &+ rawVal
                    } else {
                        address = preferredBase &+ rawVal
                    }
                }
                let rawName = frame.prefix
                let demangled = LCDemangler.demangleIfNeeded(rawName)
                results.append(LCMachOSymbolInfo(
                    id: "E:\(rawName):\(address)",
                    rawName: rawName,
                    demangledName: demangled,
                    address: address,
                    scope: .exported,
                    isSwift: LCDemangler.isSwiftMangled(rawName),
                    isObjC: rawName.contains("OBJC_")
                ))
            }

            cursor = childrenStart
            guard cursor < data.count else { continue }
            let childCount = Int(data[cursor])
            cursor += 1

            for _ in 0..<childCount {
                guard cursor < data.count else { break }
                // Scan raw bytes for the actual NUL terminator so cursor never desyncs on invalid UTF-8
                let slice = data[cursor..<data.count]
                guard let nulIdx = slice.firstIndex(of: 0) else { break }
                let edgeBytes = slice[..<nulIdx]
                let edgeLabel = String(decoding: edgeBytes.prefix(512), as: UTF8.self)
                cursor = nulIdx + 1
                guard cursor < data.count,
                      let rawNextOffset = readULEB128(data, cursor: &cursor, limit: data.count),
                      let nextOff = Int(exactly: rawNextOffset),
                      nextOff < data.count else {
                    break
                }
                stack.append((nextOff, frame.prefix + edgeLabel, frame.depth + 1))
            }
        }
        return results
    }

    private static func readULEB128(_ data: Data, cursor: inout Int, limit: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let safeLimit = min(limit, data.count)
        while cursor < safeLimit && shift < 64 {
            let byte = data[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }
}

// MARK: - Bounded Strings Extractor

/// Extracts printable UTF-8/ASCII strings from `__TEXT,__cstring` (and `__const`)
/// with strict byte/count caps and automatic URL/scheme/path/identifier classification.
enum LCMachOStringsParser {
    private static let maxScanBytes: UInt64 = 4 * 1024 * 1024
    private static let maxStrings = 50_000
    private static let minLength = 4

    static func extractStrings(
        context: LCMachOParsedSliceContext,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) throws -> LCMachOStringsResult {
        if context.overview.header.isEncrypted {
            throw LCMachOInspectorError.encryptedBinaryCannotDump
        }

        let scopeRoot = rootURL ?? context.overview.fileURL
        return try LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: context.overview.fileURL)
            let vmMap = context.vmMap
            // Only scan UTF-8/ASCII `__cstring` sections (exclude UTF-16LE `__ustring` from byte NUL splitting)
            let targetSections = vmMap.sections.filter { $0.sectionName == "__cstring" }

            var entries: [LCMachOStringEntry] = []
            var seenValues = Set<String>()
            var diagnostics: [String] = []
            var truncated = false
            var scannedTotal: UInt64 = 0

            for section in targetSections {
                guard section.size > 0, section.fileOffset < vmMap.sliceSize else { continue }
                let remainingBudget = maxScanBytes > scannedTotal ? maxScanBytes - scannedTotal : 0
                if remainingBudget == 0 {
                    truncated = true
                    diagnostics.append("String scan capped at 4 MiB of string data.")
                    break
                }
                let availInSlice = vmMap.sliceSize - section.fileOffset
                let toRead = Int(min(section.size, min(availInSlice, remainingBudget)))
                if UInt64(toRead) < section.size {
                    truncated = true
                    diagnostics.append("Section \(section.sectionName) partially scanned (capped at 4 MiB).")
                }
                guard toRead > 0,
                      let data = try? reader.readSliceData(
                          sliceOffset: vmMap.sliceOffset,
                          sliceSize: vmMap.sliceSize,
                          relativeOffset: section.fileOffset,
                          count: toRead
                      ) else {
                    continue
                }
                scannedTotal += UInt64(data.count)

                data.withUnsafeBytes { raw in
                    guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var start = 0
                    let count = data.count
                    while start < count {
                        if Task.isCancelled { break }
                        if entries.count >= maxStrings {
                            truncated = true
                            diagnostics.append("Extracted strings capped at \(maxStrings) unique entries.")
                            break
                        }
                        var end = start
                        while end < count && bytes[end] != 0 {
                            end += 1
                        }
                        let len = end - start
                        if len >= minLength && len <= 1024 {
                            let slice = Data(bytes: bytes.advanced(by: start), count: len)
                            if let str = String(data: slice, encoding: .utf8),
                               isMeaningfulString(str),
                               seenValues.insert(str).inserted {
                                let fileOff = vmMap.sliceOffset + section.fileOffset + UInt64(start)
                                let vmAddr = section.vmAddress &+ UInt64(start)
                                entries.append(LCMachOStringEntry(
                                    value: str,
                                    fileOffset: fileOff,
                                    vmAddress: vmAddr,
                                    sectionName: section.sectionName,
                                    category: classify(str)
                                ))
                            }
                        }
                        start = end + 1
                    }
                }
            }

            return LCMachOStringsResult(entries: entries, wasTruncated: truncated, diagnostics: diagnostics)
        }
    }

    private static func isMeaningfulString(_ s: String) -> Bool {
        var printable = 0
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value != 0x7F {
                printable += 1
            } else if scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
                return false
            }
        }
        return printable >= minLength
    }

    private static func classify(_ s: String) -> LCMachOStringCategory {
        let lower = s.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("wss://") || lower.hasPrefix("ws://") {
            return .url
        }
        if let range = s.range(of: "://"), range.lowerBound > s.startIndex {
            let scheme = s[..<range.lowerBound]
            if scheme.count <= 24 && scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                return .urlScheme
            }
        }
        if s.hasPrefix("/") || s.hasPrefix("@rpath/") || s.hasPrefix("@executable_path/") || s.hasPrefix("@loader_path/") {
            return .path
        }
        if (s.hasPrefix("com.") || s.hasPrefix("org.") || s.hasPrefix("io.") || s.hasPrefix("net.") || s.hasPrefix("group."))
            && !s.contains(" ") {
            return .identifier
        }
        return .general
    }
}

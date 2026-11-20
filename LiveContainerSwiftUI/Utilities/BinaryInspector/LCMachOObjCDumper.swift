//
//  LCMachOObjCDumper.swift
//  LiveContainerSwiftUI
//
//  On-demand modern Objective-C runtime metadata parser and `.h` header
//  synthesizer. Supports iOS 15–27 `LC_DYLD_CHAINED_FIXUPS`, arm64e pointer
//  decoding, relative 12-byte method lists (indirect & direct selector offsets),
//  properties, ivars, protocols, categories, and Objective-C type encodings.
//

import Foundation

/// Pure nonisolated Objective-C metadata reader and `.h` header formatter.
enum LCMachOObjCDumper {
    private static let maxClasses = 25_000
    private static let maxProtocols = 8_000
    private static let maxCategories = 8_000
    private static let maxEntriesPerList = 4_096

    // objc_class data pointer mask (arm64 / x86_64)
    private static let fastDataMask64: UInt64 = 0x0000_7FFF_FFFF_FFF8
    // method_list_t entsizeAndFlags bits (low 2 bits store isFixedUp / isSorted flags in objc4)
    private static let methodListIsRelative: UInt32 = 0x8000_0000
    private static let methodListHasDirectSelectors: UInt32 = 0x4000_0000
    private static let methodListEntsizeMask: UInt32 = 0x0000_FFFC

    /// Decodes Objective-C classes, protocols, and categories for the given parsed slice.
    static func dumpMetadata(
        context: LCMachOParsedSliceContext,
        rootURL: URL? = nil,
        needsSecurityScope: Bool = false
    ) throws -> LCObjCDumpResult {
        if context.overview.header.isEncrypted {
            throw LCMachOInspectorError.encryptedBinaryCannotDump
        }
        guard context.overview.selectedSlice.is64Bit, !context.overview.selectedSlice.isByteSwapped else {
            throw LCMachOInspectorError.unsupportedArchitecture(context.overview.selectedSlice.architectureName)
        }

        let scopeRoot = rootURL ?? context.overview.fileURL
        return try LCFileExplorerService.withSecurityScope(rootURL: scopeRoot, needsSecurityScope: needsSecurityScope) {
            let reader = try LCBoundedFileReader(url: context.overview.fileURL)
            let vmMap = context.vmMap
            let fixups = context.chainedFixups
            var diagnostics: [String] = []
            var truncated = false

            let classes = parseClasses(
                reader: reader,
                vmMap: vmMap,
                fixups: fixups,
                diagnostics: &diagnostics,
                truncated: &truncated
            )
            let protocols = parseProtocols(
                reader: reader,
                vmMap: vmMap,
                fixups: fixups,
                diagnostics: &diagnostics,
                truncated: &truncated
            )
            let categories = parseCategories(
                reader: reader,
                vmMap: vmMap,
                fixups: fixups,
                diagnostics: &diagnostics,
                truncated: &truncated
            )

            return LCObjCDumpResult(
                classes: classes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                protocols: protocols.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                categories: categories.sorted {
                    if $0.className != $1.className {
                        return $0.className.localizedCaseInsensitiveCompare($1.className) == .orderedAscending
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                },
                diagnostics: diagnostics,
                wasTruncated: truncated
            )
        }
    }

    // MARK: - Section Parsing: Classes

    private static func parseClasses(
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder,
        diagnostics: inout [String],
        truncated: inout Bool
    ) -> [LCObjCClassInfo] {
        let sections = vmMap.sections(named: "__objc_classlist")
        var results: [LCObjCClassInfo] = []
        var visited = Set<UInt64>()

        for section in sections {
            guard section.size >= 8, section.size <= UInt64(LCBoundedFileReader.maxSingleReadBytes) else { continue }
            guard let ptrData = try? reader.readSliceData(
                sliceOffset: vmMap.sliceOffset,
                sliceSize: vmMap.sliceSize,
                relativeOffset: section.fileOffset,
                count: Int(section.size)
            ) else { continue }

            let ptrCount = ptrData.count / 8
            for i in 0..<ptrCount {
                if Task.isCancelled { break }
                if results.count >= maxClasses {
                    truncated = true
                    diagnostics.append("Objective-C class list capped at \(maxClasses) classes.")
                    return results
                }
                guard let rawPtr = ptrData.lcReadUInt64(at: i * 8) else { continue }
                let storageVM = section.vmAddress &+ UInt64(i * 8)
                guard let classVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: storageVM).vmAddress,
                      classVM != 0,
                      visited.insert(classVM).inserted else {
                    continue
                }
                if let cls = parseSingleClass(at: classVM, reader: reader, vmMap: vmMap, fixups: fixups) {
                    results.append(cls)
                }
            }
        }
        return results
    }

    private static func parseSingleClass(
        at classVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> LCObjCClassInfo? {
        guard let classOff = vmMap.fileOffset(forVMAddress: classVM),
              let classData = try? reader.readData(offset: classOff, count: 40) else {
            return nil
        }

        // objc_class_64: isa(0), superclass(8), cache(16..24), bits/data(32)
        let rawIsa = classData.lcReadUInt64(at: 0) ?? 0
        let rawSuper = classData.lcReadUInt64(at: 8) ?? 0
        let rawBits = classData.lcReadUInt64(at: 32) ?? 0
        let isSwiftClass = (rawBits & 0x3) != 0

        // Clear only low 3 Swift-class flag bits BEFORE chained-fixup resolution so arm64e auth/bind upper bits stay intact
        let cleanedDataBits = rawBits & ~UInt64(0x7)
        guard let resolvedRoVM = fixups.resolvePointer(rawValue: cleanedDataBits, atVMAddress: classVM &+ 32).vmAddress,
              let roOff = vmMap.fileOffset(forVMAddress: resolvedRoVM & fastDataMask64),
              let roData = try? reader.readData(offset: roOff, count: 72) else {
            return nil
        }
        let roVM = resolvedRoVM & fastDataMask64

        // class_ro_t_64:
        // 0: flags(u32), 4: instanceStart(u32), 8: instanceSize(u32), 12: reserved(u32)
        // 16: ivarLayout(u64), 24: name(u64), 32: baseMethods(u64), 40: baseProtocols(u64)
        // 48: ivars(u64), 56: weakIvarLayout(u64), 64: baseProperties(u64)
        let instanceSize = roData.lcReadUInt32(at: 8) ?? 0
        let nameRaw = roData.lcReadUInt64(at: 24) ?? 0
        guard let className = readCStringPointer(raw: nameRaw, atVM: roVM &+ 24, reader: reader, vmMap: vmMap, fixups: fixups),
              !className.isEmpty else {
            return nil
        }

        let superclassName = resolveClassNameReference(raw: rawSuper, atVM: classVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups)
        let baseMethodsRaw = roData.lcReadUInt64(at: 32) ?? 0
        let baseProtocolsRaw = roData.lcReadUInt64(at: 40) ?? 0
        let ivarsRaw = roData.lcReadUInt64(at: 48) ?? 0
        let basePropsRaw = roData.lcReadUInt64(at: 64) ?? 0

        let instanceMethods = parseMethodList(rawPtr: baseMethodsRaw, atVM: roVM &+ 32, isClassMethod: false, reader: reader, vmMap: vmMap, fixups: fixups)
        let protocols = parseProtocolListNames(rawPtr: baseProtocolsRaw, atVM: roVM &+ 40, reader: reader, vmMap: vmMap, fixups: fixups)
        let ivars = parseIvarList(rawPtr: ivarsRaw, atVM: roVM &+ 48, reader: reader, vmMap: vmMap, fixups: fixups)
        let properties = parsePropertyList(rawPtr: basePropsRaw, atVM: roVM &+ 64, reader: reader, vmMap: vmMap, fixups: fixups)

        // Metaclass for class methods (`+`)
        var classMethods: [LCObjCMethodInfo] = []
        if let metaVM = fixups.resolvePointer(rawValue: rawIsa, atVMAddress: classVM).vmAddress,
           metaVM != classVM,
           let metaOff = vmMap.fileOffset(forVMAddress: metaVM),
           let metaData = try? reader.readData(offset: metaOff, count: 40) {
            let metaRawBits = (metaData.lcReadUInt64(at: 32) ?? 0) & ~UInt64(0x7)
            if let resolvedMetaRoVM = fixups.resolvePointer(rawValue: metaRawBits, atVMAddress: metaVM &+ 32).vmAddress,
               let metaRoOff = vmMap.fileOffset(forVMAddress: resolvedMetaRoVM & fastDataMask64),
               let metaRoData = try? reader.readData(offset: metaRoOff, count: 40) {
                let metaRoVM = resolvedMetaRoVM & fastDataMask64
                let metaMethodsRaw = metaRoData.lcReadUInt64(at: 32) ?? 0
                classMethods = parseMethodList(rawPtr: metaMethodsRaw, atVM: metaRoVM &+ 32, isClassMethod: true, reader: reader, vmMap: vmMap, fixups: fixups)
            }
        }

        let displayName = LCDemangler.demangleIfNeeded(className)
        return LCObjCClassInfo(
            name: displayName,
            superclassName: superclassName.map(LCDemangler.demangleIfNeeded),
            vmAddress: classVM,
            instanceSize: instanceSize,
            isSwiftClass: isSwiftClass,
            protocols: protocols,
            ivars: ivars,
            properties: properties,
            instanceMethods: instanceMethods,
            classMethods: classMethods
        )
    }

    // MARK: - Section Parsing: Protocols

    private static func parseProtocols(
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder,
        diagnostics: inout [String],
        truncated: inout Bool
    ) -> [LCObjCProtocolInfo] {
        let sections = vmMap.sections(named: "__objc_protolist")
        var results: [LCObjCProtocolInfo] = []
        var visited = Set<UInt64>()

        for section in sections {
            guard section.size >= 8, section.size <= UInt64(LCBoundedFileReader.maxSingleReadBytes) else { continue }
            guard let ptrData = try? reader.readSliceData(
                sliceOffset: vmMap.sliceOffset,
                sliceSize: vmMap.sliceSize,
                relativeOffset: section.fileOffset,
                count: Int(section.size)
            ) else { continue }

            let count = ptrData.count / 8
            for i in 0..<count {
                if Task.isCancelled { break }
                if results.count >= maxProtocols {
                    truncated = true
                    diagnostics.append("Objective-C protocol list capped at \(maxProtocols) protocols.")
                    return results
                }
                guard let rawPtr = ptrData.lcReadUInt64(at: i * 8),
                      let protoVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: section.vmAddress &+ UInt64(i * 8)).vmAddress,
                      protoVM != 0,
                      visited.insert(protoVM).inserted else {
                    continue
                }
                if let proto = parseSingleProtocol(at: protoVM, reader: reader, vmMap: vmMap, fixups: fixups) {
                    results.append(proto)
                }
            }
        }
        return results
    }

    private static func parseSingleProtocol(
        at protoVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> LCObjCProtocolInfo? {
        guard let off = vmMap.fileOffset(forVMAddress: protoVM),
              let data = try? reader.readData(offset: off, count: 72) else {
            return nil
        }
        // protocol_t:
        // 0: isa, 8: name, 16: protocols, 24: instanceMethods, 32: classMethods,
        // 40: optionalInstanceMethods, 48: optionalClassMethods, 56: instanceProperties
        let nameRaw = data.lcReadUInt64(at: 8) ?? 0
        guard let name = readCStringPointer(raw: nameRaw, atVM: protoVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups),
              !name.isEmpty else {
            return nil
        }
        let adopted = parseProtocolListNames(rawPtr: data.lcReadUInt64(at: 16) ?? 0, atVM: protoVM &+ 16, reader: reader, vmMap: vmMap, fixups: fixups)
        let reqInst = parseMethodList(rawPtr: data.lcReadUInt64(at: 24) ?? 0, atVM: protoVM &+ 24, isClassMethod: false, reader: reader, vmMap: vmMap, fixups: fixups)
        let reqClass = parseMethodList(rawPtr: data.lcReadUInt64(at: 32) ?? 0, atVM: protoVM &+ 32, isClassMethod: true, reader: reader, vmMap: vmMap, fixups: fixups)
        let optInst = parseMethodList(rawPtr: data.lcReadUInt64(at: 40) ?? 0, atVM: protoVM &+ 40, isClassMethod: false, reader: reader, vmMap: vmMap, fixups: fixups)
        let optClass = parseMethodList(rawPtr: data.lcReadUInt64(at: 48) ?? 0, atVM: protoVM &+ 48, isClassMethod: true, reader: reader, vmMap: vmMap, fixups: fixups)
        let props = parsePropertyList(rawPtr: data.lcReadUInt64(at: 56) ?? 0, atVM: protoVM &+ 56, reader: reader, vmMap: vmMap, fixups: fixups)

        return LCObjCProtocolInfo(
            name: LCDemangler.demangleIfNeeded(name),
            vmAddress: protoVM,
            adoptedProtocols: adopted,
            properties: props,
            requiredInstanceMethods: reqInst,
            requiredClassMethods: reqClass,
            optionalInstanceMethods: optInst,
            optionalClassMethods: optClass
        )
    }

    // MARK: - Section Parsing: Categories

    private static func parseCategories(
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder,
        diagnostics: inout [String],
        truncated: inout Bool
    ) -> [LCObjCCategoryInfo] {
        let sections = vmMap.sections(named: "__objc_catlist")
        var results: [LCObjCCategoryInfo] = []
        var visited = Set<UInt64>()

        for section in sections {
            guard section.size >= 8, section.size <= UInt64(LCBoundedFileReader.maxSingleReadBytes) else { continue }
            guard let ptrData = try? reader.readSliceData(
                sliceOffset: vmMap.sliceOffset,
                sliceSize: vmMap.sliceSize,
                relativeOffset: section.fileOffset,
                count: Int(section.size)
            ) else { continue }

            let count = ptrData.count / 8
            for i in 0..<count {
                if Task.isCancelled { break }
                if results.count >= maxCategories {
                    truncated = true
                    diagnostics.append("Objective-C category list capped at \(maxCategories) categories.")
                    return results
                }
                guard let rawPtr = ptrData.lcReadUInt64(at: i * 8),
                      let catVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: section.vmAddress &+ UInt64(i * 8)).vmAddress,
                      catVM != 0,
                      visited.insert(catVM).inserted else {
                    continue
                }
                if let cat = parseSingleCategory(at: catVM, reader: reader, vmMap: vmMap, fixups: fixups) {
                    results.append(cat)
                }
            }
        }
        return results
    }

    private static func parseSingleCategory(
        at catVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> LCObjCCategoryInfo? {
        guard let off = vmMap.fileOffset(forVMAddress: catVM),
              let data = try? reader.readData(offset: off, count: 48) else {
            return nil
        }
        // category_t:
        // 0: name, 8: cls, 16: instanceMethods, 24: classMethods, 32: protocols, 40: instanceProperties
        guard let name = readCStringPointer(raw: data.lcReadUInt64(at: 0) ?? 0, atVM: catVM, reader: reader, vmMap: vmMap, fixups: fixups),
              !name.isEmpty else {
            return nil
        }
        let targetClass = resolveClassNameReference(raw: data.lcReadUInt64(at: 8) ?? 0, atVM: catVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups) ?? "NSObject"
        let instMethods = parseMethodList(rawPtr: data.lcReadUInt64(at: 16) ?? 0, atVM: catVM &+ 16, isClassMethod: false, reader: reader, vmMap: vmMap, fixups: fixups)
        let clsMethods = parseMethodList(rawPtr: data.lcReadUInt64(at: 24) ?? 0, atVM: catVM &+ 24, isClassMethod: true, reader: reader, vmMap: vmMap, fixups: fixups)
        let protos = parseProtocolListNames(rawPtr: data.lcReadUInt64(at: 32) ?? 0, atVM: catVM &+ 32, reader: reader, vmMap: vmMap, fixups: fixups)
        let props = parsePropertyList(rawPtr: data.lcReadUInt64(at: 40) ?? 0, atVM: catVM &+ 40, reader: reader, vmMap: vmMap, fixups: fixups)

        return LCObjCCategoryInfo(
            name: name,
            className: LCDemangler.demangleIfNeeded(targetClass),
            vmAddress: catVM,
            protocols: protos,
            properties: props,
            instanceMethods: instMethods,
            classMethods: clsMethods
        )
    }

    // MARK: - Method, Property, Ivar & Protocol List Decoders

    private static func parseMethodList(
        rawPtr: UInt64,
        atVM storageVM: UInt64,
        isClassMethod: Bool,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> [LCObjCMethodInfo] {
        guard rawPtr != 0,
              let listVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: storageVM).vmAddress,
              let listOff = vmMap.fileOffset(forVMAddress: listVM),
              let header = try? reader.readData(offset: listOff, count: 8) else {
            return []
        }

        let entsizeAndFlags = header.lcReadUInt32(at: 0) ?? 0
        let count = Int(min(header.lcReadUInt32(at: 4) ?? 0, UInt32(maxEntriesPerList)))
        guard count > 0 else { return [] }

        let isRelative = (entsizeAndFlags & methodListIsRelative) != 0
        let hasDirectSelectors = (entsizeAndFlags & methodListHasDirectSelectors) != 0
        let entrySize = Int(entsizeAndFlags & methodListEntsizeMask)

        if isRelative {
            let stride = max(entrySize, 12)
            let byteCount = count * stride
            guard byteCount <= LCBoundedFileReader.maxSingleReadBytes,
                  let body = try? reader.readData(offset: listOff + 8, count: byteCount) else {
                return []
            }
            var methods: [LCObjCMethodInfo] = []
            methods.reserveCapacity(count)

            for idx in 0..<count {
                let entryOff = idx * stride
                let entryVM = listVM &+ 8 &+ UInt64(entryOff)
                guard let nameRel = body.lcReadInt32(at: entryOff),
                      let typesRel = body.lcReadInt32(at: entryOff + 4),
                      let impRel = body.lcReadInt32(at: entryOff + 8) else {
                    continue
                }

                let nameTargetVM = addSignedOffset(entryVM, offset: nameRel)
                let typesTargetVM = addSignedOffset(entryVM &+ 4, offset: typesRel)
                let impVM = addSignedOffset(entryVM &+ 8, offset: impRel)

                // iOS 16+ uses direct selector offsets when bit 0x40000000 is set;
                // iOS 14–15 uses indirect pointer to __objc_selrefs
                let selectorName: String?
                if hasDirectSelectors {
                    selectorName = readCStringAtVM(nameTargetVM, reader: reader, vmMap: vmMap)
                } else {
                    if let indirectOff = vmMap.fileOffset(forVMAddress: nameTargetVM),
                       let rawSelPtr = try? reader.readUInt64(offset: indirectOff) {
                        selectorName = readCStringPointer(raw: rawSelPtr, atVM: nameTargetVM, reader: reader, vmMap: vmMap, fixups: fixups)
                            ?? readCStringAtVM(nameTargetVM, reader: reader, vmMap: vmMap)
                    } else {
                        selectorName = readCStringAtVM(nameTargetVM, reader: reader, vmMap: vmMap)
                    }
                }

                guard let selectorName, !selectorName.isEmpty else { continue }
                let typeEncoding = readCStringAtVM(typesTargetVM, reader: reader, vmMap: vmMap) ?? ""
                let formatted = formatMethodDeclaration(name: selectorName, typeEncoding: typeEncoding, isClassMethod: isClassMethod)
                methods.append(LCObjCMethodInfo(
                    name: selectorName,
                    typeEncoding: typeEncoding,
                    isClassMethod: isClassMethod,
                    implementationAddress: impVM,
                    formattedDeclaration: formatted
                ))
            }
            return methods
        } else {
            // Classic 24-byte 64-bit method_t: name(u64), types(u64), imp(u64)
            let stride = max(entrySize, 24)
            let byteCount = count * stride
            guard byteCount <= LCBoundedFileReader.maxSingleReadBytes,
                  let body = try? reader.readData(offset: listOff + 8, count: byteCount) else {
                return []
            }
            var methods: [LCObjCMethodInfo] = []
            methods.reserveCapacity(count)

            for idx in 0..<count {
                let entryOff = idx * stride
                let entryVM = listVM &+ 8 &+ UInt64(entryOff)
                let nameRaw = body.lcReadUInt64(at: entryOff) ?? 0
                let typesRaw = body.lcReadUInt64(at: entryOff + 8) ?? 0
                let impRaw = body.lcReadUInt64(at: entryOff + 16) ?? 0

                guard let selectorName = readCStringPointer(raw: nameRaw, atVM: entryVM, reader: reader, vmMap: vmMap, fixups: fixups),
                      !selectorName.isEmpty else {
                    continue
                }
                let typeEncoding = readCStringPointer(raw: typesRaw, atVM: entryVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups) ?? ""
                let impVM = fixups.resolvePointer(rawValue: impRaw, atVMAddress: entryVM &+ 16).vmAddress ?? 0
                let formatted = formatMethodDeclaration(name: selectorName, typeEncoding: typeEncoding, isClassMethod: isClassMethod)
                methods.append(LCObjCMethodInfo(
                    name: selectorName,
                    typeEncoding: typeEncoding,
                    isClassMethod: isClassMethod,
                    implementationAddress: impVM,
                    formattedDeclaration: formatted
                ))
            }
            return methods
        }
    }

    private static func parsePropertyList(
        rawPtr: UInt64,
        atVM storageVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> [LCObjCPropertyInfo] {
        guard rawPtr != 0,
              let listVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: storageVM).vmAddress,
              let listOff = vmMap.fileOffset(forVMAddress: listVM),
              let header = try? reader.readData(offset: listOff, count: 8) else {
            return []
        }

        let entsize = max(Int(header.lcReadUInt32(at: 0) ?? 16), 16)
        let count = Int(min(header.lcReadUInt32(at: 4) ?? 0, UInt32(maxEntriesPerList)))
        guard count > 0, count * entsize <= LCBoundedFileReader.maxSingleReadBytes,
              let body = try? reader.readData(offset: listOff + 8, count: count * entsize) else {
            return []
        }

        var props: [LCObjCPropertyInfo] = []
        props.reserveCapacity(count)
        for idx in 0..<count {
            let entryOff = idx * entsize
            let entryVM = listVM &+ 8 &+ UInt64(entryOff)
            let nameRaw = body.lcReadUInt64(at: entryOff) ?? 0
            let attrsRaw = body.lcReadUInt64(at: entryOff + 8) ?? 0
            guard let name = readCStringPointer(raw: nameRaw, atVM: entryVM, reader: reader, vmMap: vmMap, fixups: fixups),
                  !name.isEmpty else {
                continue
            }
            let attrs = readCStringPointer(raw: attrsRaw, atVM: entryVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups) ?? ""
            props.append(LCObjCPropertyInfo(
                name: name,
                attributes: attrs,
                formattedDeclaration: formatPropertyDeclaration(name: name, attributes: attrs)
            ))
        }
        return props
    }

    private static func parseIvarList(
        rawPtr: UInt64,
        atVM storageVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> [LCObjCIvarInfo] {
        guard rawPtr != 0,
              let listVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: storageVM).vmAddress,
              let listOff = vmMap.fileOffset(forVMAddress: listVM),
              let header = try? reader.readData(offset: listOff, count: 8) else {
            return []
        }

        let entsize = max(Int(header.lcReadUInt32(at: 0) ?? 32), 32)
        let count = Int(min(header.lcReadUInt32(at: 4) ?? 0, UInt32(maxEntriesPerList)))
        guard count > 0, count * entsize <= LCBoundedFileReader.maxSingleReadBytes,
              let body = try? reader.readData(offset: listOff + 8, count: count * entsize) else {
            return []
        }

        var ivars: [LCObjCIvarInfo] = []
        ivars.reserveCapacity(count)
        for idx in 0..<count {
            let entryOff = idx * entsize
            let entryVM = listVM &+ 8 &+ UInt64(entryOff)
            let offsetPtrRaw = body.lcReadUInt64(at: entryOff) ?? 0
            let nameRaw = body.lcReadUInt64(at: entryOff + 8) ?? 0
            let typeRaw = body.lcReadUInt64(at: entryOff + 16) ?? 0

            guard let name = readCStringPointer(raw: nameRaw, atVM: entryVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups),
                  !name.isEmpty else {
                continue
            }
            let typeEnc = readCStringPointer(raw: typeRaw, atVM: entryVM &+ 16, reader: reader, vmMap: vmMap, fixups: fixups) ?? ""
            var ivarOffset: UInt32 = 0
            if let offVM = fixups.resolvePointer(rawValue: offsetPtrRaw, atVMAddress: entryVM).vmAddress,
               let offFile = vmMap.fileOffset(forVMAddress: offVM) {
                ivarOffset = (try? reader.readUInt32(offset: offFile)) ?? 0
            }

            let decodedType = decodeTypeEncoding(typeEnc)
            let space = decodedType.hasSuffix("*") ? "" : " "
            ivars.append(LCObjCIvarInfo(
                name: name,
                typeEncoding: typeEnc,
                offset: ivarOffset,
                formattedDeclaration: "\(decodedType)\(space)\(name);"
            ))
        }
        return ivars
    }

    private static func parseProtocolListNames(
        rawPtr: UInt64,
        atVM storageVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> [String] {
        guard rawPtr != 0,
              let listVM = fixups.resolvePointer(rawValue: rawPtr, atVMAddress: storageVM).vmAddress,
              let listOff = vmMap.fileOffset(forVMAddress: listVM),
              let countRaw = try? reader.readUInt64(offset: listOff) else {
            return []
        }

        let count = Int(min(countRaw, 256))
        guard count > 0,
              let ptrs = try? reader.readData(offset: listOff + 8, count: count * 8) else {
            return []
        }

        var names: [String] = []
        for idx in 0..<count {
            guard let protoRaw = ptrs.lcReadUInt64(at: idx * 8),
                  let protoVM = fixups.resolvePointer(rawValue: protoRaw, atVMAddress: listVM &+ 8 &+ UInt64(idx * 8)).vmAddress,
                  let protoOff = vmMap.fileOffset(forVMAddress: protoVM),
                  let nameRaw = try? reader.readUInt64(offset: protoOff + 8),
                  let name = readCStringPointer(raw: nameRaw, atVM: protoVM &+ 8, reader: reader, vmMap: vmMap, fixups: fixups),
                  !name.isEmpty else {
                continue
            }
            names.append(LCDemangler.demangleIfNeeded(name))
        }
        return names
    }

    // MARK: - Pointer & Reference Helpers

    private static func resolveClassNameReference(
        raw: UInt64,
        atVM storageVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> String? {
        switch fixups.resolvePointer(rawValue: raw, atVMAddress: storageVM) {
        case .null:
            return nil
        case let .bind(symbolName):
            for prefix in ["_OBJC_CLASS_$_", "OBJC_CLASS_$_", "_OBJC_METACLASS_$_"] {
                if symbolName.hasPrefix(prefix) {
                    return String(symbolName.dropFirst(prefix.count))
                }
            }
            return symbolName.hasPrefix("_") ? String(symbolName.dropFirst()) : symbolName
        case let .rebase(classVM), let .raw(classVM):
            guard let off = vmMap.fileOffset(forVMAddress: classVM),
                  let data = try? reader.readData(offset: off, count: 40) else {
                return nil
            }
            let bits = (data.lcReadUInt64(at: 32) ?? 0) & ~UInt64(0x7)
            guard let resolvedRoVM = fixups.resolvePointer(rawValue: bits, atVMAddress: classVM &+ 32).vmAddress,
                  let roOff = vmMap.fileOffset(forVMAddress: resolvedRoVM & fastDataMask64),
                  let nameRaw = try? reader.readUInt64(offset: roOff + 24) else {
                return nil
            }
            let roVM = resolvedRoVM & fastDataMask64
            return readCStringPointer(raw: nameRaw, atVM: roVM &+ 24, reader: reader, vmMap: vmMap, fixups: fixups)
        }
    }

    private static func readCStringPointer(
        raw: UInt64,
        atVM storageVM: UInt64,
        reader: LCBoundedFileReader,
        vmMap: LCMachOVMMap,
        fixups: LCMachOChainedFixupsDecoder
    ) -> String? {
        guard let vm = fixups.resolvePointer(rawValue: raw, atVMAddress: storageVM).vmAddress else {
            return nil
        }
        return readCStringAtVM(vm, reader: reader, vmMap: vmMap)
    }

    private static func readCStringAtVM(_ vm: UInt64, reader: LCBoundedFileReader, vmMap: LCMachOVMMap) -> String? {
        guard let off = vmMap.fileOffset(forVMAddress: vm) else { return nil }
        return try? reader.readCString(offset: off, maxLength: 512)
    }

    private static func addSignedOffset(_ base: UInt64, offset: Int32) -> UInt64 {
        let delta = Int64(offset)
        return delta >= 0 ? (base &+ UInt64(delta)) : (base &- UInt64(-delta))
    }

    // MARK: - Objective-C Type Encoding & Header Synthesis

    static func formatPropertyDeclaration(name: String, attributes: String) -> String {
        let parts = attributes.split(separator: ",").map(String.init)
        var typeName = "id"
        var modifiers: [String] = []
        var getterName: String?
        var setterName: String?
        var isReadonly = false

        for part in parts {
            if part.hasPrefix("T") {
                typeName = decodeTypeEncoding(String(part.dropFirst()))
            } else if part == "N" {
                modifiers.append("nonatomic")
            } else if part == "C" {
                modifiers.append("copy")
            } else if part == "&" {
                modifiers.append("strong")
            } else if part == "W" {
                modifiers.append("weak")
            } else if part == "R" {
                isReadonly = true
            } else if part.hasPrefix("G") {
                getterName = String(part.dropFirst())
            } else if part.hasPrefix("S") {
                setterName = String(part.dropFirst())
            }
        }
        if isReadonly { modifiers.append("readonly") }
        if let getterName { modifiers.append("getter=\(getterName)") }
        if let setterName { modifiers.append("setter=\(setterName)") }

        let attrBlock = modifiers.isEmpty ? "" : "(\(modifiers.joined(separator: ", "))) "
        let space = typeName.hasSuffix("*") ? "" : " "
        return "@property \(attrBlock)\(typeName)\(space)\(name);"
    }

    static func formatMethodDeclaration(name: String, typeEncoding: String, isClassMethod: Bool) -> String {
        let prefix = isClassMethod ? "+" : "-"
        let parsedTypes = splitMethodTypeEncoding(typeEncoding)
        let returnType = parsedTypes.first ?? "void"
        // Arguments after (returnType, self, _cmd)
        let argTypes = parsedTypes.count > 3 ? Array(parsedTypes.dropFirst(3)) : []

        let selectorParts = name.split(separator: ":", omittingEmptySubsequences: false)
        if !name.contains(":") || selectorParts.count <= 1 {
            return "\(prefix) (\(returnType))\(name);"
        }

        var segments: [String] = []
        let paramCount = selectorParts.count - 1
        for i in 0..<paramCount {
            let part = selectorParts[i]
            let argType = i < argTypes.count ? argTypes[i] : "id"
            segments.append("\(part):(\(argType))arg\(i + 1)")
        }
        return "\(prefix) (\(returnType))\(segments.joined(separator: " "));"
    }

    private static func splitMethodTypeEncoding(_ encoding: String) -> [String] {
        guard !encoding.isEmpty else { return ["id"] }
        var types: [String] = []
        let chars = Array(encoding)
        var i = 0

        while i < chars.count {
            // Skip stack frame size / argument offset digits
            if chars[i].isNumber {
                i += 1
                continue
            }
            let start = i
            advanceOneType(chars, index: &i)
            let token = String(chars[start..<i])
            if !token.isEmpty {
                types.append(decodeTypeEncoding(token))
            }
        }
        return types
    }

    private static func advanceOneType(_ chars: [Character], index i: inout Int) {
        guard i < chars.count else { return }
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V", "A"]
        while i < chars.count && qualifiers.contains(chars[i]) {
            i += 1
        }
        guard i < chars.count else { return }
        let c = chars[i]
        i += 1

        switch c {
        case "@":
            if i < chars.count && chars[i] == "?" {
                i += 1
            } else if i < chars.count && chars[i] == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" { i += 1 }
                if i < chars.count { i += 1 }
            }
        case "^":
            advanceOneType(chars, index: &i)
        case "{", "(", "[":
            let close: Character = (c == "{") ? "}" : (c == "(" ? ")" : "]")
            var depth = 1
            while i < chars.count && depth > 0 {
                if chars[i] == c { depth += 1 }
                else if chars[i] == close { depth -= 1 }
                i += 1
            }
        default:
            break
        }
    }

    static func decodeTypeEncoding(_ raw: String) -> String {
        var enc = raw
        // Strip leading type qualifiers (const, in, inout, out, bycopy, byref, oneway, atomic)
        let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V", "A"]
        var prefix = ""
        while let first = enc.first, qualifiers.contains(first) {
            if first == "r" { prefix = "const " }
            enc.removeFirst()
        }
        guard !enc.isEmpty else { return "id" }

        if enc == "@?" { return "CDUnknownBlockType" }
        if enc == "@" { return "id" }
        if enc.hasPrefix("@\"") && enc.hasSuffix("\"") {
            let inner = String(enc.dropFirst(2).dropLast())
            if inner.hasPrefix("<") && inner.hasSuffix(">") {
                return "id\(inner)"
            }
            if !inner.isEmpty {
                return "\(inner) *"
            }
            return "id"
        }
        if enc.hasPrefix("^") {
            let inner = decodeTypeEncoding(String(enc.dropFirst()))
            if inner == "void" { return "void *" }
            return inner.hasSuffix("*") ? "\(inner)*" : "\(inner) *"
        }
        if enc.hasPrefix("{") && enc.hasSuffix("}") {
            let inner = enc.dropFirst().dropLast()
            let structName = inner.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if !structName.isEmpty && structName != "?" {
                return "struct \(structName)"
            }
            return "struct"
        }

        switch enc {
        case "v": return "\(prefix)void"
        case "B": return "\(prefix)BOOL"
        case "c": return "\(prefix)char"
        case "C": return "\(prefix)unsigned char"
        case "s": return "\(prefix)short"
        case "S": return "\(prefix)unsigned short"
        case "i": return "\(prefix)int"
        case "I": return "\(prefix)unsigned int"
        case "l": return "\(prefix)long"
        case "L": return "\(prefix)unsigned long"
        case "q": return "\(prefix)long long"
        case "Q": return "\(prefix)unsigned long long"
        case "f": return "\(prefix)float"
        case "d": return "\(prefix)double"
        case "*": return "\(prefix)char *"
        case "#": return "Class"
        case ":": return "SEL"
        default: return "\(prefix)id"
        }
    }

    // MARK: - `.h` Header Formatting

    static func renderHeader(for cls: LCObjCClassInfo) -> String {
        var lines: [String] = []
        let superPart = cls.superclassName.map { " : \($0)" } ?? ""
        let protoPart = cls.protocols.isEmpty ? "" : " <\(cls.protocols.joined(separator: ", "))>"
        lines.append("@interface \(cls.name)\(superPart)\(protoPart)")

        if !cls.ivars.isEmpty {
            lines.append("{")
            for ivar in cls.ivars {
                lines.append("    \(ivar.formattedDeclaration)")
            }
            lines.append("}")
        }

        if !cls.properties.isEmpty {
            lines.append("")
            for prop in cls.properties {
                lines.append(prop.formattedDeclaration)
            }
        }

        if !cls.classMethods.isEmpty {
            lines.append("")
            for method in cls.classMethods {
                lines.append(method.formattedDeclaration)
            }
        }

        if !cls.instanceMethods.isEmpty {
            lines.append("")
            for method in cls.instanceMethods {
                lines.append(method.formattedDeclaration)
            }
        }

        lines.append("")
        lines.append("@end")
        return lines.joined(separator: "\n")
    }

    static func renderHeader(for proto: LCObjCProtocolInfo) -> String {
        var lines: [String] = []
        let adopted = proto.adoptedProtocols.isEmpty ? "" : " <\(proto.adoptedProtocols.joined(separator: ", "))>"
        lines.append("@protocol \(proto.name)\(adopted)")

        if !proto.properties.isEmpty {
            lines.append("")
            for prop in proto.properties {
                lines.append(prop.formattedDeclaration)
            }
        }
        if !proto.requiredClassMethods.isEmpty || !proto.requiredInstanceMethods.isEmpty {
            lines.append("")
            for m in proto.requiredClassMethods { lines.append(m.formattedDeclaration) }
            for m in proto.requiredInstanceMethods { lines.append(m.formattedDeclaration) }
        }
        if !proto.optionalClassMethods.isEmpty || !proto.optionalInstanceMethods.isEmpty {
            lines.append("")
            lines.append("@optional")
            for m in proto.optionalClassMethods { lines.append(m.formattedDeclaration) }
            for m in proto.optionalInstanceMethods { lines.append(m.formattedDeclaration) }
        }

        lines.append("")
        lines.append("@end")
        return lines.joined(separator: "\n")
    }

    static func renderHeader(for category: LCObjCCategoryInfo) -> String {
        var lines: [String] = []
        let protos = category.protocols.isEmpty ? "" : " <\(category.protocols.joined(separator: ", "))>"
        lines.append("@interface \(category.className) (\(category.name))\(protos)")

        if !category.properties.isEmpty {
            lines.append("")
            for prop in category.properties { lines.append(prop.formattedDeclaration) }
        }
        if !category.classMethods.isEmpty {
            lines.append("")
            for m in category.classMethods { lines.append(m.formattedDeclaration) }
        }
        if !category.instanceMethods.isEmpty {
            lines.append("")
            for m in category.instanceMethods { lines.append(m.formattedDeclaration) }
        }

        lines.append("")
        lines.append("@end")
        return lines.joined(separator: "\n")
    }

    static func renderCombinedHeader(binaryName: String, dump: LCObjCDumpResult) -> String {
        var out: [String] = [
            "//",
            "//  \(binaryName)-Headers.h",
            "//  Generated by LiveContainer Binary Inspector",
            "//",
            "//  Classes: \(dump.classes.count) | Protocols: \(dump.protocols.count) | Categories: \(dump.categories.count)",
            "//",
            "",
            "#import <Foundation/Foundation.h>",
            "",
            "typedef void (^CDUnknownBlockType)(void);",
            ""
        ]

        if !dump.protocols.isEmpty {
            out.append("// MARK: - Protocols\n")
            for proto in dump.protocols {
                out.append(renderHeader(for: proto))
                out.append("")
            }
        }
        if !dump.classes.isEmpty {
            out.append("// MARK: - Classes\n")
            for cls in dump.classes {
                out.append(renderHeader(for: cls))
                out.append("")
            }
        }
        if !dump.categories.isEmpty {
            out.append("// MARK: - Categories\n")
            for cat in dump.categories {
                out.append(renderHeader(for: cat))
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }
}

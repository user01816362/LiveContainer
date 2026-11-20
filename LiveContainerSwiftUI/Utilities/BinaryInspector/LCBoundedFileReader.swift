//
//  LCBoundedFileReader.swift
//  LiveContainerSwiftUI
//
//  Bounds-checked, overflow-safe POSIX `pread(2)` random-access reader for
//  inspecting Mach-O binaries, container files, and hex pages without loading
//  multi-hundred-megabyte files into heap memory.
//

import Darwin
import Foundation

/// Errors thrown by ``LCBoundedFileReader`` during safe file opening or bounded reads.
enum LCBoundedFileReaderError: LocalizedError, Sendable {
    case cannotOpen(path: String, errno: Int32)
    case notRegularFile(path: String)
    case outOfBounds(offset: UInt64, length: Int, fileSize: UInt64)
    case readExceedsLimit(requested: Int, limit: Int)
    case ioFailed(errno: Int32)
    case unexpectedEOF(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            return "Unable to open '\((path as NSString).lastPathComponent)': \(String(cString: strerror(code)))."
        case let .notRegularFile(path):
            return "'\((path as NSString).lastPathComponent)' is not a regular file."
        case let .outOfBounds(offset, length, fileSize):
            return "Read out of bounds (offset \(offset) + \(length) > file size \(fileSize))."
        case let .readExceedsLimit(requested, limit):
            return "Requested read (\(requested) B) exceeds safety limit (\(limit) B)."
        case let .ioFailed(code):
            return "File read failed: \(String(cString: strerror(code)))."
        case let .unexpectedEOF(expected, actual):
            return "Unexpected end of file (expected \(expected) B, read \(actual) B)."
        }
    }
}

/// Thread-safe, read-only POSIX `pread(2)` file reader with strict bounds and
/// single-read caps designed to prevent Jetsam kills and out-of-bounds crashes.
///
/// `pread(2)` reads at explicit file offsets without mutating the kernel file
/// descriptor offset, making concurrent read-only access from Swift 6 tasks safe.
final class LCBoundedFileReader: @unchecked Sendable {
    /// Maximum number of bytes allowed in a single read call (16 MiB).
    static let maxSingleReadBytes: Int = 16 * 1024 * 1024

    let url: URL
    let fileSize: UInt64
    private let fd: Int32

    /// Opens a regular file read-only with `O_NONBLOCK` so special files (FIFOs,
    /// sockets, devices) can never block the caller.
    init(url: URL) throws {
        self.url = url
        let path = url.path
        let rawFD = open(path, O_RDONLY | O_NONBLOCK)
        guard rawFD >= 0 else {
            throw LCBoundedFileReaderError.cannotOpen(path: path, errno: errno)
        }

        var st = stat()
        guard fstat(rawFD, &st) == 0 else {
            let err = errno
            close(rawFD)
            throw LCBoundedFileReaderError.cannotOpen(path: path, errno: err)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(rawFD)
            throw LCBoundedFileReaderError.notRegularFile(path: path)
        }
        guard st.st_size >= 0 else {
            close(rawFD)
            throw LCBoundedFileReaderError.notRegularFile(path: path)
        }

        self.fd = rawFD
        self.fileSize = UInt64(st.st_size)
    }

    deinit {
        close(fd)
    }

    /// Reads exactly `count` bytes starting at `offset`, throwing if the range
    /// overflows `UInt64`, exceeds `fileSize`, or exceeds `maxSingleReadBytes`.
    func readData(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else {
            throw LCBoundedFileReaderError.outOfBounds(offset: offset, length: count, fileSize: fileSize)
        }
        if count == 0 {
            return Data()
        }
        guard count <= Self.maxSingleReadBytes else {
            throw LCBoundedFileReaderError.readExceedsLimit(requested: count, limit: Self.maxSingleReadBytes)
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= fileSize else {
            throw LCBoundedFileReaderError.outOfBounds(offset: offset, length: count, fileSize: fileSize)
        }

        var buffer = Data(count: count)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while totalRead < count {
                let n = pread(fd, base.advanced(by: totalRead), count - totalRead, off_t(offset) + off_t(totalRead))
                if n > 0 {
                    totalRead += n
                } else if n == 0 {
                    throw LCBoundedFileReaderError.unexpectedEOF(expected: count, actual: totalRead)
                } else if errno == EINTR {
                    continue
                } else {
                    throw LCBoundedFileReaderError.ioFailed(errno: errno)
                }
            }
        }
        return buffer
    }

    /// Reads up to `maxCount` bytes starting at `offset`, clamping cleanly to EOF.
    func readUpTo(offset: UInt64, maxCount: Int) throws -> Data {
        guard maxCount > 0, offset < fileSize else { return Data() }
        let available = fileSize - offset
        let clamped = Int(min(UInt64(min(maxCount, Self.maxSingleReadBytes)), available))
        return try readData(offset: offset, count: clamped)
    }

    /// Reads a NUL-terminated UTF-8/ASCII string starting at `offset`, strictly bounded
    /// by `maxLength` and `fileSize`.
    func readCString(offset: UInt64, maxLength: Int = 512) throws -> String {
        let data = try readUpTo(offset: offset, maxCount: maxLength)
        if let zeroIdx = data.firstIndex(of: 0) {
            return String(decoding: data[..<zeroIdx], as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func readUInt32(offset: UInt64, bigEndian: Bool = false) throws -> UInt32 {
        let data = try readData(offset: offset, count: 4)
        let raw = data.lcReadUInt32(at: 0) ?? 0
        return bigEndian ? raw.bigEndian : UInt32(littleEndian: raw)
    }

    func readUInt64(offset: UInt64, bigEndian: Bool = false) throws -> UInt64 {
        let data = try readData(offset: offset, count: 8)
        let raw = data.lcReadUInt64(at: 0) ?? 0
        return bigEndian ? raw.bigEndian : UInt64(littleEndian: raw)
    }

    func readInt32(offset: UInt64, bigEndian: Bool = false) throws -> Int32 {
        Int32(bitPattern: try readUInt32(offset: offset, bigEndian: bigEndian))
    }

    // MARK: - Fast Mach-O Magic Detection & Bundle Resolution

    /// Known thin and universal (fat) Mach-O magic headers (host little-endian view).
    private static let knownMachOMagics: Set<UInt32> = [
        0xfeedface, // MH_MAGIC
        0xcefaedfe, // MH_CIGAM
        0xfeedfacf, // MH_MAGIC_64
        0xcffaedfe, // MH_CIGAM_64
        0xcafebabe, // FAT_MAGIC
        0xbebafeca, // FAT_CIGAM
        0xcafebabf, // FAT_MAGIC_64
        0xbfbafeca, // FAT_CIGAM_64
    ]

    /// Performs a fast 4-byte `pread(2)` magic check to determine whether `url` is a Mach-O binary.
    static func isMachOFile(at url: URL) -> Bool {
        guard let reader = try? LCBoundedFileReader(url: url), reader.fileSize >= 4 else {
            return false
        }
        guard let magic = try? reader.readUInt32(offset: 0, bigEndian: false) else {
            return false
        }
        // Guard against Java `.class` files which share 0xCAFEBABE (FAT_MAGIC big-endian -> 0xBEBAFECA LE).
        // Real FAT Mach-O binaries have nfat_arch (big-endian bytes 4..7) in 1...64.
        if magic == 0xbebafeca || magic == 0xbfbafeca {
            guard reader.fileSize >= 8,
                  let archCount = try? reader.readUInt32(offset: 4, bigEndian: true),
                  (1...64).contains(archCount) else {
                return false
            }
            return true
        }
        return knownMachOMagics.contains(magic)
    }

    /// Resolves the primary Mach-O executable for a file or bundle (`.app`, `.framework`, `.appex`, `.bundle`),
    /// including `.disabled`-suffixed tweak frameworks.
    static func resolveMachOExecutableURL(for url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        if !isDir.boolValue {
            return isMachOFile(at: url) ? url : nil
        }

        // Check Info.plist -> CFBundleExecutable
        let infoPlistURL = url.appendingPathComponent("Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let execName = plist["CFBundleExecutable"] as? String,
           !execName.isEmpty {
            let candidate = url.appendingPathComponent(execName)
            if isMachOFile(at: candidate) {
                return candidate
            }
        }

        // Fallback for `.framework` / `.framework.disabled` bundles without Info.plist
        var baseName = url.lastPathComponent
        if baseName.hasSuffix(".disabled") {
            baseName = String(baseName.dropLast(".disabled".count))
        }
        let stem = (baseName as NSString).deletingPathExtension
        if !stem.isEmpty {
            let direct = url.appendingPathComponent(stem)
            if isMachOFile(at: direct) {
                return direct
            }
        }

        return nil
    }
}

// MARK: - Unaligned Safe Data Primitives

extension Data {
    func lcReadUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { buf in
            var value: UInt16 = 0
            memcpy(&value, buf.baseAddress!.advanced(by: offset), 2)
            return value
        }
    }

    func lcReadUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { buf in
            var value: UInt32 = 0
            memcpy(&value, buf.baseAddress!.advanced(by: offset), 4)
            return value
        }
    }

    func lcReadInt32(at offset: Int) -> Int32? {
        lcReadUInt32(at: offset).map(Int32.init(bitPattern:))
    }

    func lcReadUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { buf in
            var value: UInt64 = 0
            memcpy(&value, buf.baseAddress!.advanced(by: offset), 8)
            return value
        }
    }

    func lcReadCString(at offset: Int, maxLength: Int = 512) -> String {
        guard offset >= 0, offset < count else { return "" }
        let endLimit = Swift.min(count, offset + maxLength)
        let slice = self[offset..<endLimit]
        if let zeroIdx = slice.firstIndex(of: 0) {
            return String(decoding: slice[..<zeroIdx], as: UTF8.self)
        }
        return String(decoding: slice, as: UTF8.self)
    }
}

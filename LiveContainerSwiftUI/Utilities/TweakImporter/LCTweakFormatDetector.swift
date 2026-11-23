//
//  LCTweakFormatDetector.swift
//  LiveContainerSwiftUI
//
//  Magic-byte file format sniffer and HTTP filename/Content-Disposition resolver
//  so redirected downloads, extensionless release assets, and misnamed archives
//  are classified accurately before extraction.
//

import Foundation

enum LCTweakFormatDetector {
    private nonisolated static let machoMagics: Set<UInt32> = [
        0xfeedfacf, // MH_MAGIC_64
        0xcffaedfe, // MH_CIGAM_64
        0xfeedface, // MH_MAGIC
        0xcefaedfe, // MH_CIGAM
        0xcafebabe, // FAT_MAGIC (note: also Java class, disambiguated below if needed)
        0xbebafeca, // FAT_CIGAM
        0xcafebabf, // FAT_MAGIC_64
        0xbfbafeca  // FAT_CIGAM_64
    ]

    nonisolated static let supportedArchiveExtensions: Set<String> = [
        "zip", "deb", "ipa", "tipa", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2", "lzma"
    ]

    /// Detects the actual format of `url` using file-header magic bytes first,
    /// falling back to path extension when magic bytes are ambiguous.
    nonisolated static func detectFormat(at url: URL, fileManager: FileManager = .default) -> LCTweakSourceFormat {
        var isDir = ObjCBool(false)
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.pathExtension.lowercased() == "framework" ? .framework : .unknown
        }

        let ext = url.pathExtension.lowercased()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return formatFromExtension(ext)
        }
        defer { try? handle.close() }

        let headerData = (try? handle.read(upToCount: 512)) ?? Data()
        if headerData.count >= 4 {
            let b0 = headerData[0], b1 = headerData[1], b2 = headerData[2], b3 = headerData[3]

            // Zstandard frame magic: 28 B5 2F FD
            if b0 == 0x28 && b1 == 0xB5 && b2 == 0x2F && b3 == 0xFD {
                return .zstdUnsupported
            }

            // Debian `ar` archive magic: "!<arch>\n"
            if headerData.count >= 8,
               let arPrefix = String(data: headerData.prefix(8), encoding: .ascii),
               arPrefix == "!<arch>\n" {
                return .deb
            }

            // ZIP / IPA / TIPA magic: PK\x03\x04, PK\x05\x06 (empty zip), PK\x07\x08
            if b0 == 0x50 && b1 == 0x4B && ((b2 == 0x03 && b3 == 0x04) || (b2 == 0x05 && b3 == 0x06) || (b2 == 0x07 && b3 == 0x08)) {
                return (ext == "ipa" || ext == "tipa") ? .ipa : .zip
            }

            // Mach-O thin / fat header
            let magicLE = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
            if machoMagics.contains(magicLE) {
                return .dylib
            }

            // GZip (1F 8B), XZ (FD 37 7A 58 5A 00), BZip2 (42 5A 68)
            if (b0 == 0x1F && b1 == 0x8B) || (b0 == 0x42 && b1 == 0x5A && b2 == 0x68) {
                return .tar
            }
            if headerData.count >= 6,
               headerData[0] == 0xFD, headerData[1] == 0x37, headerData[2] == 0x7A,
               headerData[3] == 0x58, headerData[4] == 0x5A, headerData[5] == 0x00 {
                return .tar
            }
        }

        // POSIX ustar tarball magic at byte offset 257
        if headerData.count >= 262,
           let ustar = String(data: headerData.subdata(in: 257..<262), encoding: .ascii),
           ustar == "ustar" {
            return .tar
        }

        // HTML error / login wall / CDN block page returned instead of binary/archive
        if let textPrefix = String(data: headerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           textPrefix.hasPrefix("<!doctype html") || textPrefix.hasPrefix("<html") || textPrefix.hasPrefix("<?xml") && textPrefix.contains("<html") {
            return .htmlErrorPage
        }

        return formatFromExtension(ext)
    }

    nonisolated static func isZstdCompressed(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic.count == 4 && magic[0] == 0x28 && magic[1] == 0xB5 && magic[2] == 0x2F && magic[3] == 0xFD
    }

    nonisolated static func isArchiveExtension(_ ext: String) -> Bool {
        supportedArchiveExtensions.contains(ext.lowercased())
    }

    /// Resolves a clean filename for a completed URLSession download by combining
    /// RFC 5987 `Content-Disposition`, `URLResponse.suggestedFilename`, final redirected
    /// URL path, and actual magic-byte format sniffing on `localFileURL`.
    nonisolated static func resolveDownloadedFileName(
        response: URLResponse?,
        originalRequest: URLRequest?,
        localFileURL: URL
    ) -> String {
        var candidates: [String] = []

        if let httpResponse = response as? HTTPURLResponse {
            for (rawKey, rawVal) in httpResponse.allHeaderFields {
                if let key = rawKey as? String, key.caseInsensitiveCompare("Content-Disposition") == .orderedSame,
                   let value = rawVal as? String,
                   let parsed = parseContentDispositionFilename(from: value) {
                    candidates.append(parsed)
                }
            }
        }
        if let suggested = response?.suggestedFilename, !suggested.isEmpty {
            candidates.append(suggested)
        }
        if let redirectedName = response?.url?.lastPathComponent, !redirectedName.isEmpty, redirectedName != "/" {
            candidates.append(redirectedName)
        }
        if let origName = originalRequest?.url?.lastPathComponent, !origName.isEmpty, origName != "/" {
            candidates.append(origName)
        }

        let detectedFormat = detectFormat(at: localFileURL)
        let firstUseful = candidates
            .map(sanitizeFileNameComponent)
            .first(where: { !$0.isEmpty && $0 != "download" && $0 != "unknown" })

        var chosen = firstUseful ?? "tweak_download"
        let currentExt = URL(fileURLWithPath: chosen).pathExtension.lowercased()

        // Preserve `.tipa` / `.tar.gz` / `.tar.xz` / `.tar.bz2` / `.tgz` when valid.
        if let preferredExt = detectedFormat.preferredExtension {
            let compatible = isExtension(currentExt, compatibleWith: detectedFormat)
            if !compatible {
                let stem = URL(fileURLWithPath: chosen).deletingPathExtension().lastPathComponent
                let baseStem = (currentExt.isEmpty || currentExt == "bin" || currentExt == "php" || currentExt == "download" || currentExt == "unknown")
                    ? (currentExt.isEmpty ? chosen : stem)
                    : chosen
                chosen = "\(baseStem).\(preferredExt)"
            }
        }
        return chosen
    }

    /// Parses RFC 5987 (`filename*=UTF-8''...`) and quoted (`filename="..."`) Content-Disposition headers.
    nonisolated static func parseContentDispositionFilename(from headerValue: String) -> String? {
        let parts = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Prefer UTF-8 RFC 5987 filename* when present.
        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                var raw = String(part.dropFirst("filename*=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let quoteRange = raw.range(of: "''") {
                    raw = String(raw[quoteRange.upperBound...])
                }
                let decoded = raw.removingPercentEncoding ?? raw
                let sanitized = sanitizeFileNameComponent(decoded)
                if !sanitized.isEmpty {
                    return sanitized
                }
            }
        }

        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("filename=") {
                let raw = String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                let sanitized = sanitizeFileNameComponent(raw)
                if !sanitized.isEmpty {
                    return sanitized
                }
            }
        }

        return nil
    }

    private nonisolated static func sanitizeFileNameComponent(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        return last
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func formatFromExtension(_ ext: String) -> LCTweakSourceFormat {
        switch ext.lowercased() {
        case "dylib": return .dylib
        case "framework": return .framework
        case "deb": return .deb
        case "zip": return .zip
        case "ipa", "tipa": return .ipa
        case "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2", "lzma": return .tar
        case "zst": return .zstdUnsupported
        case "html", "htm": return .htmlErrorPage
        default: return .unknown
        }
    }

    private nonisolated static func isExtension(_ ext: String, compatibleWith format: LCTweakSourceFormat) -> Bool {
        switch format {
        case .dylib: return ext == "dylib"
        case .framework: return ext == "framework"
        case .deb: return ext == "deb"
        case .zip: return ext == "zip"
        case .ipa: return ext == "ipa" || ext == "tipa" || ext == "zip"
        case .tar: return ["tar", "gz", "tgz", "xz", "txz", "bz2", "tbz2", "lzma"].contains(ext)
        case .zstdUnsupported: return ext == "zst"
        case .htmlErrorPage: return ext == "html" || ext == "htm"
        case .unknown: return true
        }
    }
}

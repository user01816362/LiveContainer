# LiveContainer Native File Explorer & Mach-O Binary Inspector

LiveContainer includes a built-in, crash-guarded **File Explorer** and a modern **Mach-O Binary & Tweak Inspector** designed natively for iOS 27 and Swift 6. Both subsystems operate strictly read-only during inspection, perform all I/O off the main actor via bounded POSIX `pread(2)` reads, and integrate directly across installed apps, data containers, and tweak folders.

---

## Architecture Overview

```
LiveContainerSwiftUI/
├── Utilities/
│   ├── BinaryInspector/
│   │   ├── LCBoundedFileReader.swift       # Bounds-checked pread(2) reader & fast Mach-O/bundle resolver
│   │   ├── LCMachOModels.swift             # Immutable Sendable data models for all analysis stages
│   │   ├── LCMachOChainedFixups.swift      # Overflow-safe VMMap + LC_DYLD_CHAINED_FIXUPS pointer decoder
│   │   ├── LCMachOParser.swift             # Hardened Mach-O header/load command/codesign parser & Doctor
│   │   ├── LCMachOObjCDumper.swift         # Modern Objective-C metadata reader & `.h` synthesizer
│   │   ├── LCMachOSwiftAndSymbols.swift    # Swift5 metadata, runtime dlsym demangler, Exports Trie, Symtab, Strings
│   │   └── LCMachOExportService.swift      # `.h`, `Headers.zip`, `.md`, and `.json` report exporter
│   └── FileExplorer/
│       ├── LCFileExplorerModels.swift      # Sendable file entry, plist tree, SQLite, and hex page models
│       └── LCFileExplorerService.swift     # Security-scoped directory, Plist, JSON/text, read-only SQLite, Hex I/O
└── Views/
    ├── FileExplorer/
    │   ├── LCFileExplorerView.swift        # Recursive Liquid Glass file browser with context menu & guards
    │   ├── LCFilePreviewView.swift         # Smart preview dispatcher + 4 KiB random-access Hex Peek
    │   ├── LCPlistViewerView.swift         # Searchable collapsible Plist OutlineGroup + raw XML toggle
    │   └── LCSQLiteViewerView.swift        # Read-only SQLite table & paginated row browser
    └── BinaryInspector/
        ├── LCBinaryInspectorView.swift     # Top-level inspector with bundle target switcher & slice picker
        ├── LCBinaryOverviewSection.swift   # Compatibility Doctor, Hardening badges, Header, CodeSign/Entitlements
        ├── LCBinaryHeadersSection.swift    # ObjC Classes/Protocols/Categories/Hierarchy + Swift types + `.h` viewer
        ├── LCBinaryStructureSection.swift  # Linked Dylibs/@rpath, Segments/Sections (jump-to-hex), Load Commands
        └── LCBinaryDeepDiveSection.swift   # Demangled Symbols/Exports, Categorized Strings, embedded Hex Viewer
```

---

## Built-In File Explorer

### Entry Points
- **App Long-Press Context Menu → Inspect & Files → Browse App Bundle / Browse Container Data**
- **App Settings → Browse App Bundle**
- **Container Settings → Browse Container Files** (supports private, shared App Group, and external security-scoped bookmarked containers; automatically switches to read-only while the container is actively running)
- **Settings → Data Management → Built-In File Explorer** (Private Container, App Group Container, and read-only LiveContainer Bundle)
- **Tweaks Tab → Long-Press any folder or `.framework` → Browse Folder / Bundle**

### Built-In Viewers & Safety Guarantees
- **Property Lists (`.plist`, `.strings`, `.stringsdict`, `.entitlements`)**: Decoded off-main-thread (4 MiB safety cap) into a searchable collapsible tree with one-tap Raw XML toggle.
- **JSON, Logs & Source Files**: Bounded 512 KiB preview with automatic pretty-printing for valid JSON and truncation banner for oversized files.
- **SQLite Databases (`.sqlite`, `.db`, `.storedata`, extensionless SQLite magic)**: Opened strictly read-only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI`) with `?mode=ro` and `?immutable=1` fallback so WAL-mode or read-only containers never fail or mutate on-disk state. Table identifiers are safely quoted and rows paginate in 50-row pages.
- **Images**: Bounded 24 MiB loader with resolution display.
- **Paginated 4 KiB Hex Peek**: Available for every regular file via `pread(2)` with hex/decimal offset jump.
- **Special-File & Symlink Protection**: Uses `O_RDONLY | O_NONBLOCK` and `S_ISREG` verification so sockets, FIFOs, or symlink loops can never hang or crash the app.

---

## Modern Mach-O Binary & Tweak Inspector

### Entry Points
- **App Long-Press Context Menu → Inspect & Files → Inspect Binary & Dump** (opens with target switcher across main executable, embedded `.framework`s, `.dylib`s, and `PlugIns/*.appex`)
- **App Settings → Inspect App Binaries**
- **Tweaks Tab**: Tap any `.dylib` or `.framework` directly, or long-press → **Inspect & Dump Binary** (works for both enabled and `.disabled` tweaks)
- **Export Dylibs & Frameworks Sheet**: Tap the info icon on any row to inspect before exporting
- **File Explorer**: Automatically detects Mach-O binaries via 4-byte magic probe (with Java `.class` exclusion) and offers **Inspect & Dump Binary** in the context menu and preview banner

### Key Capabilities
1. **LiveContainer Compatibility Doctor**
   - Detects FairPlay encryption (`cryptid != 0`) and blocks unsafe metadata decoding with a clear explanation.
   - Evaluates architecture (`arm64`, `arm64e` PAC ABI, 32-bit emulator requirements).
   - Identifies `MH_EXECUTE` vs `MH_DYLIB` LiveContainer guest patch state.
   - Checks `TweakLoader.dylib` linkage vs disabled marker (`0x114514`).
   - Audits linked dylibs and `@rpath`/`@executable_path`/`@loader_path` resolution, highlighting missing embedded frameworks and jailbreak substrate dependencies (`CydiaSubstrate`, `ElleKit`, `libhooker`, `/var/jb`).
   - Parses `LC_CODE_SIGNATURE` (`CS_SuperBlob`, `CS_CodeDirectory`, Team ID, CDHash, CS flags, XML & DER entitlements, CMS blob) and cross-checks live device signature validity.
2. **Modern iOS 15–27 Objective-C & Swift Metadata Engine**
   - Parses `LC_DYLD_CHAINED_FIXUPS` pointer formats (`DYLD_CHAINED_PTR_64`, `DYLD_CHAINED_PTR_64_OFFSET`, `DYLD_CHAINED_PTR_ARM64E*`) and bind ordinal tables so superclasses and selectors resolve cleanly even on modern arm64/arm64e binaries.
   - Decodes both classic 24-byte `method_t` and modern 12-byte relative method lists (including direct selector offsets).
   - Synthesizes clean Objective-C `.h` headers for classes, protocols, and categories, plus an interactive inheritance Hierarchy view.
   - Decodes Swift `__swift5_types`, `__swift5_fieldmd`, and `__swift5_proto` descriptors and demangles Swift & C++ symbols via the host runtime (`swift_demangle` / `__cxa_demangle`).
3. **Exports, Symbols, Strings & Hex**
   - Walks `LC_DYLD_EXPORTS_TRIE` (bounded iterative DFS with cycle protection) alongside bounded `LC_SYMTAB` entries.
   - Extracts and categorizes `__cstring` entries (URLs, URL schemes, paths, reverse-DNS identifiers) with tap-to-jump into the 4 KiB Hex Viewer.
4. **One-Tap Export**
   - Export any individual class/protocol/category `.h`, a combined `-Headers.h`, a full structured `Headers.zip` archive, a Markdown analysis report (`.md`), a JSON report (`.json`), or the raw binary via the iOS share sheet.

---

## Safety & Memory Bounds

| Subsystem | Guard / Cap |
| :--- | :--- |
| Single `pread(2)` read | 16 MiB hard cap, `UInt64` overflow-checked |
| Load command walk | Max 8,192 commands, `cmdsize >= 8`, 4-byte aligned, clamped to slice size |
| ObjC dump | Max 25,000 classes, 8,000 protocols, 8,000 categories, 4,096 members/list |
| Swift metadata | Max 15,000 types, 5,000 protocols, 512 fields/type |
| Symbols & Exports | Max 50,000 exports (depth ≤ 64, visited-offset cycle guard), 100,000 symtab entries |
| Strings scan | Max 4 MiB scanned, 50,000 unique strings |
| File Explorer viewers | Plist 4 MiB, Text/JSON 512 KiB, Image 24 MiB, Hex 4 KiB pages, SQLite 50 rows/page |

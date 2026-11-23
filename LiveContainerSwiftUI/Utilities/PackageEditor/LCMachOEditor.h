//
//  LCMachOEditor.h
//  LiveContainerSwiftUI
//
//  Bounds-checked C/ObjC Mach-O load-command editor for standalone IPA packaging
//  and pre-install dylib/framework injection, removal, path remapping, and
//  code-signature stripping. Zero external runtime dependencies.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Appends an `LC_LOAD_DYLIB` (or `LC_LOAD_WEAK_DYLIB` when `weakLink == YES`)
/// load command across all 64-bit Mach-O slices in `path`, preserving 16 bytes
/// of header headroom when no `LC_CODE_SIGNATURE` exists yet.
/// Returns `nil` on success or an error description on failure.
NSString * _Nullable LCMachOInjectDylibAtPath(NSString *path, NSString *dylibPath, BOOL weakLink);

/// Removes every load command matching any path in `dylibPaths` across all
/// 64-bit Mach-O slices in `path` and compacts the load-command table.
NSString * _Nullable LCMachORemoveDylibsAtPath(NSString *path, NSArray<NSString *> *dylibPaths);

/// Rewrites any dylib dependency load command matching `oldPath` to `newPath`
/// across all 64-bit slices (handling both shorter and longer replacement strings).
NSString * _Nullable LCMachOChangeDylibPathAtPath(NSString *path, NSString *oldPath, NSString *newPath);

/// Sets `LC_ID_DYLIB` install name on a dynamic library (`MH_DYLIB`) across all 64-bit slices.
NSString * _Nullable LCMachOSetDylibIDAtPath(NSString *path, NSString *newInstallName);

/// Ensures `rpath` is present in `LC_RPATH` across all 64-bit slices in `path`.
NSString * _Nullable LCMachOEnsureRPathAtPath(NSString *path, NSString *rpath);

/// Removes `rpath` from `LC_RPATH` across all 64-bit slices in `path`.
NSString * _Nullable LCMachORemoveRPathAtPath(NSString *path, NSString *rpath);

/// Removes `LC_CODE_SIGNATURE` across all 64-bit slices (and truncates trailing
/// signature payload + shrinks `__LINKEDIT` on thin Mach-Os when trailing).
NSString * _Nullable LCMachOStripCodeSignatureAtPath(NSString *path);

NS_ASSUME_NONNULL_END

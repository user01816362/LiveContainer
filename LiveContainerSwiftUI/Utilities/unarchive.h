#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, LCArchiveExtractOptions) {
    LCArchiveExtractOptionNone                 = 0,
    LCArchiveExtractOptionSkipUnsafeLinks      = 1 << 0,
    LCArchiveExtractOptionStripLeadingSlashes  = 1 << 1,
    LCArchiveExtractOptionNormalizePermissions = 1 << 2,
};

extern int extract(NSString* _Nonnull fileToExtract, NSString* _Nonnull extractionPath, NSProgress* _Nullable progress);

/// Extracts an archive using libarchive with configurable symlink/path safety,
/// leading-slash stripping (common in `.deb` tarballs), writable permission normalization,
/// `NSProgress.isCancelled` polling, and explicit error diagnostics.
/// Returns `nil` on success, or a localized error message string on failure.
extern NSString * _Nullable LCExtractArchiveAtPath(
    NSString * _Nonnull fileToExtract,
    NSString * _Nonnull extractionPath,
    LCArchiveExtractOptions options,
    NSProgress * _Nullable progress
);

/// Creates a standard ZIP archive using libarchive with streaming deflate compression.
///
/// Each dictionary in `rootMappings` supports:
/// - `"sourcePath"` (`NSString *`): directory or regular file path to archive
/// - `"archivePrefix"` (`NSString *`, optional): path prefix inside the ZIP (e.g. `"Payload/App.app"`)
/// - `"skipSymlinks"` (`NSNumber *` BOOL, optional): omit symlinks when `@YES`
/// - `"excludedNames"` (`NSArray<NSString *> *`, optional): filenames to exclude at any depth
///
/// Returns `nil` on success, or a localized error message string on failure.
extern NSString * _Nullable LCCreateZipArchive(
    NSString * _Nonnull destinationPath,
    NSArray<NSDictionary<NSString *, id> *> * _Nonnull rootMappings
);

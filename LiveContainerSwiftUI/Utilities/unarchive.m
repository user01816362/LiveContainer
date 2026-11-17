#import "unarchive.h"

#include <sys/stat.h>
#include "archive.h"
#include "archive_entry.h"

static BOOL LCIsResolvedPathWithinRoot(NSString *resolvedPath, NSString *canonicalRoot, NSString *rootPrefix) {
    if (resolvedPath.length == 0 || canonicalRoot.length == 0) {
        return NO;
    }
    return [resolvedPath isEqualToString:canonicalRoot] || [resolvedPath hasPrefix:rootPrefix];
}

static NSString *LCRelativeStringFromCStr(const char *cStr) {
    if (!cStr || cStr[0] == '\0') {
        return nil;
    }
    size_t len = strlen(cStr);
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:cStr length:len];
}

static void LCUpdateProgressFromArchive(struct archive *a, NSProgress *progress, int64_t totalBytes) {
    if (!progress || !a || totalBytes <= 0) {
        return;
    }
    la_int64_t bytesRead = archive_filter_bytes(a, -1);
    int64_t clamped = bytesRead > 0 ? (int64_t)bytesRead : 0;
    if (clamped > totalBytes) {
        clamped = totalBytes;
    }
    if (clamped > progress.completedUnitCount) {
        progress.completedUnitCount = clamped;
    }
}

static int copy_data(struct archive *ar, struct archive *aw, NSProgress *progress, int64_t totalBytes) {
    int r;
    const void *buff;
    size_t size;
    la_int64_t offset;

    for (;;) {
        r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF) {
            LCUpdateProgressFromArchive(ar, progress, totalBytes);
            return ARCHIVE_OK;
        }
        if (r < ARCHIVE_OK) {
            return r;
        }
        la_ssize_t writeResult = archive_write_data_block(aw, buff, size, offset);
        if (writeResult < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(aw));
            return (int)writeResult;
        }
        LCUpdateProgressFromArchive(ar, progress, totalBytes);
    }
}

int extract(NSString *fileToExtract, NSString *extractionPath, NSProgress *progress) {
    if (fileToExtract.length == 0 || extractionPath.length == 0) {
        return 1;
    }

    NSError *dirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:extractionPath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&dirError]) {
        fprintf(stderr, "Failed to create extraction root: %s\n", dirError.localizedDescription.UTF8String);
        return 1;
    }

    NSURL *rootURL = [NSURL fileURLWithPath:extractionPath isDirectory:YES].URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSString *canonicalRoot = rootURL.path;
    if (canonicalRoot.length == 0) {
        return 1;
    }
    NSString *rootPrefix = [canonicalRoot hasSuffix:@"/"] ? canonicalRoot : [canonicalRoot stringByAppendingString:@"/"];

    struct stat st;
    int64_t totalBytes = (stat(fileToExtract.fileSystemRepresentation, &st) == 0 && st.st_size > 0) ? (int64_t)st.st_size : 1;
    if (progress) {
        progress.totalUnitCount = totalBytes;
        progress.completedUnitCount = 0;
    }

    struct archive *a = archive_read_new();
    struct archive *ext = archive_write_disk_new();
    if (!a || !ext) {
        if (a) archive_read_free(a);
        if (ext) archive_write_free(ext);
        return 1;
    }

    int flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_FFLAGS;

    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    int r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        fprintf(stderr, "archive_read_open_filename failed: %s\n", archive_error_string(a) ?: "unknown");
        archive_read_free(a);
        archive_write_free(ext);
        return 1;
    }

    int result = 0;
    struct archive_entry *entry = NULL;

    for (;;) {
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) {
            break;
        }
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(a) ?: "archive_read_next_header warning");
        }
        if (r < ARCHIVE_WARN) {
            result = 1;
            break;
        }

        const char *entryPathC = archive_entry_pathname(entry);
        if (!entryPathC || entryPathC[0] == '\0' || entryPathC[0] == '/') {
            fprintf(stderr, "Rejected invalid archive entry path: %s\n", entryPathC ?: "(null)");
            result = 1;
            break;
        }

        NSString *relPath = LCRelativeStringFromCStr(entryPathC);
        if (relPath.length == 0 || [relPath.pathComponents containsObject:@".."]) {
            fprintf(stderr, "Rejected path traversal archive entry: %s\n", entryPathC);
            result = 1;
            break;
        }

        NSString *candidatePath = [canonicalRoot stringByAppendingPathComponent:relPath];
        NSString *resolvedDest = [NSURL fileURLWithPath:candidatePath].URLByStandardizingPath.path;
        if (!LCIsResolvedPathWithinRoot(resolvedDest, canonicalRoot, rootPrefix)) {
            fprintf(stderr, "Rejected escaping archive path: %s\n", entryPathC);
            result = 1;
            break;
        }

        // Validate symlink targets against the entry's directory so relative framework symlinks work
        // while symlinks escaping canonicalRoot are rejected.
        const char *symlinkC = archive_entry_symlink(entry);
        if (symlinkC && symlinkC[0] != '\0') {
            if (symlinkC[0] == '/') {
                fprintf(stderr, "Rejected absolute symlink target: %s\n", symlinkC);
                result = 1;
                break;
            }
            NSString *symlinkRel = LCRelativeStringFromCStr(symlinkC);
            NSString *parentDir = resolvedDest.stringByDeletingLastPathComponent;
            NSString *resolvedTarget = symlinkRel ? [NSURL fileURLWithPath:[parentDir stringByAppendingPathComponent:symlinkRel]].URLByStandardizingPath.path : nil;
            if (!LCIsResolvedPathWithinRoot(resolvedTarget, canonicalRoot, rootPrefix)) {
                fprintf(stderr, "Rejected escaping symlink target: %s -> %s\n", entryPathC, symlinkC);
                result = 1;
                break;
            }
        }

        // Validate hardlink targets relative to canonicalRoot.
        const char *hardlinkC = archive_entry_hardlink(entry);
        if (hardlinkC && hardlinkC[0] != '\0') {
            if (hardlinkC[0] == '/') {
                fprintf(stderr, "Rejected absolute hardlink target: %s\n", hardlinkC);
                result = 1;
                break;
            }
            NSString *hardlinkRel = LCRelativeStringFromCStr(hardlinkC);
            if (!hardlinkRel || [hardlinkRel.pathComponents containsObject:@".."]) {
                fprintf(stderr, "Rejected invalid hardlink target: %s\n", hardlinkC);
                result = 1;
                break;
            }
            NSString *resolvedHardlink = [NSURL fileURLWithPath:[canonicalRoot stringByAppendingPathComponent:hardlinkRel]].URLByStandardizingPath.path;
            if (!LCIsResolvedPathWithinRoot(resolvedHardlink, canonicalRoot, rootPrefix)) {
                fprintf(stderr, "Rejected escaping hardlink target: %s -> %s\n", entryPathC, hardlinkC);
                result = 1;
                break;
            }
            archive_entry_set_hardlink(entry, resolvedHardlink.fileSystemRepresentation);
        }

        archive_entry_set_pathname(entry, resolvedDest.fileSystemRepresentation);

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext) ?: "archive_write_header warning");
        }
        if (r < ARCHIVE_WARN) {
            result = 1;
            break;
        }

        if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress, totalBytes);
            if (r < ARCHIVE_OK) {
                fprintf(stderr, "%s\n", archive_error_string(ext) ?: "copy_data warning");
            }
            if (r < ARCHIVE_WARN) {
                result = 1;
                break;
            }
        } else {
            LCUpdateProgressFromArchive(a, progress, totalBytes);
        }

        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext) ?: "archive_write_finish_entry warning");
        }
        if (r < ARCHIVE_WARN) {
            result = 1;
            break;
        }
    }

    if (result == 0 && progress) {
        progress.completedUnitCount = totalBytes;
    }

    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);

    return result;
}

#import "unarchive.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
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

// MARK: - Streaming libarchive ZIP Writer

static const NSUInteger kLCMaxZipDepth = 64;
static const size_t kLCZipCopyBufferSize = 64 * 1024;

static NSString *LCTrimSlashes(NSString *path) {
    if (path.length == 0) {
        return @"";
    }
    return [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
}

static BOOL LCShouldSkipEntryName(NSString *name, NSSet<NSString *> *excludedNames) {
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return YES;
    }
    if ([name isEqualToString:@".DS_Store"] || [name isEqualToString:@"__MACOSX"] || [name hasPrefix:@"._"]) {
        return YES;
    }
    if (excludedNames && [excludedNames containsObject:name]) {
        return YES;
    }
    return NO;
}

static BOOL LCIsSafeRelativeSymlinkTarget(NSString *target, NSString *relParentPath) {
    if (target.length == 0 || [target hasPrefix:@"/"]) {
        return NO;
    }
    NSInteger depth = 0;
    for (NSString *comp in relParentPath.pathComponents) {
        if (comp.length > 0 && ![comp isEqualToString:@"."] && ![comp isEqualToString:@"/"]) {
            depth++;
        }
    }
    for (NSString *comp in target.pathComponents) {
        if (comp.length == 0 || [comp isEqualToString:@"."]) {
            continue;
        }
        if ([comp isEqualToString:@".."]) {
            depth--;
            if (depth < 0) {
                return NO;
            }
        } else {
            depth++;
        }
    }
    return YES;
}

static NSString *LCWriteArchiveEntry(
    struct archive *aw,
    NSString *fsPath,
    NSString *archivePath,
    NSString *relPathInsideMapping,
    BOOL skipSymlinks,
    NSSet<NSString *> *excludedNames,
    uint8_t *copyBuffer,
    NSUInteger depth
) {
    if (depth > kLCMaxZipDepth) {
        return [NSString stringWithFormat:@"Directory nesting exceeds maximum depth (%lu) at %@", (unsigned long)kLCMaxZipDepth, relPathInsideMapping];
    }

    const char *cFsPath = fsPath.fileSystemRepresentation;
    if (!cFsPath) {
        return [NSString stringWithFormat:@"Invalid filesystem path: %@", fsPath];
    }

    struct stat st;
    if (lstat(cFsPath, &st) != 0) {
        int err = errno;
        if (err == ENOENT) {
            return nil;
        }
        return [NSString stringWithFormat:@"Unable to inspect %@: %s", fsPath.lastPathComponent, strerror(err)];
    }

    // Skip special files (sockets, FIFOs, device nodes) silently
    if (S_ISSOCK(st.st_mode) || S_ISFIFO(st.st_mode) || S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) {
        return nil;
    }

    if (S_ISLNK(st.st_mode)) {
        if (skipSymlinks || archivePath.length == 0) {
            return nil;
        }
        char linkBuf[PATH_MAX + 1];
        ssize_t linkLen = readlink(cFsPath, linkBuf, PATH_MAX);
        if (linkLen <= 0 || linkLen >= PATH_MAX) {
            return nil;
        }
        linkBuf[linkLen] = '\0';
        NSString *target = [NSFileManager.defaultManager stringWithFileSystemRepresentation:linkBuf length:(NSUInteger)linkLen];
        NSString *relParent = relPathInsideMapping.stringByDeletingLastPathComponent;
        if (!LCIsSafeRelativeSymlinkTarget(target, relParent)) {
            return nil;
        }

        struct archive_entry *entry = archive_entry_new();
        if (!entry) {
            return @"Out of memory allocating archive symlink entry.";
        }
        archive_entry_set_pathname(entry, archivePath.UTF8String);
        archive_entry_set_filetype(entry, AE_IFLNK);
        archive_entry_set_perm(entry, 0777);
        archive_entry_set_mtime(entry, st.st_mtime, 0);
        archive_entry_set_symlink(entry, target.UTF8String);

        int r = archive_write_header(aw, entry);
        archive_entry_free(entry);
        if (r < ARCHIVE_WARN) {
            return [NSString stringWithFormat:@"Failed to write symlink header (%@): %s", archivePath, archive_error_string(aw) ?: "unknown error"];
        }
        int finishR = archive_write_finish_entry(aw);
        if (finishR < ARCHIVE_WARN) {
            return [NSString stringWithFormat:@"Failed to finish symlink entry (%@): %s", archivePath, archive_error_string(aw) ?: "unknown error"];
        }
        return nil;
    }

    if (S_ISREG(st.st_mode)) {
        if (archivePath.length == 0) {
            return @"Regular file archive mapping requires a non-empty archive prefix.";
        }
        int fd = open(cFsPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) {
            int err = errno;
            if (err == ENOENT || err == EPERM || err == EACCES) {
                return nil;
            }
            return [NSString stringWithFormat:@"Failed to open %@: %s", fsPath.lastPathComponent, strerror(err)];
        }
        struct stat fdStat;
        if (fstat(fd, &fdStat) != 0 || !S_ISREG(fdStat.st_mode)) {
            close(fd);
            return nil;
        }

        struct archive_entry *entry = archive_entry_new();
        if (!entry) {
            close(fd);
            return @"Out of memory allocating archive file entry.";
        }
        archive_entry_set_pathname(entry, archivePath.UTF8String);
        archive_entry_set_filetype(entry, AE_IFREG);
        archive_entry_set_perm(entry, fdStat.st_mode & 07777);
        archive_entry_set_size(entry, (la_int64_t)fdStat.st_size);
        archive_entry_set_mtime(entry, fdStat.st_mtime, 0);

        int headerR = archive_write_header(aw, entry);
        archive_entry_free(entry);
        if (headerR < ARCHIVE_WARN) {
            close(fd);
            return [NSString stringWithFormat:@"Failed to write header for %@: %s", archivePath, archive_error_string(aw) ?: "unknown error"];
        }

        off_t remaining = fdStat.st_size;
        while (remaining > 0) {
            size_t toRead = (size_t)(remaining > (off_t)kLCZipCopyBufferSize ? kLCZipCopyBufferSize : (size_t)remaining);
            ssize_t nRead = read(fd, copyBuffer, toRead);
            if (nRead > 0) {
                size_t totalWritten = 0;
                while (totalWritten < (size_t)nRead) {
                    la_ssize_t written = archive_write_data(aw, copyBuffer + totalWritten, (size_t)nRead - totalWritten);
                    if (written < 0) {
                        close(fd);
                        return [NSString stringWithFormat:@"Failed writing %@ to archive: %s", archivePath, archive_error_string(aw) ?: "write error"];
                    }
                    if (written == 0) {
                        close(fd);
                        return [NSString stringWithFormat:@"Unexpected short write archiving %@", archivePath];
                    }
                    totalWritten += (size_t)written;
                }
                remaining -= (off_t)nRead;
            } else if (nRead == 0) {
                break;
            } else if (errno == EINTR) {
                continue;
            } else {
                int err = errno;
                close(fd);
                return [NSString stringWithFormat:@"Failed reading %@: %s", fsPath.lastPathComponent, strerror(err)];
            }
        }
        close(fd);

        int finishR = archive_write_finish_entry(aw);
        if (finishR < ARCHIVE_WARN) {
            return [NSString stringWithFormat:@"Failed finalizing %@: %s", archivePath, archive_error_string(aw) ?: "unknown error"];
        }
        return nil;
    }

    if (S_ISDIR(st.st_mode)) {
        if (archivePath.length > 0) {
            NSString *dirArchivePath = [archivePath hasSuffix:@"/"] ? archivePath : [archivePath stringByAppendingString:@"/"];
            struct archive_entry *entry = archive_entry_new();
            if (!entry) {
                return @"Out of memory allocating archive directory entry.";
            }
            archive_entry_set_pathname(entry, dirArchivePath.UTF8String);
            archive_entry_set_filetype(entry, AE_IFDIR);
            archive_entry_set_perm(entry, st.st_mode & 07777);
            archive_entry_set_mtime(entry, st.st_mtime, 0);

            int headerR = archive_write_header(aw, entry);
            archive_entry_free(entry);
            if (headerR < ARCHIVE_WARN) {
                return [NSString stringWithFormat:@"Failed writing directory %@: %s", dirArchivePath, archive_error_string(aw) ?: "unknown error"];
            }
            int finishR = archive_write_finish_entry(aw);
            if (finishR < ARCHIVE_WARN) {
                return [NSString stringWithFormat:@"Failed finalizing directory %@: %s", dirArchivePath, archive_error_string(aw) ?: "unknown error"];
            }
        }

        DIR *dir = opendir(cFsPath);
        if (!dir) {
            int err = errno;
            if (err == ENOENT || err == EPERM || err == EACCES) {
                return nil;
            }
            return [NSString stringWithFormat:@"Failed to open directory %@: %s", fsPath.lastPathComponent, strerror(err)];
        }

        NSMutableArray<NSString *> *childNames = [NSMutableArray array];
        struct dirent *dp = NULL;
        while ((dp = readdir(dir)) != NULL) {
            NSString *childName = [NSFileManager.defaultManager stringWithFileSystemRepresentation:dp->d_name length:strlen(dp->d_name)];
            if (!LCShouldSkipEntryName(childName, excludedNames)) {
                [childNames addObject:childName];
            }
        }
        closedir(dir);

        [childNames sortUsingSelector:@selector(compare:)];

        for (NSString *childName in childNames) {
            @autoreleasepool {
                NSString *childFsPath = [fsPath stringByAppendingPathComponent:childName];
                NSString *childArchivePath = archivePath.length > 0
                    ? [archivePath stringByAppendingPathComponent:childName]
                    : childName;
                NSString *childRelPath = relPathInsideMapping.length > 0
                    ? [relPathInsideMapping stringByAppendingPathComponent:childName]
                    : childName;

                NSString *childError = LCWriteArchiveEntry(
                    aw,
                    childFsPath,
                    childArchivePath,
                    childRelPath,
                    skipSymlinks,
                    excludedNames,
                    copyBuffer,
                    depth + 1
                );
                if (childError) {
                    return childError;
                }
            }
        }
        return nil;
    }

    return nil;
}

NSString *LCCreateZipArchive(
    NSString *destinationPath,
    NSArray<NSDictionary<NSString *, id> *> *rootMappings
) {
    if (destinationPath.length == 0 || rootMappings.count == 0) {
        return @"Invalid archive destination or empty input mappings.";
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *parentDir = destinationPath.stringByDeletingLastPathComponent;
    NSError *dirError = nil;
    if (parentDir.length > 0 && ![fm createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        return dirError.localizedDescription ?: @"Unable to create archive output directory.";
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }

    uint8_t *copyBuffer = (uint8_t *)malloc(kLCZipCopyBufferSize);
    if (!copyBuffer) {
        return @"Out of memory allocating archive buffer.";
    }

    struct archive *aw = archive_write_new();
    if (!aw) {
        free(copyBuffer);
        return @"Unable to initialize libarchive writer.";
    }

    NSString *errorMessage = nil;
    if (archive_write_set_format_zip(aw) != ARCHIVE_OK) {
        errorMessage = [NSString stringWithFormat:@"Failed to configure ZIP format: %s", archive_error_string(aw) ?: "unknown"];
    } else if (archive_write_zip_set_compression_deflate(aw) != ARCHIVE_OK) {
        errorMessage = [NSString stringWithFormat:@"Failed to enable deflate compression: %s", archive_error_string(aw) ?: "unknown"];
    } else if (archive_write_open_filename(aw, destinationPath.fileSystemRepresentation) != ARCHIVE_OK) {
        errorMessage = [NSString stringWithFormat:@"Failed to create ZIP at %@: %s", destinationPath.lastPathComponent, archive_error_string(aw) ?: "unknown"];
    }

    if (!errorMessage) {
        NSMutableSet<NSString *> *emittedParentDirs = [NSMutableSet set];
        for (NSDictionary<NSString *, id> *mapping in rootMappings) {
            NSString *sourcePath = mapping[@"sourcePath"];
            if (![sourcePath isKindOfClass:NSString.class] || sourcePath.length == 0) {
                errorMessage = @"Archive mapping missing sourcePath.";
                break;
            }
            NSString *rawPrefix = [mapping[@"archivePrefix"] isKindOfClass:NSString.class] ? mapping[@"archivePrefix"] : @"";
            NSString *archivePrefix = LCTrimSlashes(rawPrefix);
            BOOL skipSymlinks = [mapping[@"skipSymlinks"] respondsToSelector:@selector(boolValue)] ? [mapping[@"skipSymlinks"] boolValue] : NO;
            NSArray<NSString *> *excludedArr = [mapping[@"excludedNames"] isKindOfClass:NSArray.class] ? mapping[@"excludedNames"] : nil;
            NSSet<NSString *> *excludedSet = excludedArr ? [NSSet setWithArray:excludedArr] : nil;

            // Emit any intermediate parent directory entries (e.g. "Payload/" before "Payload/App.app/")
            // so strict ZIP directory-table inspectors see every path component explicitly.
            NSArray<NSString *> *prefixComponents = archivePrefix.length > 0 ? archivePrefix.pathComponents : @[];
            if (prefixComponents.count > 1) {
                NSString *running = @"";
                for (NSUInteger i = 0; i + 1 < prefixComponents.count; i++) {
                    NSString *comp = prefixComponents[i];
                    if (comp.length == 0 || [comp isEqualToString:@"/"]) {
                        continue;
                    }
                    running = running.length > 0 ? [running stringByAppendingPathComponent:comp] : comp;
                    NSString *dirPath = [running stringByAppendingString:@"/"];
                    if (![emittedParentDirs containsObject:dirPath]) {
                        [emittedParentDirs addObject:dirPath];
                        struct archive_entry *parentEntry = archive_entry_new();
                        if (!parentEntry) {
                            errorMessage = @"Out of memory allocating parent directory entry.";
                            break;
                        }
                        archive_entry_set_pathname(parentEntry, dirPath.UTF8String);
                        archive_entry_set_filetype(parentEntry, AE_IFDIR);
                        archive_entry_set_perm(parentEntry, 0755);
                        int hdrR = archive_write_header(aw, parentEntry);
                        archive_entry_free(parentEntry);
                        if (hdrR < ARCHIVE_WARN || archive_write_finish_entry(aw) < ARCHIVE_WARN) {
                            errorMessage = [NSString stringWithFormat:@"Failed writing directory %@: %s", dirPath, archive_error_string(aw) ?: "unknown error"];
                            break;
                        }
                    }
                }
                if (errorMessage) {
                    break;
                }
            }

            errorMessage = LCWriteArchiveEntry(
                aw,
                sourcePath,
                archivePrefix,
                @"",
                skipSymlinks,
                excludedSet,
                copyBuffer,
                0
            );
            if (errorMessage) {
                break;
            }
        }
    }

    int closeR = archive_write_close(aw);
    if (!errorMessage && closeR != ARCHIVE_OK) {
        errorMessage = [NSString stringWithFormat:@"Failed to finalize ZIP archive: %s", archive_error_string(aw) ?: "unknown"];
    }
    archive_write_free(aw);
    free(copyBuffer);

    if (errorMessage) {
        [fm removeItemAtPath:destinationPath error:nil];
    }
    return errorMessage;
}

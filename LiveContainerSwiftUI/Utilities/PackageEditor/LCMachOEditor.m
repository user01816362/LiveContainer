//
//  LCMachOEditor.m
//  LiveContainerSwiftUI
//

#import "LCMachOEditor.h"

@import Darwin;
@import MachO;
#import <errno.h>
#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

static inline uint32_t lcEditorRoundUp32(uint32_t value, uint32_t alignment) {
    uint32_t mask = alignment - 1U;
    return (value + mask) & ~mask;
}

static inline uint64_t lcEditorRoundUp64(uint64_t value, uint64_t alignment) {
    uint64_t mask = alignment - 1ULL;
    return (value + mask) & ~mask;
}

static BOOL lcEditorIsDependencyCommand(uint32_t cmd) {
    return cmd == LC_LOAD_DYLIB ||
           cmd == LC_LOAD_WEAK_DYLIB ||
           cmd == LC_REEXPORT_DYLIB ||
           cmd == LC_LOAD_UPWARD_DYLIB ||
           cmd == LC_LAZY_LOAD_DYLIB;
}

static BOOL lcEditorReadLoadCommandString(const struct load_command *cmd,
                                          uint32_t strOffset,
                                          const char * _Nullable * _Nullable outStr,
                                          size_t * _Nullable outMaxLen) {
    if (!cmd || cmd->cmdsize <= strOffset || strOffset < sizeof(struct load_command)) {
        return NO;
    }
    const char *str = (const char *)cmd + strOffset;
    size_t maxLen = (size_t)cmd->cmdsize - (size_t)strOffset;
    size_t actualLen = strnlen(str, maxLen);
    if (actualLen >= maxLen) {
        return NO;
    }
    if (outStr) *outStr = str;
    if (outMaxLen) *outMaxLen = maxLen;
    return YES;
}

static uint32_t lcEditorMinHeaderDataOffset(struct mach_header_64 *header, uint64_t sliceSize) {
    uint32_t minOffset = (sliceSize < UINT32_MAX) ? (uint32_t)sliceSize : UINT32_MAX;
    uint64_t headerBytes = sizeof(struct mach_header_64);
    if (sliceSize < headerBytes || (uint64_t)header->sizeofcmds > sliceSize - headerBytes) {
        return 0;
    }
    uint8_t *cmdPtr = (uint8_t *)header + headerBytes;
    uint8_t *cmdEnd = cmdPtr + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && cmdPtr + sizeof(struct load_command) <= cmdEnd; i++) {
        struct load_command *cmd = (struct load_command *)cmdPtr;
        if (cmd->cmdsize < sizeof(struct load_command) ||
            (cmd->cmdsize & 3U) != 0 ||
            cmdPtr + cmd->cmdsize > cmdEnd) {
            break;
        }
        if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            uint64_t remaining = (uint64_t)seg->cmdsize - sizeof(struct segment_command_64);
            if ((uint64_t)seg->nsects <= remaining / sizeof(struct section_64)) {
                struct section_64 *sects = (struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    if (sects[j].offset > 0 && sects[j].offset < minOffset) {
                        minOffset = sects[j].offset;
                    }
                }
            }
            if (seg->fileoff > 0 && seg->filesize > 0 && seg->fileoff < minOffset) {
                minOffset = (uint32_t)seg->fileoff;
            }
        } else if ((cmd->cmd == LC_ENCRYPTION_INFO_64 || cmd->cmd == LC_ENCRYPTION_INFO) &&
                   cmd->cmdsize >= sizeof(struct encryption_info_command)) {
            struct encryption_info_command *enc = (struct encryption_info_command *)cmd;
            if (enc->cryptoff > 0 && enc->cryptoff < minOffset) {
                minOffset = enc->cryptoff;
            }
        }
        cmdPtr += cmd->cmdsize;
    }
    return minOffset;
}

static void lcEditorCompactRemoveCommand(struct mach_header_64 *header,
                                         uint8_t *cmdPtr,
                                         uint32_t removeSize) {
    uint8_t *firstCmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *cmdEnd = firstCmdPtr + header->sizeofcmds;
    uint8_t *nextCmd = cmdPtr + removeSize;
    size_t tailBytes = (cmdEnd > nextCmd) ? (size_t)(cmdEnd - nextCmd) : 0;
    if (tailBytes > 0) {
        memmove(cmdPtr, nextCmd, tailBytes);
    }
    bzero(firstCmdPtr + header->sizeofcmds - removeSize, removeSize);
    header->ncmds--;
    header->sizeofcmds -= removeSize;
}

static NSString * _Nullable lcEditorResizeCommandString(struct mach_header_64 *header,
                                                        uint64_t sliceSize,
                                                        uint8_t *cmdPtr,
                                                        uint32_t fixedStructSize,
                                                        uint32_t *nameOffsetField,
                                                        const char *newStr) {
    struct load_command *cmd = (struct load_command *)cmdPtr;
    uint32_t oldCmdSize = cmd->cmdsize;
    size_t strLen = strlen(newStr);
    if (strLen > 4096) {
        return @"Replacement path exceeds maximum allowed Mach-O load-command length.";
    }
    uint32_t naturalSize = fixedStructSize + lcEditorRoundUp32((uint32_t)strLen + 1U, 8U);
    uint8_t *firstCmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *cmdEnd = firstCmdPtr + header->sizeofcmds;
    uint8_t *nextCmd = cmdPtr + oldCmdSize;
    size_t tailBytes = (cmdEnd > nextCmd) ? (size_t)(cmdEnd - nextCmd) : 0;

    uint32_t targetCmdSize = oldCmdSize;
    if (naturalSize > oldCmdSize) {
        uint32_t delta = naturalSize - oldCmdSize;
        uint32_t minDataOffset = lcEditorMinHeaderDataOffset(header, sliceSize);
        uint32_t currentEnd = (uint32_t)(sizeof(struct mach_header_64) + header->sizeofcmds);
        uint32_t freeSpace = (minDataOffset > currentEnd) ? (minDataOffset - currentEnd) : 0U;
        if (freeSpace < delta) {
            return [NSString stringWithFormat:@"Insufficient Mach-O header space to expand load command (%u B needed, %u B free).", delta, freeSpace];
        }
        if (tailBytes > 0) {
            memmove(nextCmd + delta, nextCmd, tailBytes);
        }
        header->sizeofcmds += delta;
        targetCmdSize = naturalSize;
    } else if (naturalSize < oldCmdSize) {
        uint32_t delta = oldCmdSize - naturalSize;
        if (tailBytes > 0) {
            memmove(cmdPtr + naturalSize, nextCmd, tailBytes);
        }
        bzero(firstCmdPtr + header->sizeofcmds - delta, delta);
        header->sizeofcmds -= delta;
        targetCmdSize = naturalSize;
    }

    bzero(cmdPtr + sizeof(struct load_command), targetCmdSize - sizeof(struct load_command));
    cmd->cmdsize = targetCmdSize;
    *nameOffsetField = fixedStructSize;
    strlcpy((char *)cmdPtr + fixedStructSize, newStr, targetCmdSize - fixedStructSize);
    return nil;
}

typedef NSString * _Nullable (^LCEditorSliceBlock)(struct mach_header_64 *header,
                                                   uint64_t sliceSize,
                                                   BOOL isFat,
                                                   uint64_t * _Nullable truncateSizeOut);

static NSString * _Nullable lcEditorMutateFile(NSString *path, LCEditorSliceBlock block) {
    if (path.length == 0 || !block) {
        return @"Invalid Mach-O file path.";
    }
    const char *cPath = path.fileSystemRepresentation;
    int fd = open(cPath, O_RDWR, 0600);
    if (fd < 0) {
        return [NSString stringWithFormat:@"Failed to open %@: %s", path.lastPathComponent, strerror(errno)];
    }

    struct stat st = {0};
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        int savedErr = errno;
        close(fd);
        return (st.st_size >= 0 && st.st_size < (off_t)sizeof(struct mach_header_64))
            ? @"File is too small to be a 64-bit Mach-O binary."
            : [NSString stringWithFormat:@"Failed to stat %@: %s", path.lastPathComponent, strerror(savedErr)];
    }

    uint64_t fileSize = (uint64_t)st.st_size;
    void *map = mmap(NULL, (size_t)fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        int savedErr = errno;
        close(fd);
        return [NSString stringWithFormat:@"Failed to map %@: %s", path.lastPathComponent, strerror(savedErr)];
    }

    NSString *resultError = nil;
    uint64_t truncateSize = 0;
    uint32_t magic = *(uint32_t *)map;
    uint32_t mutatedSlices = 0;

    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        BOOL swap = (magic == FAT_CIGAM);
        if (fileSize < sizeof(struct fat_header)) {
            resultError = @"Invalid FAT Mach-O header.";
        } else {
            struct fat_header *fat = (struct fat_header *)map;
            uint32_t nfat = swap ? OSSwapInt32(fat->nfat_arch) : fat->nfat_arch;
            uint64_t maxArchs = (fileSize - sizeof(struct fat_header)) / sizeof(struct fat_arch);
            if (nfat > maxArchs) {
                resultError = @"Corrupted FAT slice table.";
            } else {
                struct fat_arch *archs = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
                for (uint32_t i = 0; i < nfat; i++) {
                    uint64_t sliceOff = swap ? OSSwapInt32(archs[i].offset) : archs[i].offset;
                    uint64_t sliceSize = swap ? OSSwapInt32(archs[i].size) : archs[i].size;
                    if (sliceOff < sizeof(struct fat_header) || sliceOff > fileSize || sliceSize > fileSize - sliceOff || sliceSize < sizeof(struct mach_header_64)) {
                        continue;
                    }
                    struct mach_header_64 *sliceHeader = (struct mach_header_64 *)((uint8_t *)map + sliceOff);
                    if (sliceHeader->magic != MH_MAGIC_64) {
                        continue;
                    }
                    if ((uint64_t)sliceHeader->sizeofcmds > sliceSize - sizeof(struct mach_header_64)) {
                        resultError = @"Corrupted Mach-O load-command region in FAT slice.";
                        break;
                    }
                    NSString *sliceErr = block(sliceHeader, sliceSize, YES, NULL);
                    if (sliceErr) {
                        resultError = sliceErr;
                        break;
                    }
                    mutatedSlices++;
                }
                if (!resultError && mutatedSlices == 0) {
                    resultError = @"No compatible 64-bit Mach-O slices found.";
                }
            }
        }
    } else if (magic == FAT_CIGAM_64 || magic == FAT_MAGIC_64) {
        BOOL swap = (magic == FAT_CIGAM_64);
        if (fileSize < sizeof(struct fat_header)) {
            resultError = @"Invalid FAT64 Mach-O header.";
        } else {
            struct fat_header *fat = (struct fat_header *)map;
            uint32_t nfat = swap ? OSSwapInt32(fat->nfat_arch) : fat->nfat_arch;
            uint64_t maxArchs = (fileSize - sizeof(struct fat_header)) / sizeof(struct fat_arch_64);
            if (nfat > maxArchs) {
                resultError = @"Corrupted FAT64 slice table.";
            } else {
                struct fat_arch_64 *archs = (struct fat_arch_64 *)((uint8_t *)map + sizeof(struct fat_header));
                for (uint32_t i = 0; i < nfat; i++) {
                    uint64_t sliceOff = swap ? OSSwapInt64(archs[i].offset) : archs[i].offset;
                    uint64_t sliceSize = swap ? OSSwapInt64(archs[i].size) : archs[i].size;
                    if (sliceOff < sizeof(struct fat_header) || sliceOff > fileSize || sliceSize > fileSize - sliceOff || sliceSize < sizeof(struct mach_header_64)) {
                        continue;
                    }
                    struct mach_header_64 *sliceHeader = (struct mach_header_64 *)((uint8_t *)map + sliceOff);
                    if (sliceHeader->magic != MH_MAGIC_64) {
                        continue;
                    }
                    if ((uint64_t)sliceHeader->sizeofcmds > sliceSize - sizeof(struct mach_header_64)) {
                        resultError = @"Corrupted Mach-O load-command region in FAT64 slice.";
                        break;
                    }
                    NSString *sliceErr = block(sliceHeader, sliceSize, YES, NULL);
                    if (sliceErr) {
                        resultError = sliceErr;
                        break;
                    }
                    mutatedSlices++;
                }
                if (!resultError && mutatedSlices == 0) {
                    resultError = @"No compatible 64-bit Mach-O slices found.";
                }
            }
        }
    } else if (magic == MH_MAGIC_64) {
        struct mach_header_64 *header = (struct mach_header_64 *)map;
        if ((uint64_t)header->sizeofcmds > fileSize - sizeof(struct mach_header_64)) {
            resultError = @"Corrupted Mach-O load-command region.";
        } else {
            resultError = block(header, fileSize, NO, &truncateSize);
        }
    } else {
        resultError = [NSString stringWithFormat:@"Unsupported or non-64-bit Mach-O binary (%@).", path.lastPathComponent];
    }

    if (!resultError && msync(map, (size_t)fileSize, MS_SYNC) != 0) {
        resultError = [NSString stringWithFormat:@"Failed to sync %@: %s", path.lastPathComponent, strerror(errno)];
    }

    munmap(map, (size_t)fileSize);
    if (!resultError && truncateSize > 0 && truncateSize < fileSize) {
        if (ftruncate(fd, (off_t)truncateSize) != 0) {
            resultError = [NSString stringWithFormat:@"Failed to truncate stripped signature in %@: %s", path.lastPathComponent, strerror(errno)];
        }
    }
    close(fd);
    return resultError;
}

NSString * _Nullable LCMachOInjectDylibAtPath(NSString *path, NSString *dylibPath, BOOL weakLink) {
    if (dylibPath.length == 0) {
        return @"Empty dylib path for injection.";
    }
    const char *targetCStr = dylibPath.UTF8String;
    if (!targetCStr || targetCStr[0] == '\0') {
        return @"Invalid UTF-8 dylib path.";
    }
    size_t targetLen = strlen(targetCStr);
    if (targetLen > 4096) {
        return @"Dylib install path exceeds maximum length.";
    }

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *firstCmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint8_t *cmdPtr = firstCmdPtr;
        uint8_t *cmdEnd = cmdPtr + header->sizeofcmds;
        BOOL hasCodeSig = NO;

        for (uint32_t i = 0; i < header->ncmds && cmdPtr + sizeof(struct load_command) <= cmdEnd; i++) {
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Encountered malformed Mach-O load command.";
            }
            if (cmd->cmd == LC_CODE_SIGNATURE) {
                hasCodeSig = YES;
            } else if (lcEditorIsDependencyCommand(cmd->cmd) && cmd->cmdsize > sizeof(struct dylib_command)) {
                struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
                const char *existingName = NULL;
                if (lcEditorReadLoadCommandString(cmd, dylibCmd->dylib.name.offset, &existingName, NULL) &&
                    strcmp(existingName, targetCStr) == 0) {
                    if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB) {
                        cmd->cmd = weakLink ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB;
                    }
                    return nil;
                }
            }
            cmdPtr += cmd->cmdsize;
        }

        uint32_t cmdSize = (uint32_t)sizeof(struct dylib_command) + lcEditorRoundUp32((uint32_t)targetLen + 1U, 8U);
        uint32_t minDataOffset = lcEditorMinHeaderDataOffset(header, sliceSize);
        uint32_t currentEnd = (uint32_t)(sizeof(struct mach_header_64) + header->sizeofcmds);
        uint32_t freeSpace = (minDataOffset > currentEnd) ? (minDataOffset - currentEnd) : 0U;
        uint32_t reserveBytes = hasCodeSig ? 0U : 16U;
        if (freeSpace < cmdSize + reserveBytes) {
            return [NSString stringWithFormat:@"Insufficient Mach-O header padding in %@ to inject %@ (need %u B, %u B free).",
                    path.lastPathComponent, dylibPath.lastPathComponent, cmdSize + reserveBytes, freeSpace];
        }

        struct dylib_command *newCmd = (struct dylib_command *)((uint8_t *)header + currentEnd);
        bzero(newCmd, cmdSize);
        newCmd->cmd = weakLink ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB;
        newCmd->cmdsize = cmdSize;
        newCmd->dylib.name.offset = sizeof(struct dylib_command);
        newCmd->dylib.timestamp = 2;
        newCmd->dylib.current_version = 0x10000;
        newCmd->dylib.compatibility_version = 0x10000;
        strlcpy((char *)newCmd + newCmd->dylib.name.offset, targetCStr, cmdSize - newCmd->dylib.name.offset);

        header->ncmds += 1;
        header->sizeofcmds += cmdSize;
        return nil;
    });
}

NSString * _Nullable LCMachORemoveDylibsAtPath(NSString *path, NSArray<NSString *> *dylibPaths) {
    if (dylibPaths.count == 0) {
        return nil;
    }
    NSSet<NSString *> *targetSet = [NSSet setWithArray:dylibPaths];

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint32_t remaining = header->ncmds;
        while (remaining > 0) {
            uint8_t *cmdEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
            if (cmdPtr + sizeof(struct load_command) > cmdEnd) {
                return @"Encountered truncated Mach-O load command while removing dylibs.";
            }
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Encountered malformed Mach-O load command while removing dylibs.";
            }
            BOOL shouldRemove = NO;
            if (lcEditorIsDependencyCommand(cmd->cmd) && cmd->cmdsize > sizeof(struct dylib_command)) {
                struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
                const char *existingName = NULL;
                if (lcEditorReadLoadCommandString(cmd, dylibCmd->dylib.name.offset, &existingName, NULL)) {
                    NSString *str = [NSString stringWithUTF8String:existingName];
                    if (str && [targetSet containsObject:str]) {
                        shouldRemove = YES;
                    }
                }
            }
            if (shouldRemove) {
                lcEditorCompactRemoveCommand(header, cmdPtr, cmd->cmdsize);
                remaining--;
                continue;
            }
            cmdPtr += cmd->cmdsize;
            remaining--;
        }
        return nil;
    });
}

NSString * _Nullable LCMachOChangeDylibPathAtPath(NSString *path, NSString *oldPath, NSString *newPath) {
    if (oldPath.length == 0 || newPath.length == 0 || [oldPath isEqualToString:newPath]) {
        return nil;
    }
    const char *oldCStr = oldPath.UTF8String;
    const char *newCStr = newPath.UTF8String;
    if (!oldCStr || !newCStr) {
        return @"Invalid UTF-8 path for dylib rewrite.";
    }

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint32_t remaining = header->ncmds;
        while (remaining > 0) {
            uint8_t *cmdEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
            if (cmdPtr + sizeof(struct load_command) > cmdEnd) {
                return @"Encountered truncated Mach-O load command while renaming dylib.";
            }
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Encountered malformed Mach-O load command while renaming dylib.";
            }
            if (lcEditorIsDependencyCommand(cmd->cmd) && cmd->cmdsize > sizeof(struct dylib_command)) {
                struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
                const char *existingName = NULL;
                if (lcEditorReadLoadCommandString(cmd, dylibCmd->dylib.name.offset, &existingName, NULL) &&
                    strcmp(existingName, oldCStr) == 0) {
                    NSString *resizeErr = lcEditorResizeCommandString(
                        header,
                        sliceSize,
                        cmdPtr,
                        (uint32_t)sizeof(struct dylib_command),
                        &dylibCmd->dylib.name.offset,
                        newCStr
                    );
                    if (resizeErr) {
                        return resizeErr;
                    }
                    cmd = (struct load_command *)cmdPtr;
                }
            }
            cmdPtr += cmd->cmdsize;
            remaining--;
        }
        return nil;
    });
}

NSString * _Nullable LCMachOSetDylibIDAtPath(NSString *path, NSString *newInstallName) {
    if (newInstallName.length == 0) {
        return @"Empty install name.";
    }
    const char *newCStr = newInstallName.UTF8String;
    if (!newCStr) {
        return @"Invalid UTF-8 install name.";
    }

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        if (header->filetype != MH_DYLIB) {
            return nil;
        }
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint32_t remaining = header->ncmds;
        while (remaining > 0) {
            uint8_t *cmdEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
            if (cmdPtr + sizeof(struct load_command) > cmdEnd) {
                break;
            }
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Malformed load command while updating LC_ID_DYLIB.";
            }
            if (cmd->cmd == LC_ID_DYLIB && cmd->cmdsize > sizeof(struct dylib_command)) {
                struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
                return lcEditorResizeCommandString(
                    header,
                    sliceSize,
                    cmdPtr,
                    (uint32_t)sizeof(struct dylib_command),
                    &dylibCmd->dylib.name.offset,
                    newCStr
                );
            }
            cmdPtr += cmd->cmdsize;
            remaining--;
        }
        return nil;
    });
}

NSString * _Nullable LCMachOEnsureRPathAtPath(NSString *path, NSString *rpath) {
    if (rpath.length == 0) {
        return nil;
    }
    const char *rpathCStr = rpath.UTF8String;
    if (!rpathCStr) {
        return @"Invalid UTF-8 RPATH.";
    }
    size_t rpathLen = strlen(rpathCStr);
    if (rpathLen > 4096) {
        return @"RPATH exceeds maximum length.";
    }

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint8_t *cmdEnd = cmdPtr + header->sizeofcmds;
        for (uint32_t i = 0; i < header->ncmds && cmdPtr + sizeof(struct load_command) <= cmdEnd; i++) {
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Malformed load command while checking LC_RPATH.";
            }
            if (cmd->cmd == LC_RPATH && cmd->cmdsize > sizeof(struct rpath_command)) {
                struct rpath_command *rp = (struct rpath_command *)cmd;
                const char *existing = NULL;
                if (lcEditorReadLoadCommandString(cmd, rp->path.offset, &existing, NULL) &&
                    strcmp(existing, rpathCStr) == 0) {
                    return nil;
                }
            }
            cmdPtr += cmd->cmdsize;
        }

        uint32_t cmdSize = (uint32_t)sizeof(struct rpath_command) + lcEditorRoundUp32((uint32_t)rpathLen + 1U, 8U);
        uint32_t minDataOffset = lcEditorMinHeaderDataOffset(header, sliceSize);
        uint32_t currentEnd = (uint32_t)(sizeof(struct mach_header_64) + header->sizeofcmds);
        uint32_t freeSpace = (minDataOffset > currentEnd) ? (minDataOffset - currentEnd) : 0U;
        if (freeSpace < cmdSize) {
            return [NSString stringWithFormat:@"Insufficient header padding in %@ to add LC_RPATH '%@'.", path.lastPathComponent, rpath];
        }

        struct rpath_command *newCmd = (struct rpath_command *)((uint8_t *)header + currentEnd);
        bzero(newCmd, cmdSize);
        newCmd->cmd = LC_RPATH;
        newCmd->cmdsize = cmdSize;
        newCmd->path.offset = sizeof(struct rpath_command);
        strlcpy((char *)newCmd + newCmd->path.offset, rpathCStr, cmdSize - newCmd->path.offset);

        header->ncmds += 1;
        header->sizeofcmds += cmdSize;
        return nil;
    });
}

NSString * _Nullable LCMachORemoveRPathAtPath(NSString *path, NSString *rpath) {
    if (rpath.length == 0) {
        return nil;
    }
    const char *rpathCStr = rpath.UTF8String;
    if (!rpathCStr) {
        return nil;
    }

    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint32_t remaining = header->ncmds;
        while (remaining > 0) {
            uint8_t *cmdEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
            if (cmdPtr + sizeof(struct load_command) > cmdEnd) {
                break;
            }
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Malformed load command while removing LC_RPATH.";
            }
            BOOL match = NO;
            if (cmd->cmd == LC_RPATH && cmd->cmdsize > sizeof(struct rpath_command)) {
                struct rpath_command *rp = (struct rpath_command *)cmd;
                const char *existing = NULL;
                if (lcEditorReadLoadCommandString(cmd, rp->path.offset, &existing, NULL) &&
                    strcmp(existing, rpathCStr) == 0) {
                    match = YES;
                }
            }
            if (match) {
                lcEditorCompactRemoveCommand(header, cmdPtr, cmd->cmdsize);
                remaining--;
                continue;
            }
            cmdPtr += cmd->cmdsize;
            remaining--;
        }
        return nil;
    });
}

NSString * _Nullable LCMachOStripCodeSignatureAtPath(NSString *path) {
    return lcEditorMutateFile(path, ^NSString * _Nullable(struct mach_header_64 *header, uint64_t sliceSize, BOOL isFat, uint64_t * _Nullable truncateSizeOut) {
        uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
        uint32_t remaining = header->ncmds;
        uint32_t sigOffset = 0;
        uint32_t sigSize = 0;
        struct segment_command_64 *linkeditSeg = NULL;

        while (remaining > 0) {
            uint8_t *cmdEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
            if (cmdPtr + sizeof(struct load_command) > cmdEnd) {
                break;
            }
            struct load_command *cmd = (struct load_command *)cmdPtr;
            if (cmd->cmdsize < sizeof(struct load_command) || (cmd->cmdsize & 3U) != 0 || cmdPtr + cmd->cmdsize > cmdEnd) {
                return @"Malformed load command while stripping code signature.";
            }
            if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
                struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
                if (strncmp(seg->segname, "__LINKEDIT", sizeof(seg->segname)) == 0) {
                    linkeditSeg = seg;
                }
            }
            if (cmd->cmd == LC_CODE_SIGNATURE && cmd->cmdsize >= sizeof(struct linkedit_data_command)) {
                struct linkedit_data_command *sigCmd = (struct linkedit_data_command *)cmd;
                sigOffset = sigCmd->dataoff;
                sigSize = sigCmd->datasize;
                lcEditorCompactRemoveCommand(header, cmdPtr, cmd->cmdsize);
                remaining--;
                continue;
            }
            cmdPtr += cmd->cmdsize;
            remaining--;
        }

        if (!isFat &&
            truncateSizeOut != NULL &&
            sigOffset > 0 &&
            sigSize > 0 &&
            (uint64_t)sigOffset + (uint64_t)sigSize == sliceSize &&
            linkeditSeg != NULL &&
            linkeditSeg->fileoff <= sigOffset &&
            linkeditSeg->fileoff + linkeditSeg->filesize == sliceSize) {
            uint64_t newLinkeditSize = (uint64_t)sigOffset - linkeditSeg->fileoff;
            linkeditSeg->filesize = newLinkeditSize;
            linkeditSeg->vmsize = lcEditorRoundUp64(MAX(newLinkeditSize, 1ULL), 0x4000ULL);
            *truncateSizeOut = sigOffset;
        }
        return nil;
    });
}

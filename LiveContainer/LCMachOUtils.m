@import Darwin;
@import Foundation;
@import MachO;
#import "../litehook/src/litehook.h"
#import "LCUtils.h"
#include "dyld_cache_format.h"

static uint32_t rnd32(uint32_t v, uint32_t r) {
    r--;
    return (v + r) & ~r;
}

struct dyld_all_image_infos *_alt_dyld_get_all_image_infos(void) {
    static struct dyld_all_image_infos *result;
    if (result) {
        return result;
    }
    struct task_dyld_info dyld_info;
    mach_vm_address_t image_infos;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t ret;
    ret = task_info(mach_task_self_,
                    TASK_DYLD_INFO,
                    (task_info_t)&dyld_info,
                    &count);
    if (ret != KERN_SUCCESS) {
        return NULL;
    }
    image_infos = dyld_info.all_image_info_addr;
    result = (struct dyld_all_image_infos *)image_infos;
    return result;
}

static uint32_t get_chained_fixups_seg_count(void *macho, struct linkedit_data_command *fixups) {
    printf("[*] Found DYLD_CHAINED_FIXUPS!\n");
    
    if (fixups->dataoff == 0 || fixups->datasize < sizeof(struct dyld_chained_fixups_header)) {
        printf("\t\t[!] Invalid chained fixups payload\n");
        return 0;
    }
    
    off_t fixups_offset = fixups->dataoff;
    struct dyld_chained_fixups_header *header = (struct dyld_chained_fixups_header *)(macho+fixups_offset);
    
    if (header->starts_offset == 0 || header->starts_offset + sizeof(struct dyld_chained_starts_in_image) > fixups->datasize) {
        printf("\t\t[!] No chained starts to patch\n");

        return 0;
    }
    
    off_t starts_offset = fixups_offset + header->starts_offset;
    uint32_t *seg_count = (uint32_t *)(macho+starts_offset);

    return *seg_count;
}


static uint32_t lcMinHeaderDataOffset(struct mach_header_64 *header) {
    uint32_t minOffset = UINT32_MAX;
    uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *cmdEnd = cmdPtr + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && cmdPtr + sizeof(struct load_command) <= cmdEnd; i++) {
        struct load_command *cmd = (struct load_command *)cmdPtr;
        if (cmd->cmdsize < sizeof(struct load_command) || cmdPtr + cmd->cmdsize > cmdEnd) {
            break;
        }
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (seg->cmdsize >= sizeof(struct segment_command_64) + (size_t)seg->nsects * sizeof(struct section_64)) {
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
        } else if (cmd->cmd == LC_ENCRYPTION_INFO_64 || cmd->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *enc = (struct encryption_info_command *)cmd;
            if (enc->cryptoff > 0 && enc->cryptoff < minOffset) {
                minOffset = enc->cryptoff;
            }
        }
        cmdPtr += cmd->cmdsize;
    }
    return minOffset;
}

static bool lcHasRPathCommand(struct mach_header_64 *header, const char *path) {
    uint8_t *cmdPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *cmdEnd = cmdPtr + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && cmdPtr + sizeof(struct load_command) <= cmdEnd; i++) {
        struct load_command *cmd = (struct load_command *)cmdPtr;
        if (cmd->cmdsize < sizeof(struct load_command) || cmdPtr + cmd->cmdsize > cmdEnd) {
            break;
        }
        if (cmd->cmd == LC_RPATH && cmd->cmdsize > sizeof(struct rpath_command)) {
            struct rpath_command *rpath = (struct rpath_command *)cmd;
            uint32_t off = rpath->path.offset;
            if (off >= sizeof(struct rpath_command) && off < cmd->cmdsize) {
                size_t maxLen = cmd->cmdsize - off;
                const char *existing = (const char *)cmd + off;
                if (strnlen(existing, maxLen) < maxLen && strcmp(existing, path) == 0) {
                    return true;
                }
            }
        }
        cmdPtr += cmd->cmdsize;
    }
    return false;
}

static uint32_t insertDylibCommandWithMinSize(uint32_t cmd, const char *path, struct mach_header_64 *header, size_t minCmdSize) {
    const char *name = cmd == LC_ID_DYLIB ? basename((char *)path) : path;
    struct dylib_command *dylib;
    size_t naturalSize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(name) + 1, 8);
    size_t cmdsize = naturalSize > minCmdSize ? naturalSize : minCmdSize;
    if (cmd == LC_ID_DYLIB) {
        // Make this the first load command on the list (like dylibify does), or some UE3 games may break
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (uintptr_t)header);
        memmove((void *)((uintptr_t)dylib + cmdsize), (void *)dylib, header->sizeofcmds);
    } else {
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (uintptr_t)header + header->sizeofcmds);
    }
    bzero(dylib, cmdsize);
    dylib->cmd = cmd;
    dylib->cmdsize = (uint32_t)cmdsize;
    dylib->dylib.name.offset = sizeof(struct dylib_command);
    dylib->dylib.compatibility_version = 0x10000;
    dylib->dylib.current_version = 0x10000;
    dylib->dylib.timestamp = 2;
    strlcpy((char *)dylib + dylib->dylib.name.offset, name, cmdsize - dylib->dylib.name.offset);
    header->ncmds++;
    header->sizeofcmds += dylib->cmdsize;
    return dylib->cmdsize;
}

static void replaceDylinkerWithIDDylibCommand(struct dylinker_command* dylinkerCommand, const char *path) {
    if (!dylinkerCommand || !path) {
        return;
    }
    uint32_t size = dylinkerCommand->cmdsize;
    if (size <= sizeof(struct dylib_command)) {
        return;
    }
    struct dylib_command* newDylibCommand = (struct dylib_command*)dylinkerCommand;
    newDylibCommand->cmd = LC_ID_DYLIB;

    newDylibCommand->dylib.name.offset = sizeof(struct dylib_command);
    newDylibCommand->dylib.compatibility_version = 0x10000;
    newDylibCommand->dylib.current_version = 0x10000;
    newDylibCommand->dylib.timestamp = 2;
    uint32_t nameSize = size - sizeof(struct dylib_command);
    const char* name = basename((char *)path);
    bzero((void *)newDylibCommand + newDylibCommand->dylib.name.offset, nameSize);
    strlcpy((char *)newDylibCommand + newDylibCommand->dylib.name.offset, name, nameSize);
}

static void insertRPathCommand(const char *path, struct mach_header_64 *header) {
    if (!path || !header || header->magic != MH_MAGIC_64) {
        return;
    }
    if (lcHasRPathCommand(header, path)) {
        return;
    }
    size_t cmdsize = sizeof(struct rpath_command) + rnd32((uint32_t)strlen(path) + 1, 8);
    uint32_t minDataOffset = lcMinHeaderDataOffset(header);
    size_t currentEnd = sizeof(struct mach_header_64) + header->sizeofcmds;
    if (minDataOffset == UINT32_MAX || currentEnd > minDataOffset || (minDataOffset - currentEnd) < cmdsize) {
        return;
    }
    struct rpath_command *rpath = (struct rpath_command *)((uintptr_t)header + currentEnd);
    bzero(rpath, cmdsize);
    rpath->cmd = LC_RPATH;
    rpath->cmdsize = (uint32_t)cmdsize;
    rpath->path.offset = sizeof(struct rpath_command);
    strlcpy((char *)rpath + rpath->path.offset, path, cmdsize - rpath->path.offset);
    header->ncmds++;
    header->sizeofcmds += rpath->cmdsize;
}

void LCPatchAddRPath(const char *path, struct mach_header_64 *header) {
    insertRPathCommand("@executable_path/../../Tweaks", header);
    insertRPathCommand("@loader_path", header);
}

int LCPatchExecSlice(const char *path, struct mach_header_64 *header, bool doInject) {
    int ans = 0;
    if (!path || !header || header->magic != MH_MAGIC_64) {
        return ans;
    }
    uint8_t *imageHeaderPtr = (uint8_t *)header + sizeof(struct mach_header_64);
    // Literally convert an executable to a dylib
    header->filetype = MH_DYLIB;
    header->flags |= MH_NO_REEXPORTED_DYLIBS;
    header->flags &= ~MH_PIE;

    BOOL hasDylibCommand = NO;
    struct dylib_command *dylibLoaderCommand = NULL;
    const char *tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib";
    const char *libCppPath = "/usr/lib/libc++.1.dylib";
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    uint8_t *cmdEnd = imageHeaderPtr + header->sizeofcmds;
    struct dylinker_command *dylinkerCommand = NULL;
    bool codeSignatureCommandFound = false;
    uint32_t loadCommandSegCount = 0;
    for (uint32_t i = 0; i < header->ncmds && (uint8_t *)command + sizeof(struct load_command) <= cmdEnd; i++) {
        if (command->cmdsize < sizeof(struct load_command) || (uint8_t *)command + command->cmdsize > cmdEnd) {
            break;
        }
        if (command->cmd == LC_ID_DYLIB) {
            hasDylibCommand = YES;
        } else if (command->cmd == LC_LOAD_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)command;
            if (dylib->dylib.name.offset >= sizeof(struct dylib_command) && dylib->dylib.name.offset < dylib->cmdsize) {
                char *dylibName = (char *)dylib + dylib->dylib.name.offset;
                if (!strncmp(dylibName, tweakLoaderPath, dylib->cmdsize - dylib->dylib.name.offset)) {
                    dylibLoaderCommand = dylib;
                }
            }
        } else if (command->cmd == 0x114514) {
            dylibLoaderCommand = (struct dylib_command *)command;
        } else if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seglc = (struct segment_command_64 *)command;
            loadCommandSegCount++;
            // Patch __PAGEZERO to map just a single zero page, fixing "out of address space"
            if (seglc->vmaddr == 0 && strcmp(SEG_PAGEZERO, seglc->segname) == 0) {
                seglc->vmaddr = 0x100000000 - 0x4000;
                seglc->vmsize = 0x4000;
            }
        } else if (command->cmd == LC_CODE_SIGNATURE) {
            codeSignatureCommandFound = true;
        } else if (command->cmd == LC_LOAD_DYLINKER) {
            dylinkerCommand = (struct dylinker_command *)command;
        } else if (command->cmd == LC_DYLD_CHAINED_FIXUPS) {
            if (loadCommandSegCount != get_chained_fixups_seg_count((void *)header, (struct linkedit_data_command *)command)) {
                ans |= PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH;
            }
        }

        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }

    uint32_t minDataOffset = lcMinHeaderDataOffset(header);
    long freeLoadCommandCountLeft = 0;
    size_t currentCmdEndOffset = sizeof(struct mach_header_64) + header->sizeofcmds;
    if (minDataOffset != UINT32_MAX && minDataOffset >= currentCmdEndOffset) {
        freeLoadCommandCountLeft = (long)(minDataOffset - currentCmdEndOffset);
    }
    size_t tweakLoaderLoadDylibCmdSize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(tweakLoaderPath) + 1, 8);
    if (tweakLoaderLoadDylibCmdSize < 0x48) {
        tweakLoaderLoadDylibCmdSize = 0x48;
    }

    // Insert command priority: LC_CODE_SIGNATURE > LC_ID_DYLIB > LC_LOAD_DYLIB
    if (!codeSignatureCommandFound) {
        freeLoadCommandCountLeft -= 0x10;
    }

    size_t idDylibCommandSize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(basename((char *)path)) + 1, 8);
    if (!hasDylibCommand) {
        if (freeLoadCommandCountLeft >= (long)idDylibCommandSize) {
            freeLoadCommandCountLeft -= (long)idDylibCommandSize;
            uint32_t insertedBytes = insertDylibCommandWithMinSize(LC_ID_DYLIB, path, header, 0);
            // Shifting load commands forward invalidates any earlier load-command pointer
            if (dylibLoaderCommand) {
                dylibLoaderCommand = (struct dylib_command *)((uintptr_t)dylibLoaderCommand + insertedBytes);
            }
        } else if (dylinkerCommand) {
            // #1042 fix: if there's not enough space for LC_ID_DYLIB we reuse LC_LOAD_DYLINKER's space for LC_ID_DYLIB
            replaceDylinkerWithIDDylibCommand(dylinkerCommand, path);
        }
    }

    const char *targetLoaderPath = doInject ? tweakLoaderPath : libCppPath;
    size_t targetLoaderPathLen = strlen(targetLoaderPath) + 1;
    bool handledLoaderCommand = false;
    if (dylibLoaderCommand) {
        uint32_t nameOffset = dylibLoaderCommand->dylib.name.offset;
        if (nameOffset >= sizeof(struct dylib_command) &&
            nameOffset < dylibLoaderCommand->cmdsize &&
            (dylibLoaderCommand->cmdsize - nameOffset) >= targetLoaderPathLen) {
            dylibLoaderCommand->cmd = doInject ? LC_LOAD_DYLIB : 0x114514;
            size_t nameBufSize = dylibLoaderCommand->cmdsize - nameOffset;
            bzero((void *)dylibLoaderCommand + nameOffset, nameBufSize);
            strlcpy((char *)dylibLoaderCommand + nameOffset, targetLoaderPath, nameBufSize);
            handledLoaderCommand = true;
        }
    }
    if (!handledLoaderCommand) {
        // Reserve full TweakLoader command size even when initially disabled so toggling injection later never overflows
        if (freeLoadCommandCountLeft >= (long)tweakLoaderLoadDylibCmdSize) {
            freeLoadCommandCountLeft -= (long)tweakLoaderLoadDylibCmdSize;
            insertDylibCommandWithMinSize(doInject ? LC_LOAD_DYLIB : 0x114514, targetLoaderPath, header, tweakLoaderLoadDylibCmdSize);
        } else {
            // Not enough free space for injecting tweak loader!
            ans |= PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER;
        }
    }

    // Ensure no duplicated dylibs, often caused by incorrect tweak injection
    // https://github.com/LiveContainer/LiveContainer/issues/582
    // https://github.com/apple-oss-distributions/dyld/blob/93bd81f9d7fcf004fcebcb66ec78983882b41e71/mach_o/Header.cpp#L678
    struct load_command *command2 = (struct load_command *)imageHeaderPtr;
    uint8_t *cmdEnd2 = imageHeaderPtr + header->sizeofcmds;
    int depCount = 0;
    const char **depPaths = header->ncmds > 0 ? calloc(header->ncmds, sizeof(char *)) : NULL;
    if (depPaths) {
        for (uint32_t i = 0; i < header->ncmds && (uint8_t *)command2 + sizeof(struct load_command) <= cmdEnd2; i++) {
            if (command2->cmdsize < sizeof(struct load_command) || (uint8_t *)command2 + command2->cmdsize > cmdEnd2) {
                break;
            }
            switch (command2->cmd) {
                case LC_LOAD_DYLIB:
                case LC_LOAD_WEAK_DYLIB:
                case LC_REEXPORT_DYLIB:
                case LC_LOAD_UPWARD_DYLIB: {
                    struct dylib_command *dylibCmd = (struct dylib_command *)command2;
                    uint32_t nameOff = dylibCmd->dylib.name.offset;
                    if (nameOff >= sizeof(struct dylib_command) && nameOff < dylibCmd->cmdsize) {
                        char *loadPath = (char *)command2 + nameOff;
                        bool isDuplicate = false;
                        for (int k = 0; k < depCount; ++k) {
                            if (strcmp(loadPath, depPaths[k]) == 0) {
                                // Replace this duplicated dylib command with an invalid command number
                                command2->cmd = 0x114515;
                                isDuplicate = true;
                                break;
                            }
                        }
                        if (!isDuplicate) {
                            depPaths[depCount++] = loadPath;
                        }
                    }
                    break;
                }
                default:
                    break;
            }
            command2 = (struct load_command *)((uint8_t *)command2 + command2->cmdsize);
        }
        free(depPaths);
    }

    return ans;
}

NSString *LCParseMachO(const char *path, bool readOnly, LCParseMachOCallback callback) {
    NSString *error = nil;
    int fd = open(path, readOnly ? O_RDONLY : O_RDWR, readOnly ? 0400 : 0600);
    if (fd < 0) {
        return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
    }

    struct stat s = {0};
    if (fstat(fd, &s) != 0) {
        error = [NSString stringWithFormat:@"Failed to stat %s: %s", path, strerror(errno)];
        goto cleanup_fd;
    }

    if (s.st_size < (off_t)sizeof(uint32_t)) {
        error = @"Not a Mach-O file";
        goto cleanup_fd;
    }

    void *map = mmap(NULL, (size_t)s.st_size, readOnly ? PROT_READ : (PROT_READ | PROT_WRITE), readOnly ? MAP_PRIVATE : MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        error = [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
        goto cleanup_fd;
    }

    uint64_t fileSize = (uint64_t)s.st_size;
    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM) {
        if (fileSize < sizeof(struct fat_header)) {
            error = @"Not a valid FAT Mach-O file";
            goto cleanup_map;
        }
        // Find compatible slices within mapped bounds
        struct fat_header *header = (struct fat_header *)map;
        uint32_t nfat = OSSwapInt32(header->nfat_arch);
        uint64_t maxArchs = (fileSize - sizeof(struct fat_header)) / sizeof(struct fat_arch);
        if (nfat > maxArchs) {
            error = @"Invalid FAT slice table";
            goto cleanup_map;
        }
        struct fat_arch *arch = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
        for (uint32_t i = 0; i < nfat; i++) {
            uint64_t sliceOff = OSSwapInt32(arch[i].offset);
            uint64_t sliceSize = OSSwapInt32(arch[i].size);
            int cputype = OSSwapInt32(arch[i].cputype);
            if (sliceOff >= sizeof(struct fat_header) &&
                sliceOff <= fileSize &&
                sliceSize <= fileSize - sliceOff &&
                sliceSize >= sizeof(struct mach_header) &&
                (cputype != CPU_TYPE_ARM64 || sliceSize >= sizeof(struct mach_header_64))) {
                if (cputype == CPU_TYPE_ARM64 || cputype == CPU_TYPE_ARM) {
                    callback(path, (struct mach_header_64 *)((uint8_t *)map + sliceOff), fd, map);
                }
            }
        }
    } else if ((magic == MH_MAGIC_64 && fileSize >= sizeof(struct mach_header_64)) ||
               (magic == MH_MAGIC && fileSize >= sizeof(struct mach_header))) {
        callback(path, (struct mach_header_64 *)map, fd, map);
    } else {
        error = @"Not a Mach-O file";
        goto cleanup_map;
    }

    if (!readOnly && msync(map, (size_t)s.st_size, MS_SYNC) != 0) {
        error = [NSString stringWithFormat:@"Failed to sync %s: %s", path, strerror(errno)];
    }

cleanup_map:
    munmap(map, (size_t)s.st_size);
cleanup_fd:
    close(fd);
    return error;
}

NSString *LCPatchMachOFixupARM64eSlice(const char *path) {
    int fd = open(path, O_RDWR, 0600);
    if (fd < 0) {
        return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
    }
    struct stat s = {0};
    if (fstat(fd, &s) != 0) {
        close(fd);
        return [NSString stringWithFormat:@"Failed to stat %s: %s", path, strerror(errno)];
    }
    if (s.st_size < (off_t)sizeof(uint32_t)) {
        close(fd);
        return nil;
    }
    void *map = mmap(NULL, (size_t)s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
    }

    uint64_t fileSize = (uint64_t)s.st_size;
    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM && fileSize >= sizeof(struct fat_header)) {
        // Find arm64e slice without CPU_SUBTYPE_LIB64
        struct fat_header *fatHeader = (struct fat_header *)map;
        uint32_t nfat = OSSwapInt32(fatHeader->nfat_arch);
        uint64_t maxArchs = (fileSize - sizeof(struct fat_header)) / sizeof(struct fat_arch);
        uint32_t count = nfat < maxArchs ? nfat : (uint32_t)maxArchs;
        struct fat_arch *arch = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
        for (uint32_t i = 0; i < count; i++) {
            uint32_t cpuType = OSSwapInt32(arch[i].cputype);
            uint32_t subType = OSSwapInt32(arch[i].cpusubtype);
            uint64_t sliceOff = OSSwapInt32(arch[i].offset);
            if (cpuType == CPU_TYPE_ARM64 &&
                (subType & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E &&
                !(subType & CPU_SUBTYPE_LIB64) &&
                sliceOff <= fileSize &&
                sizeof(struct mach_header_64) <= fileSize - sliceOff) {
                struct mach_header_64 *header = (struct mach_header_64 *)((uint8_t *)map + sliceOff);
                header->cpusubtype |= CPU_SUBTYPE_LIB64;
                arch[i].cpusubtype = OSSwapInt32(header->cpusubtype);
                break;
            }
        }
    } else if (magic == MH_MAGIC_64 && fileSize >= sizeof(struct mach_header_64)) {
        struct mach_header_64 *header = (struct mach_header_64 *)map;
        if (header->cputype == CPU_TYPE_ARM64 &&
            (header->cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E &&
            !(header->cpusubtype & CPU_SUBTYPE_LIB64)) {
            header->cpusubtype |= CPU_SUBTYPE_LIB64;
        }
    }

    if (msync(map, (size_t)s.st_size, MS_SYNC) != 0) {
        munmap(map, (size_t)s.st_size);
        close(fd);
        return [NSString stringWithFormat:@"Failed to sync %s: %s", path, strerror(errno)];
    }
    munmap(map, (size_t)s.st_size);
    close(fd);
    return nil;
}

void LCPatchAppBundleFixupARM64eSlice(NSURL *bundleURL) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:bundleURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *fileURL in enumerator) {
        if ([fileURL.pathExtension isEqualToString:@"dylib"]) {
            LCPatchMachOFixupARM64eSlice(fileURL.path.fileSystemRepresentation);
        } else if ([fileURL.pathExtension isEqualToString:@"framework"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[fileURL URLByAppendingPathComponent:@"Info.plist"]];
            NSString *executableName = info[@"CFBundleExecutable"];
            if(!executableName) {
                executableName = fileURL.lastPathComponent.stringByDeletingPathExtension;
            }
            NSURL *executableURL = [fileURL URLByAppendingPathComponent:executableName];
            LCPatchMachOFixupARM64eSlice(executableURL.path.fileSystemRepresentation);
        }
    }
}

void LCChangeMachOUUID(struct mach_header_64 *header) {
    struct load_command *command = (struct load_command *)(header + 1);
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_UUID) {
            struct uuid_command *uuidCmd = (struct uuid_command *)command;
            // let's add the first byte by 1
            uuidCmd->uuid[0] += 1;
            break;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
}

const uint8_t* LCGetMachOUUID(struct mach_header_64 *header) {
    if (!header) return NULL;
    if(*(uint32_t*)header != 0x646c7964) { // dyld
        // Find load commands
        const struct load_command* command = (const struct load_command*)(header + 1);
        
        // Iterate through load commands to find LC_SYMTAB
        for(uint32_t i = 0; i < header->ncmds; i++) {
            if(command->cmd == LC_UUID) {
                return ((const struct uuid_command*)command)->uuid;
            }
            command = (const struct load_command*)((void *)command + command->cmdsize);
        }
        return NULL;
    } else {
        struct dyld_cache_header* dsc_header = (struct dyld_cache_header*)header;
        return dsc_header->uuid;
    }
}

bool LCIsMachOEncrypted(struct mach_header_64 *header) {
    size_t size = header->cputype==CPU_TYPE_ARM64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    struct load_command *command = (struct load_command *)((uint64_t)header + size);
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_ENCRYPTION_INFO || command->cmd == LC_ENCRYPTION_INFO_64) {
            return ((struct encryption_info_command *)command)->cryptid != 0;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    return NO;
}

mach_header_u *LCGetLoadedImageHeader(int i0, const char* name);
void *getDyldBase(void);

uint64_t LCFindSymbolOffset(const char *basePath, const char *symbol) {
#if !TARGET_OS_SIMULATOR
    const char *path = basePath;
#else
    char path[PATH_MAX];
    const char *rootPath = getenv("DYLD_ROOT_PATH") ?: "";
    snprintf(path, sizeof(path), "%s%s", rootPath, basePath);
#endif
    struct mach_header_64 *loadedHeader = (strcmp(basePath, "/usr/lib/dyld") == 0)
        ? (struct mach_header_64 *)getDyldBase()
        : (struct mach_header_64 *)LCGetLoadedImageHeader(0, basePath);
    const uint8_t *targetUUID = loadedHeader ? LCGetMachOUUID(loadedHeader) : NULL;

    __block uint64_t offset = 0;
    LCParseMachO(path, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if (offset != 0 || header->cputype != CPU_TYPE_ARM64) return;
        if (targetUUID) {
            const uint8_t *sliceUUID = LCGetMachOUUID(header);
            if (sliceUUID && memcmp(sliceUUID, targetUUID, 16) != 0) {
                return;
            }
        }
        void *result = litehook_find_symbol_file(header, symbol);
        if (result) {
            offset = (uint64_t)result - (uint64_t)header;
        }
    });
    NSCAssert(offset != 0, @"Failed to find symbol %s in %s", symbol, path);
    return offset;
}

mach_header_u *LCGetLoadedImageHeader(int i0, const char* name) {
    if(!name) {
        return NULL;
    }
    size_t nameLen = strlen(name);
    for(uint32_t i = i0; i < _dyld_image_count(); ++i) {
        const char* imgName = _dyld_get_image_name(i);
        if(!imgName) {
            continue;
        }
        size_t imgLen = strlen(imgName);
        // cover simulator path as well without unsigned underflow
        if(imgLen >= nameLen && strcmp(imgName + (imgLen - nameLen), name) == 0) {
            return (struct mach_header_64*)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

#if TARGET_OS_SIMULATOR
// Make it init first on simulator to find dyld_sim
__attribute__((constructor))
#endif
void *getDyldBase(void) {
    static void *dyldBase = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dyldBase = (void *)_alt_dyld_get_all_image_infos()->dyldImageLoadAddress;
    });
#if !TARGET_OS_SIMULATOR
    return dyldBase;
#else
    static void *dyldSimBase = NULL;
    if(!dyldSimBase) {
        __block size_t textSize = 0;
        LCParseMachO("/usr/lib/dyld", true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            if(header->cputype != CPU_TYPE_ARM64) return;
            getsegmentdata(header, SEG_TEXT, &textSize);
        });
        NSArray *callStack = [NSThread callStackReturnAddresses];
        for(NSNumber *addr in callStack.reverseObjectEnumerator) {
            // the first addresss outside of dyld's text is dyld_sim
            uintptr_t addrValue = addr.unsignedLongLongValue;
            if(addrValue < (uintptr_t)dyldBase || addrValue >= (uintptr_t)dyldBase + textSize) {
                dyldSimBase = (void *)(addrValue & ~PAGE_MASK);
                while (((mach_header_u *)dyldSimBase)->magic != MH_MAGIC_64) {
                    dyldSimBase -= PAGE_SIZE;
                }
                break;
            }
        }
    }
    return dyldSimBase;
#endif
}

struct code_signature_command {
    uint32_t    cmd;
    uint32_t    cmdsize;
    uint32_t    dataoff;
    uint32_t    datasize;
};

// from zsign
struct ui_CS_BlobIndex {
    uint32_t type;                    /* type of entry */
    uint32_t offset;                /* offset of entry */
};

struct ui_CS_SuperBlob {
    uint32_t magic;                    /* magic number */
    uint32_t length;                /* total length of SuperBlob */
    uint32_t count;                    /* number of index entries following */
    //CS_BlobIndex index[];            /* (count) entries */
    /* followed by Blobs in no particular order as indicated by offsets in index */
};

struct ui_CS_blob {
    uint32_t magic;
    uint32_t length;
};


struct code_signature_command* findSignatureCommand(struct mach_header_64* header) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    struct code_signature_command* codeSignCommand = 0;
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_CODE_SIGNATURE) {
            codeSignCommand = (struct code_signature_command*)command;
            break;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    return codeSignCommand;
}

NSString* getEntitlementXML(struct mach_header_64* header, void** entitlementXMLPtrOut) {
    struct code_signature_command* codeSignCommand = findSignatureCommand(header);

    if(!codeSignCommand) {
        return @"Unable to find LC_CODE_SIGNATURE command.";
    }
    uint32_t dataSize = codeSignCommand->datasize;
    if (dataSize < sizeof(struct ui_CS_SuperBlob)) {
        return @"CodeSign superblob truncated.";
    }
    struct ui_CS_SuperBlob* blob = (void*)header + codeSignCommand->dataoff;
    if(blob->magic != OSSwapInt32(0xfade0cc0)) {
        return [NSString stringWithFormat:@"CodeSign blob magic mismatch %8x.", blob->magic];
    }
    uint32_t blobCount = OSSwapInt32(blob->count);
    uint32_t maxBlobs = (dataSize - (uint32_t)sizeof(struct ui_CS_SuperBlob)) / (uint32_t)sizeof(struct ui_CS_BlobIndex);
    if (blobCount > maxBlobs) {
        return @"CodeSign blob index count out of bounds.";
    }
    struct ui_CS_BlobIndex* entitlementBlobIndex = 0;
    struct ui_CS_BlobIndex* nowIndex = (void*)blob + sizeof(struct ui_CS_SuperBlob);
    for(uint32_t i = 0; i < blobCount; i++) {
        if(OSSwapInt32(nowIndex->type) == 5) {
            entitlementBlobIndex = nowIndex;
            break;
        }
        nowIndex = (void*)nowIndex + sizeof(struct ui_CS_BlobIndex);
    }
    if(entitlementBlobIndex == 0) {
        return @"[LC] entitlement blob index not found.";
    }
    uint32_t entOffset = OSSwapInt32(entitlementBlobIndex->offset);
    if (entOffset > dataSize || dataSize - entOffset < sizeof(struct ui_CS_blob)) {
        return @"Entitlement blob offset out of bounds.";
    }
    struct ui_CS_blob* entitlementBlob = (void*)blob + entOffset;
    if(entitlementBlob->magic != OSSwapInt32(0xfade7171)) {
        return [NSString stringWithFormat:@"EntitlementBlob magic mismatch %8x.", entitlementBlob->magic];
    }
    uint32_t entLength = OSSwapInt32(entitlementBlob->length);
    if (entLength < sizeof(struct ui_CS_blob) || entLength > dataSize - entOffset) {
        return @"Entitlement blob length out of bounds.";
    }
    uint32_t xmlLength = entLength - (uint32_t)sizeof(struct ui_CS_blob);
    void* xmlPtr = (void*)entitlementBlob + sizeof(struct ui_CS_blob);
    
    if(entitlementXMLPtrOut) {
        *entitlementXMLPtrOut = xmlPtr;
    }

    // entitlement xml in executable don't have \0 so we have to copy it first
    char* xmlString = malloc((size_t)xmlLength + 1);
    if (!xmlString) {
        return @"Out of memory allocating entitlement XML.";
    }
    memcpy(xmlString, xmlPtr, xmlLength);
    xmlString[xmlLength] = 0;

    NSString* ans = [NSString stringWithUTF8String:xmlString];
    free(xmlString);
    return ans;
}

bool checkCodeSignature(const char* path) {
    __block bool checked = false;
    __block bool ans = false;
    LCParseMachO(path, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if(checked || header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        checked = true;
        
        struct code_signature_command* codeSignatureCommand = findSignatureCommand(header);
        if(!codeSignatureCommand) {
            return;
        }
        off_t sliceOffset = (void*)header - filePtr;
        fsignatures_t siginfo;
        siginfo.fs_file_start = sliceOffset;
        siginfo.fs_blob_start = (void*)(long)(codeSignatureCommand->dataoff);
        siginfo.fs_blob_size  = codeSignatureCommand->datasize;
        int addFileSigsReault = fcntl(fd, F_ADDFILESIGS_RETURN, &siginfo);
        if ( addFileSigsReault == -1 ) {
            ans = false;
            return;
        }
        
        fchecklv_t checkInfo;
        char     messageBuffer[512];
        messageBuffer[0]                = '\0';
        checkInfo.lv_error_message_size = sizeof(messageBuffer);
        checkInfo.lv_error_message      = messageBuffer;
        checkInfo.lv_file_start= sliceOffset;
        int checkLVresult = fcntl(fd, F_CHECK_LV, &checkInfo);
        
        if (checkLVresult == 0) {
            ans = true;
            return;
        } else {
            ans = false;
            return;
        }
    });
    return ans;
}

NSString* getExecutableEntitlementXML(NSString* path) {
    __block NSString* ans = @"Failed to find main executable?";
    // it seems the debug build messes the code signature region up, so we search the executable file on the disk instead.
    LCParseMachO(path.UTF8String, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        ans = getEntitlementXML(header, 0);
    });
    return ans;
}

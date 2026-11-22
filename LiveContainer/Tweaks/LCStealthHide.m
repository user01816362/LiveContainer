//
//  LCStealthHide.m
//  LiveContainer
//
//  Multi-layer stealth cloaking for injected LiveContainer and TweakLoader
//  images. Masks dyld enumeration, dladdr image resolution, ObjC runtime image
//  lists, Mach VM region path queries, NSBundle discovery, and sanitized
//  DYLD_* environment keys while keeping LiveContainer internal callers functional.
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#import "../../litehook/src/litehook.h"
#import "../LCSharedUtils.h"
#import "../utils.h"
#import "Tweaks.h"
#include "./libproc.h"
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

extern int (*orig_dladdr)(const void *addr, Dl_info *info);

#ifndef PROC_PIDREGIONPATHINFO
#define PROC_PIDREGIONPATHINFO 8
#endif
#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 21
#endif
#ifndef PROC_PIDREGIONPATHINFO3
#define PROC_PIDREGIONPATHINFO3 22
#endif

typedef struct {
    uintptr_t start;
    uintptr_t end;
} LCStealthAddrRange;

static os_unfair_lock sRangeLock = OS_UNFAIR_LOCK_INIT;
static LCStealthAddrRange *sHiddenRanges = NULL;
static size_t sHiddenRangeCount = 0;
static size_t sHiddenRangeCapacity = 0;

static char sLcMainBundlePath[PATH_MAX] = {0};
static char sGlobalTweaksPath[PATH_MAX] = {0};
static char sGuestAppBundlePath[PATH_MAX] = {0};

static const char * _Nonnull * (*orig_objc_copyImageNames)(unsigned int *outCount) = objc_copyImageNames;
static const char * (*orig_class_getImageName)(Class cls) = class_getImageName;
static const char * _Nonnull * (*orig_objc_copyClassNamesForImage)(const char *image, unsigned int *outCount) = objc_copyClassNamesForImage;
static int (*orig_proc_regionfilename)(int pid, uint64_t address, void *buffer, uint32_t buffersize) = proc_regionfilename;
static int (*orig_proc_pidinfo)(int pid, int flavor, uint64_t arg, void *buffer, int buffersize) = proc_pidinfo;
static int (*orig_proc_pidpath)(int pid, void *buffer, uint32_t buffersize) = proc_pidpath;

static const char *lcStripPrivatePrefix(const char *path) {
    if (!path) return "";
    if (strncmp(path, "/private/", 9) == 0) {
        return path + 8;
    }
    return path;
}

static bool lcHasNormalizedPrefix(const char *path, const char *prefix) {
    if (!path || !prefix || prefix[0] == '\0') return false;
    const char *p = lcStripPrivatePrefix(path);
    const char *q = lcStripPrivatePrefix(prefix);
    size_t qLen = strlen(q);
    if (strncmp(p, q, qLen) != 0) return false;
    return p[qLen] == '\0' || p[qLen] == '/';
}

static void lcCapturePathCString(NSString *nsPath, char *dst, size_t dstSize) {
    if (nsPath.length == 0 || !dst || dstSize == 0) return;
    const char *rep = nsPath.fileSystemRepresentation;
    if (rep && rep[0] != '\0') {
        strlcpy(dst, rep, dstSize);
    }
}

bool LCStealthIsHiddenPath(const char *path) {
    if (!path || path[0] == '\0') {
        return false;
    }

    // Never hide guest app binaries/frameworks unless an explicit TweakLoader symlink lives inside it.
    if (sGuestAppBundlePath[0] != '\0' && lcHasNormalizedPrefix(path, sGuestAppBundlePath)) {
        return strstr(path, "/TweakLoader.dylib") != NULL;
    }

    if (sLcMainBundlePath[0] != '\0' && lcHasNormalizedPrefix(path, sLcMainBundlePath)) {
        return true;
    }
    if (sGlobalTweaksPath[0] != '\0' && lcHasNormalizedPrefix(path, sGlobalTweaksPath)) {
        return true;
    }

    static const char *const kHiddenSubstrings[] = {
        "/LiveContainer.app",
        "/LiveProcess.appex",
        "/LiveContainerShared.framework",
        "/SideStoreSupport.framework",
        "/TweakLoader.dylib",
        "/Tweaks/",
        "/procursus/",
        "/CydiaSubstrate",
        "CydiaSubstrate.framework",
        "libsubstitute",
        "libhooker",
        "ellekit"
    };
    size_t count = sizeof(kHiddenSubstrings) / sizeof(kHiddenSubstrings[0]);
    for (size_t i = 0; i < count; ++i) {
        if (strstr(path, kHiddenSubstrings[i]) != NULL) {
            return true;
        }
    }
    return false;
}

static void lcAppendHiddenRangeLocked(uintptr_t start, uintptr_t end) {
    if (end <= start) return;
    for (size_t i = 0; i < sHiddenRangeCount; ++i) {
        if (sHiddenRanges[i].start == start && sHiddenRanges[i].end == end) {
            return;
        }
    }
    if (sHiddenRangeCount >= sHiddenRangeCapacity) {
        size_t newCap = sHiddenRangeCapacity == 0 ? 32 : sHiddenRangeCapacity * 2;
        LCStealthAddrRange *grown = (LCStealthAddrRange *)realloc(sHiddenRanges, newCap * sizeof(LCStealthAddrRange));
        if (!grown) return;
        sHiddenRanges = grown;
        sHiddenRangeCapacity = newCap;
    }
    sHiddenRanges[sHiddenRangeCount++] = (LCStealthAddrRange){ start, end };
}

static void lcRegisterSegmentsForHeader(const struct mach_header *header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) {
        return;
    }
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    const uint8_t *cursor = (const uint8_t *)(header64 + 1);

    os_unfair_lock_lock(&sRangeLock);
    for (uint32_t i = 0; i < header64->ncmds; ++i) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize == 0) break;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (seg->vmsize > 0 && strcmp(seg->segname, "__PAGEZERO") != 0) {
                uintptr_t start = (uintptr_t)((intptr_t)seg->vmaddr + slide);
                uintptr_t end = start + (uintptr_t)seg->vmsize;
                lcAppendHiddenRangeLocked(start, end);
            }
        }
        cursor += cmd->cmdsize;
    }
    os_unfair_lock_unlock(&sRangeLock);
}

static const char *lcFindImageNameForHeader(const struct mach_header *header) {
    if (!header || !orig_dyld_image_count || !orig_dyld_get_image_header || !orig_dyld_get_image_name) {
        return NULL;
    }
    uint32_t count = orig_dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        if (orig_dyld_get_image_header(i) == header) {
            return orig_dyld_get_image_name(i);
        }
    }
    return NULL;
}

static void lcStealthImageAdded(const struct mach_header *header, intptr_t slide) {
    if (!header) {
        return;
    }
    Dl_info dlInfo;
    const char *path = NULL;
    if ((orig_dladdr ? orig_dladdr(header, &dlInfo) : dladdr(header, &dlInfo)) && dlInfo.dli_fname) {
        path = dlInfo.dli_fname;
    } else {
        path = lcFindImageNameForHeader(header);
    }
    if (LCStealthIsHiddenPath(path)) {
        lcRegisterSegmentsForHeader(header, slide);
    }
}

bool LCStealthIsInternalAddress(const void *addr) {
    if (!addr) return false;
#ifdef __PTRAUTH_INTRINSICS__
    uintptr_t p = (uintptr_t)ptrauth_strip((void *)addr, ptrauth_key_return_address);
#else
    uintptr_t p = (uintptr_t)addr;
#endif
    p &= 0x0000FFFFFFFFFFFFULL;
    os_unfair_lock_lock(&sRangeLock);
    bool found = false;
    for (size_t i = 0; i < sHiddenRangeCount; ++i) {
        uintptr_t start = sHiddenRanges[i].start & 0x0000FFFFFFFFFFFFULL;
        uintptr_t end = sHiddenRanges[i].end & 0x0000FFFFFFFFFFFFULL;
        if (p >= start && p < end) {
            found = true;
            break;
        }
    }
    os_unfair_lock_unlock(&sRangeLock);
    return found;
}

static const char * _Nonnull *hook_objc_copyImageNames(unsigned int *outCount) {
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return orig_objc_copyImageNames(outCount);
    }
    unsigned int rawCount = 0;
    const char * _Nonnull *rawNames = orig_objc_copyImageNames(&rawCount);
    if (!rawNames) {
        if (outCount) *outCount = 0;
        return NULL;
    }
    const char **filtered = (const char **)malloc(sizeof(char *) * ((size_t)rawCount + 1));
    if (!filtered) {
        if (outCount) *outCount = rawCount;
        return rawNames;
    }
    unsigned int kept = 0;
    for (unsigned int i = 0; i < rawCount; ++i) {
        const char *name = rawNames[i];
        if (!LCStealthIsHiddenPath(name)) {
            filtered[kept++] = name;
        }
    }
    filtered[kept] = NULL;
    free((void *)rawNames);
    if (outCount) *outCount = kept;
    return (const char * _Nonnull *)filtered;
}

static const char *hook_class_getImageName(Class cls) {
    const char *name = orig_class_getImageName(cls);
    if (!name) return NULL;
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return name;
    }
    if (LCStealthIsHiddenPath(name)) {
        return NULL;
    }
    return name;
}

static const char * _Nonnull *hook_objc_copyClassNamesForImage(const char *image, unsigned int *outCount) {
    if (image && !LCStealthIsInternalAddress(__builtin_return_address(0)) && LCStealthIsHiddenPath(image)) {
        if (outCount) *outCount = 0;
        const char **empty = (const char **)calloc(1, sizeof(char *));
        return (const char * _Nonnull *)empty;
    }
    return orig_objc_copyClassNamesForImage(image, outCount);
}

static int hook_proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize) {
    int ret = orig_proc_regionfilename(pid, address, buffer, buffersize);
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return ret;
    }
    bool hiddenAddr = (address != 0 && LCStealthIsInternalAddress((const void *)(uintptr_t)address));
    bool hiddenPath = (ret > 0 && buffer && LCStealthIsHiddenPath((const char *)buffer));
    if (hiddenAddr || hiddenPath) {
        if (buffer && buffersize > 0) {
            ((char *)buffer)[0] = '\0';
        }
        return 0;
    }
    return ret;
}

static int hook_proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize) {
    int ret = orig_proc_pidinfo(pid, flavor, arg, buffer, buffersize);
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return ret;
    }
    if ((flavor == PROC_PIDREGIONPATHINFO || flavor == PROC_PIDREGIONPATHINFO2 || flavor == PROC_PIDREGIONPATHINFO3) &&
        ret >= MAXPATHLEN && buffer != NULL) {
        const char *vipPath = (const char *)buffer + (ret - MAXPATHLEN);
        if (vipPath[0] != '\0' && LCStealthIsHiddenPath(vipPath)) {
            if (buffersize > 0) {
                memset(buffer, 0, (size_t)buffersize);
            }
            errno = EINVAL;
            return 0;
        }
    }
    return ret;
}

static int hook_proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    int ret = orig_proc_pidpath(pid, buffer, buffersize);
    if (pid == getpid() &&
        !LCStealthIsInternalAddress(__builtin_return_address(0)) &&
        ret > 0 && buffer && buffersize > 0 &&
        lcGuestExecutablePath && lcGuestExecutablePath[0] != '\0' &&
        LCStealthIsHiddenPath((const char *)buffer)) {
        size_t copied = strlcpy((char *)buffer, lcGuestExecutablePath, buffersize);
        return (int)(copied < buffersize ? copied : buffersize - 1);
    }
    return ret;
}

@interface NSBundle (LCStealthHide)
+ (NSArray<NSBundle *> *)lc_stealth_allBundles;
+ (NSArray<NSBundle *> *)lc_stealth_allFrameworks;
@end

@implementation NSBundle (LCStealthHide)

+ (NSArray<NSBundle *> *)lc_filterVisibleBundles:(NSArray<NSBundle *> *)bundles {
    NSMutableArray<NSBundle *> *filtered = [NSMutableArray arrayWithCapacity:bundles.count];
    for (NSBundle *bundle in bundles) {
        const char *bundlePath = bundle.bundlePath.fileSystemRepresentation;
        const char *execPath = bundle.executablePath.fileSystemRepresentation;
        if (LCStealthIsHiddenPath(bundlePath) || LCStealthIsHiddenPath(execPath)) {
            continue;
        }
        [filtered addObject:bundle];
    }
    return filtered;
}

+ (NSArray<NSBundle *> *)lc_stealth_allBundles {
    NSArray<NSBundle *> *raw = [self lc_stealth_allBundles];
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return raw;
    }
    return [self lc_filterVisibleBundles:raw];
}

+ (NSArray<NSBundle *> *)lc_stealth_allFrameworks {
    NSArray<NSBundle *> *raw = [self lc_stealth_allFrameworks];
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return raw;
    }
    return [self lc_filterVisibleBundles:raw];
}

@end

@interface NSProcessInfo (LCStealthHide)
- (NSDictionary<NSString *, NSString *> *)lc_stealth_environment;
- (NSDictionary<NSString *, NSString *> *)lc_stealth_swift_environment;
@end

static NSDictionary<NSString *, NSString *> *lcFilterEnvironmentDict(NSDictionary<NSString *, NSString *> *raw) {
    if (raw.count == 0) {
        return raw;
    }
    NSMutableDictionary<NSString *, NSString *> *filtered = [raw mutableCopy];
    [filtered removeObjectsForKeys:@[
        @"DYLD_INSERT_LIBRARIES",
        @"LC_GLOBAL_TWEAKS_FOLDER",
        @"LC_HOME_PATH",
        @"LP_HOME_PATH"
    ]];
    for (NSString *key in [filtered allKeys]) {
        NSString *val = filtered[key];
        if ([key hasPrefix:@"DYLD_"] &&
            ([val containsString:@"LiveContainer"] || [val containsString:@"TweakLoader"] || [val containsString:@"/Tweaks/"])) {
            [filtered removeObjectForKey:key];
        }
    }
    return filtered;
}

@implementation NSProcessInfo (LCStealthHide)

- (NSDictionary<NSString *, NSString *> *)lc_stealth_environment {
    NSDictionary<NSString *, NSString *> *raw = [self lc_stealth_environment];
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return raw;
    }
    return lcFilterEnvironmentDict(raw);
}

- (NSDictionary<NSString *, NSString *> *)lc_stealth_swift_environment {
    NSDictionary<NSString *, NSString *> *raw = [self lc_stealth_swift_environment];
    if (LCStealthIsInternalAddress(__builtin_return_address(0))) {
        return raw;
    }
    return lcFilterEnvironmentDict(raw);
}

@end

/**
 Initializes stealth image, Objective-C runtime, Mach VM region, NSBundle, and
 `NSProcessInfo.environment` cloaking hooks once per guest process.

 Loaded images under the LiveContainer bundle, Global Tweaks folder, and
 guest-specific TweakLoader/Tweaks directories remain functional inside the
 process while appearing absent to external anti-tamper inspection.
 */
void LCStealthRegisterInternalRanges(void) {
    static dispatch_once_t regOnceToken;
    dispatch_once(&regOnceToken, ^{
        if (lcMainBundlePath && lcMainBundlePath[0] != '\0') {
            strlcpy(sLcMainBundlePath, lcMainBundlePath, sizeof(sLcMainBundlePath));
        } else {
            NSString *bundlePath = NSUserDefaults.lcMainBundle.bundlePath;
            if (NSUserDefaults.isLiveProcess && [bundlePath.lastPathComponent isEqualToString:@"LiveProcess.appex"]) {
                bundlePath = bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            }
            lcCapturePathCString(bundlePath, sLcMainBundlePath, sizeof(sLcMainBundlePath));
        }
        lcCapturePathCString([LCSharedUtils cachedGlobalTweaksFolderPath], sGlobalTweaksPath, sizeof(sGlobalTweaksPath));
        lcCapturePathCString(NSBundle.mainBundle.bundlePath, sGuestAppBundlePath, sizeof(sGuestAppBundlePath));

        _dyld_register_func_for_add_image(lcStealthImageAdded);
    });
}

void LCStealthHideInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LCStealthRegisterInternalRanges();

        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, objc_copyImageNames, hook_objc_copyImageNames, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, class_getImageName, hook_class_getImageName, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, objc_copyClassNamesForImage, hook_objc_copyClassNamesForImage, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, proc_regionfilename, hook_proc_regionfilename, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, proc_pidinfo, hook_proc_pidinfo, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, proc_pidpath, hook_proc_pidpath, nil);

        Class bundleMeta = object_getClass(NSBundle.class);
        swizzle(bundleMeta, @selector(allBundles), @selector(lc_stealth_allBundles));
        swizzle(bundleMeta, @selector(allFrameworks), @selector(lc_stealth_allFrameworks));

        swizzle(NSProcessInfo.class, @selector(environment), @selector(lc_stealth_environment));
        Class swiftProcInfo = NSClassFromString(@"_NSSwiftProcessInfo");
        if (swiftProcInfo) {
            SEL envSel = @selector(environment);
            Method baseMethod = class_getInstanceMethod(NSProcessInfo.class, envSel);
            Method swiftMethod = class_getInstanceMethod(swiftProcInfo, envSel);
            if (baseMethod && swiftMethod && swiftMethod != baseMethod) {
                Method hookM = class_getInstanceMethod(NSProcessInfo.class, @selector(lc_stealth_swift_environment));
                if (hookM) {
                    class_addMethod(swiftProcInfo, @selector(lc_stealth_swift_environment), method_getImplementation(hookM), method_getTypeEncoding(hookM));
                    method_exchangeImplementations(swiftMethod, class_getInstanceMethod(swiftProcInfo, @selector(lc_stealth_swift_environment)));
                }
            }
        }
    });
}

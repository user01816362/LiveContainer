@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#import <dlfcn.h>
#include <mach-o/getsect.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#pragma clang diagnostic ignored "-Wundeclared-selector"

BOOL isolateAppGroup = NO;
BOOL strictTestMode = NO;
static BOOL isolateWebViewData = NO;
static NSString *extensionParentContainerPath;
void* webKitHeader = 0;
static uintptr_t webKitTextStart = 0;
static uintptr_t webKitTextEnd = 0;

static void updateWebKitTextBounds(void) {
    if (!webKitHeader) {
        return;
    }
    unsigned long textSize = 0;
    uint8_t *textPtr = getsegmentdata((const struct mach_header_64 *)webKitHeader, SEG_TEXT, &textSize);
    if (textPtr && textSize > 0) {
        webKitTextStart = (uintptr_t)textPtr;
        webKitTextEnd = webKitTextStart + textSize;
    } else {
        webKitTextStart = (uintptr_t)webKitHeader;
        webKitTextEnd = webKitTextStart + (128ULL << 20);
    }
}
void NSFMGuestExtensionHooksInit(NSString *parentContainerPath) {
    LCStealthRegisterInternalRanges();
    extensionParentContainerPath = parentContainerPath;
    NSDictionary *infoDict = [NSUserDefaults guestContainerInfo];
    strictTestMode = [infoDict[@"strictTestMode"] boolValue];
    isolateAppGroup = strictTestMode || [infoDict[@"isolateAppGroup"] boolValue];
    isolateWebViewData = strictTestMode || [infoDict[@"isolateWebViewData"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
}

void NSFMGuestHooksInit(void) {
    LCStealthRegisterInternalRanges();
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    strictTestMode = [infoDict[@"strictTestMode"] boolValue];
    isolateAppGroup = strictTestMode || [infoDict[@"isolateAppGroup"] boolValue];
    isolateWebViewData = strictTestMode || [infoDict[@"isolateWebViewData"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));

    if (isolateWebViewData) {
        // Native WKWebsiteDataStore isolation (dataStoreForIdentifier: / nonPersistentDataStore) handles cookies without symlinking.
        return;
    }
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        if (webKitHeader && dscPtr) {
            saveCachedSymbol(@"webKitHeader", dscPtr, (uintptr_t)webKitHeader - (uintptr_t)dscPtr);
        }
    }
    updateWebKitTextBounds();
    
    swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        void *rawCaller = __builtin_return_address(0);
#ifdef __PTRAUTH_INTRINSICS__
        void *strippedCaller = ptrauth_strip(rawCaller, ptrauth_key_return_address);
#else
        void *strippedCaller = rawCaller;
#endif
        if (LCStealthIsInternalAddress(strippedCaller) && NSUserDefaults.lcAppGroupPath) {
            return [NSURL fileURLWithPath:NSUserDefaults.lcAppGroupPath];
        }
    }
    NSURL *result;
    if(isolateAppGroup) {
        const char *homeEnv = getenv("HOME");
        NSString *homePath = extensionParentContainerPath ?: (homeEnv ? @(homeEnv) : NSHomeDirectory());
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LCAppGroup/%@", homePath, groupIdentifier]];
    } else if (NSUserDefaults.lcAppGroupPath){
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier]];
    } else {
        NSString *lcHome = [NSClassFromString(@"LCSharedUtils") cachedLcHomePath] ?: NSHomeDirectory();
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Documents/Data/AppGroup/%@", lcHome, groupIdentifier]];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:[result URLByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil];
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    void *rawCaller = __builtin_return_address(0);
#ifdef __PTRAUTH_INTRINSICS__
    uintptr_t callerAddr = (uintptr_t)ptrauth_strip(rawCaller, ptrauth_key_return_address);
#else
    uintptr_t callerAddr = (uintptr_t)rawCaller;
#endif
    if (webKitHeader && webKitTextEnd > webKitTextStart && callerAddr >= webKitTextStart && callerAddr < webKitTextEnd) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *lcHomePath = NSUserDefaults.isLiveProcess
                ? [NSClassFromString(@"LCSharedUtils") cachedLpHomePath]
                : [NSClassFromString(@"LCSharedUtils") cachedLcHomePath];
            const char *homeEnv = getenv("HOME");
            if (lcHomePath.length == 0 || !homeEnv) {
                return YES;
            }
            NSString *libraryPath = [lcHomePath stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            NSString* appCookiesPath = [@(homeEnv) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end

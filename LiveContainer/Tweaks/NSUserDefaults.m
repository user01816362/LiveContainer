//
//  NSUserDefaults.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//

#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "../../litehook/src/litehook.h"
#include "Tweaks.h"
@import ObjectiveC;
@import MachO;

BOOL hook_return_false(void) {
    return NO;
}

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
}

NSURL* appContainerURL = 0;
NSString* appContainerPath = 0;

void NUDGuestHooksInit(void) {
    const char *homeEnv = getenv("HOME");
    appContainerPath = homeEnv ? [NSString stringWithUTF8String:homeEnv] : NSHomeDirectory();
    appContainerURL = [NSURL fileURLWithPath:appContainerPath];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    // fix for macOS host
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"CFPrefsPlistSource"), @selector(_isSharedInTheiOSSimulator)), (IMP)hook_return_false);
#endif

    Class CFPrefsPlistSourceClass = NSClassFromString(@"CFPrefsPlistSource");

    swizzle2(CFPrefsPlistSourceClass, @selector(initWithDomain:user:byHost:containerPath:containingPreferences:), CFPrefsPlistSource2.class, @selector(hook_initWithDomain:user:byHost:containerPath:containingPreferences:));
#pragma clang diagnostic pop
    
    Class CFXPreferencesClass = NSClassFromString(@"_CFXPreferences");
    Ivar sourcesIvar = CFXPreferencesClass ? class_getInstanceVariable(CFXPreferencesClass, "_sources") : NULL;
    id defaultPrefs = CFXPreferencesClass ? [CFXPreferencesClass copyDefaultPreferences] : nil;
    NSMutableDictionary* sources = (defaultPrefs && sourcesIvar) ? object_getIvar(defaultPrefs, sourcesIvar) : nil;

    if ([sources isKindOfClass:NSMutableDictionary.class]) {
        [sources removeObjectForKey:@"C/A//B/L"];
        [sources removeObjectForKey:@"C/C//*/L"];
    }
    
    // replace _CFPrefsCurrentAppIdentifierCache so kCFPreferencesCurrentApplication refers to the guest app
    const char* coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    struct mach_header_64* coreFoundationHeader = LCGetLoadedImageHeader(2, coreFoundationPath);
    
#if !TARGET_OS_SIMULATOR
    static NSString *sGuestAppIdentifierCache = nil;
    CFStringRef* _CFPrefsCurrentAppIdentifierCache = coreFoundationHeader ? getCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader) : NULL;
    if (!_CFPrefsCurrentAppIdentifierCache && coreFoundationHeader) {
        _CFPrefsCurrentAppIdentifierCache = litehook_find_dsc_symbol(coreFoundationPath, "__CFPrefsCurrentAppIdentifierCache");
        if (_CFPrefsCurrentAppIdentifierCache) {
            uint64_t offset = (uint64_t)((uintptr_t)_CFPrefsCurrentAppIdentifierCache - (uintptr_t)coreFoundationHeader);
            saveCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader, offset);
        }
    }
    if (_CFPrefsCurrentAppIdentifierCache) {
        CFStringRef currentCachedId = *_CFPrefsCurrentAppIdentifierCache;
        if (currentCachedId) {
            NSString *copiedId = CFBridgingRelease(CFStringCreateCopy(nil, currentCachedId));
            [NSUserDefaults.lcUserDefaults _setIdentifier:copiedId];
        } else if (NSUserDefaults.lcMainBundle.bundleIdentifier) {
            [NSUserDefaults.lcUserDefaults _setIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier];
        }
        sGuestAppIdentifierCache = [NSUserDefaults.lcGuestAppId copy];
        if (sGuestAppIdentifierCache) {
            *_CFPrefsCurrentAppIdentifierCache = (__bridge CFStringRef)sGuestAppIdentifierCache;
        }
    }
#else
    // FIXME: for now we skip overwriting _CFPrefsCurrentAppIdentifierCache on simulator, since there is no way to find private symbol
#endif
    
    NSUserDefaults* newStandardUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"whatever"];
    [newStandardUserDefaults _setIdentifier:NSUserDefaults.lcGuestAppId];
    NSUserDefaults.standardUserDefaults = newStandardUserDefaults;

#if !TARGET_OS_SIMULATOR
    static NSMutableArray *sGuestUserLanguages = nil;
    NSString* selectedLanguage = NSUserDefaults.guestAppInfo[@"LCSelectedLanguage"];
    if(selectedLanguage) {
        [newStandardUserDefaults setObject:@[selectedLanguage] forKey:@"AppleLanguages"];
        CFMutableArrayRef* _CFBundleUserLanguages = coreFoundationHeader ? getCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader) : NULL;
        if (!_CFBundleUserLanguages && coreFoundationHeader) {
            _CFBundleUserLanguages = litehook_find_dsc_symbol(coreFoundationPath, "__CFBundleUserLanguages");
            if (_CFBundleUserLanguages) {
                uint64_t offset = (uint64_t)((uintptr_t)_CFBundleUserLanguages - (uintptr_t)coreFoundationHeader);
                saveCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader, offset);
            }
        }
        // Keep a strong static reference so ARC never releases the array pointed to by _CFBundleUserLanguages
        if (_CFBundleUserLanguages) {
            sGuestUserLanguages = [NSMutableArray arrayWithObjects:selectedLanguage, nil];
            *_CFBundleUserLanguages = (__bridge CFMutableArrayRef)sGuestUserLanguages;
        }
    } else {
        [newStandardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
#endif
    
    // Create Library/Preferences folder in app's data folder in case it does not exist
    NSFileManager* fm = NSFileManager.defaultManager;
    NSURL* libraryPath = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL* preferenceFolderPath = [libraryPath URLByAppendingPathComponent:@"Preferences"];
    if(![fm fileExistsAtPath:preferenceFolderPath.path]) {
        NSError* error;
        [fm createDirectoryAtPath:preferenceFolderPath.path withIntermediateDirectories:YES attributes:@{} error:&error];
    }
    
}

NSArray* appleIdentifierPrefixes = @[
    @"com.apple.",
    @"group.com.apple.",
    @"systemgroup.com.apple."
];

bool isAppleIdentifier(NSString* identifier) {
    for(NSString* cur in appleIdentifierPrefixes) {
        if([identifier hasPrefix:cur]) {
            return true;
        }
    }
    return false;
}


@implementation CFPrefsPlistSource2
-(id)hook_initWithDomain:(CFStringRef)domain user:(CFStringRef)user byHost:(bool)host containerPath:(CFStringRef)containerPath containingPreferences:(id)arg5 {
    if(isAppleIdentifier((__bridge NSString*)domain)) {
        return [self hook_initWithDomain:domain user:user byHost:host containerPath:containerPath containingPreferences:arg5];
    }
    if(user == kCFPreferencesAnyUser) {
        user = kCFPreferencesCurrentUser;
    }
    return [self hook_initWithDomain:domain user:user byHost:host containerPath:(__bridge CFStringRef)appContainerPath containingPreferences:arg5];
}
@end

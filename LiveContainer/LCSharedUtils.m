#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
@import MachO;
@import Security;
@import CommonCrypto;
#import <objc/message.h>
#import <os/lock.h>

static os_unfair_lock sSigningCacheLock = OS_UNFAIR_LOCK_INIT;
static uint64_t sSigningCacheGeneration = 0;
static NSDate *sCachedCertUpdateDate = nil;
static BOOL sCertDataLoaded = NO;
static NSData *sCachedCertData = nil;
static BOOL sCertPwdLoaded = NO;
static NSString *sCachedCertPassword = nil;

static void LCInvalidateHostSigningSecretCache(void) {
    os_unfair_lock_lock(&sSigningCacheLock);
    sSigningCacheGeneration++;
    sCachedCertUpdateDate = nil;
    sCertDataLoaded = NO;
    sCachedCertData = nil;
    sCertPwdLoaded = NO;
    sCachedCertPassword = nil;
    os_unfair_lock_unlock(&sSigningCacheLock);
}

static uint64_t LCSyncHostSigningCacheLocked(NSDate *currentUpdateDate) {
    BOOL dateChanged = (sCachedCertUpdateDate != currentUpdateDate &&
                        ![sCachedCertUpdateDate isEqual:currentUpdateDate]);
    if (dateChanged) {
        sSigningCacheGeneration++;
        sCachedCertUpdateDate = currentUpdateDate;
        sCertDataLoaded = NO;
        sCachedCertData = nil;
        sCertPwdLoaded = NO;
        sCachedCertPassword = nil;
    }
    return sSigningCacheGeneration;
}

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

NSString* FBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";
NSString* FBSOpenApplicationOptionKeyPayloadURL = @"__PayloadURL";

@implementation LCSharedUtils

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        if(taskSelf) {
            CFErrorRef error = NULL;
            CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
            if(cfans) {
                if(CFGetTypeID(cfans) == CFStringGetTypeID()) {
                    ans = [(__bridge NSString*)cfans copy];
                }
                CFRelease(cfans);
            }
            if(error) {
                CFRelease(error);
            }
            CFRelease(taskSelf);
        }
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            NSString *tempAccountName = @"bundleSeedID";
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        NSString *teamId = [self teamIdentifier];
        NSMutableArray* possibleAppGroups = [NSMutableArray array];
        if(teamId.length > 0) {
            [possibleAppGroups addObject:[@"group.com.SideStore.SideStore." stringByAppendingString:teamId]];
            [possibleAppGroups addObject:[@"group.com.rileytestut.AltStore." stringByAppendingString:teamId]];
        }
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        if(!taskSelf) {
            return;
        }
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        if(error) {
            CFRelease(error);
        }
        CFRelease(taskSelf);

        if(!value) {
            return;
        }
        if(CFGetTypeID(value) == CFArrayGetTypeID()) {
            NSArray* appGroups = (__bridge NSArray *)value;
            if(appGroups.count > 0) {
                appGroupID = [appGroups.firstObject copy];
            }
        }
        CFRelease(value);
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
    });
    return appGroupPath;
}

+ (NSUserDefaults *)sharedSigningDefaults {
    if (NSUserDefaults.lcSharedDefaults) {
        return NSUserDefaults.lcSharedDefaults;
    }
    NSString *groupID = [self appGroupID];
    if (groupID.length > 0 && ![groupID isEqualToString:@"Unknown"]) {
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:groupID];
        if (suite) {
            return suite;
        }
    }
    return NSUserDefaults.standardUserDefaults;
}

+ (nullable NSString *)hostKeychainAccessGroup {
    NSString *teamId = [self teamIdentifier];
    if (teamId.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@.com.kdt.livecontainer.host", teamId];
}

+ (nullable NSString *)appIdentifierKeychainAccessGroup {
    NSString *teamId = [self teamIdentifier];
    NSString *bundleId = (NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle).bundleIdentifier;
    if (teamId.length == 0 || bundleId.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@.%@", teamId, bundleId];
}

+ (NSMutableDictionary *)baseHostCertQueryForAccount:(NSString *)account accessGroup:(nullable NSString *)accessGroup {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.kdt.livecontainer.host.signing",
        (__bridge id)kSecAttrAccount: account
    } mutableCopy];
    if (accessGroup.length > 0) {
        query[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return query;
}

+ (nullable NSData *)readHostSigningSecretForAccount:(NSString *)account {
    if (NSUserDefaults.isLiveProcess) {
        return nil;
    }
    NSString *hostGroup = [self hostKeychainAccessGroup];
    if (hostGroup.length > 0) {
        NSMutableDictionary *query = [self baseHostCertQueryForAccount:account accessGroup:hostGroup];
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        query[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID()) {
            return CFBridgingRelease(result);
        }
        if (result) {
            CFRelease(result);
        }
        // Only fall back when the .host entitlement itself was stripped; never search .shared* on errSecItemNotFound.
        if (status != errSecMissingEntitlement) {
            return nil;
        }
    }

    NSString *appIdGroup = [self appIdentifierKeychainAccessGroup];
    if (appIdGroup.length > 0) {
        NSMutableDictionary *fallbackQuery = [self baseHostCertQueryForAccount:account accessGroup:appIdGroup];
        fallbackQuery[(__bridge id)kSecReturnData] = @YES;
        fallbackQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        fallbackQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        CFTypeRef fallbackResult = NULL;
        OSStatus fallbackStatus = SecItemCopyMatching((__bridge CFDictionaryRef)fallbackQuery, &fallbackResult);
        if (fallbackStatus == errSecSuccess && fallbackResult && CFGetTypeID(fallbackResult) == CFDataGetTypeID()) {
            return CFBridgingRelease(fallbackResult);
        }
        if (fallbackResult) {
            CFRelease(fallbackResult);
        }
    }
    return nil;
}

+ (BOOL)writeHostSigningSecret:(NSData *)data forAccount:(NSString *)account {
    if (!data || NSUserDefaults.isLiveProcess) {
        return NO;
    }
    NSMutableArray<NSString *> *candidateGroups = [NSMutableArray array];
    NSString *hostGroup = [self hostKeychainAccessGroup];
    NSString *appIdGroup = [self appIdentifierKeychainAccessGroup];
    if (hostGroup.length > 0) {
        [candidateGroups addObject:hostGroup];
    }
    // Use application-identifier (never default group 0) if a signer stripped .host.
    if (appIdGroup.length > 0) {
        [candidateGroups addObject:appIdGroup];
    } else if (candidateGroups.count == 0) {
        [candidateGroups addObject:@""];
    }

    for (NSString *group in candidateGroups) {
        NSString *effectiveGroup = group.length > 0 ? group : nil;
        NSMutableDictionary *deleteQuery = [self baseHostCertQueryForAccount:account accessGroup:effectiveGroup];
        deleteQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

        NSMutableDictionary *addAttrs = [self baseHostCertQueryForAccount:account accessGroup:effectiveGroup];
        addAttrs[(__bridge id)kSecValueData] = data;
        addAttrs[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        addAttrs[(__bridge id)kSecAttrSynchronizable] = @NO;

        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addAttrs, NULL);
        if (status == errSecSuccess) {
            return YES;
        }
        if (status != errSecMissingEntitlement) {
            NSLog(@"[LC] Failed to store signing secret %@ in keychain: %d", account, (int)status);
            break;
        }
    }
    return NO;
}

+ (nullable NSData *)certificateData {
    BOOL canUseHostCache = (!NSUserDefaults.isLiveProcess && NSUserDefaults.guestAppInfo == nil);
    uint64_t readGeneration = 0;
    if (canUseHostCache) {
        id rawDate = [[self sharedSigningDefaults] objectForKey:@"LCCertificateUpdateDate"];
        NSDate *currentUpdateDate = [rawDate isKindOfClass:NSDate.class] ? rawDate : nil;
        os_unfair_lock_lock(&sSigningCacheLock);
        readGeneration = LCSyncHostSigningCacheLocked(currentUpdateDate);
        BOOL loaded = sCertDataLoaded;
        NSData *cached = sCachedCertData;
        os_unfair_lock_unlock(&sSigningCacheLock);
        if (loaded) {
            return cached;
        }
    }

    NSData *resolved = [self readHostSigningSecretForAccount:@"certificateData"];
    if (resolved.length == 0) {
        NSUserDefaults *sharedDefaults = [self sharedSigningDefaults];
        NSData *legacy = [sharedDefaults objectForKey:@"LCCertificateData"];
        if ([legacy isKindOfClass:NSData.class] && legacy.length > 0) {
            resolved = legacy;
        } else {
            NSData *stdLegacy = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificateData"];
            resolved = [stdLegacy isKindOfClass:NSData.class] ? stdLegacy : nil;
        }
    }

    if (canUseHostCache) {
        os_unfair_lock_lock(&sSigningCacheLock);
        if (sSigningCacheGeneration == readGeneration) {
            sCachedCertData = resolved;
            sCertDataLoaded = YES;
        }
        os_unfair_lock_unlock(&sSigningCacheLock);
    }
    return resolved;
}

+ (nullable NSString *)certificatePassword {
    BOOL canUseHostCache = (!NSUserDefaults.isLiveProcess && NSUserDefaults.guestAppInfo == nil);
    uint64_t readGeneration = 0;
    if (canUseHostCache) {
        id rawDate = [[self sharedSigningDefaults] objectForKey:@"LCCertificateUpdateDate"];
        NSDate *currentUpdateDate = [rawDate isKindOfClass:NSDate.class] ? rawDate : nil;
        os_unfair_lock_lock(&sSigningCacheLock);
        readGeneration = LCSyncHostSigningCacheLocked(currentUpdateDate);
        BOOL loaded = sCertPwdLoaded;
        NSString *cached = sCachedCertPassword;
        os_unfair_lock_unlock(&sSigningCacheLock);
        if (loaded) {
            return cached;
        }
    }

    NSString *resolved = nil;
    NSData *pwdData = [self readHostSigningSecretForAccount:@"certificatePassword"];
    if (pwdData != nil) {
        resolved = [[NSString alloc] initWithData:pwdData encoding:NSUTF8StringEncoding];
    }
    if (resolved == nil) {
        NSUserDefaults *nud = [self sharedSigningDefaults];
        id legacy = [nud objectForKey:@"LCCertificatePassword"];
        if ([legacy isKindOfClass:NSString.class]) {
            resolved = legacy;
        } else {
            id stdLegacy = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificatePassword"];
            resolved = [stdLegacy isKindOfClass:NSString.class] ? stdLegacy : nil;
        }
    }

    if (canUseHostCache) {
        os_unfair_lock_lock(&sSigningCacheLock);
        if (sSigningCacheGeneration == readGeneration) {
            sCachedCertPassword = resolved;
            sCertPwdLoaded = YES;
        }
        os_unfair_lock_unlock(&sSigningCacheLock);
    }
    return resolved;
}

+ (BOOL)isJITLessConfigured {
    NSUserDefaults *nud = [self sharedSigningDefaults];
    // Never probe host Keychain once running a guest process or inside normal-mode bootstrap where SecItem is hooked.
    if (NSUserDefaults.isLiveProcess || NSUserDefaults.guestAppInfo != nil) {
        return [nud boolForKey:@"LCJITLessConfigured"] || ([nud objectForKey:@"LCCertificatePassword"] != nil);
    }
    // Always verify actual backing secret in host process so stale defaults never mask missing Keychain items.
    BOOL configured = ([self certificateData].length > 0 && [self certificatePassword] != nil);
    if ([nud boolForKey:@"LCJITLessConfigured"] != configured) {
        [nud setBool:configured forKey:@"LCJITLessConfigured"];
    }
    return configured;
}

+ (void)saveCertificateData:(NSData *)certData password:(NSString *)password {
    NSData *pwdData = [(password ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    BOOL savedCert = [self writeHostSigningSecret:certData forAccount:@"certificateData"];
    BOOL savedPwd = [self writeHostSigningSecret:pwdData forAccount:@"certificatePassword"];

    NSUserDefaults *sharedDefaults = [self sharedSigningDefaults];
    if (savedCert && savedPwd) {
        [sharedDefaults removeObjectForKey:@"LCCertificateData"];
        [sharedDefaults removeObjectForKey:@"LCCertificatePassword"];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificateData"];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificatePassword"];
    } else {
        // Fallback when signer strips all Keychain entitlements.
        [sharedDefaults setObject:certData forKey:@"LCCertificateData"];
        [sharedDefaults setObject:(password ?: @"") forKey:@"LCCertificatePassword"];
    }
    [sharedDefaults setBool:YES forKey:@"LCJITLessConfigured"];
    [sharedDefaults setObject:NSDate.date forKey:@"LCCertificateUpdateDate"];
    LCInvalidateHostSigningSecretCache();
}

+ (void)clearCertificateData {
    for (NSString *account in @[@"certificateData", @"certificatePassword"]) {
        for (NSString *group in @[[self hostKeychainAccessGroup] ?: @"", [self appIdentifierKeychainAccessGroup] ?: @"", @""]) {
            NSMutableDictionary *q = [self baseHostCertQueryForAccount:account accessGroup:(group.length > 0 ? group : nil)];
            q[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
            SecItemDelete((__bridge CFDictionaryRef)q);
        }
    }

    NSUserDefaults *sharedDefaults = [self sharedSigningDefaults];
    [sharedDefaults removeObjectForKey:@"LCCertificateData"];
    [sharedDefaults removeObjectForKey:@"LCCertificatePassword"];
    [sharedDefaults removeObjectForKey:@"LCCertificateUpdateDate"];
    [sharedDefaults setBool:NO forKey:@"LCJITLessConfigured"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificateData"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificatePassword"];
    LCInvalidateHostSigningSecretCache();
}

+ (void)migrateCertificateToHostKeychainIfNeeded {
    if (NSUserDefaults.isLiveProcess) {
        return;
    }
    NSUserDefaults *sharedDefaults = [self sharedSigningDefaults];
    NSData *legacyCert = [sharedDefaults objectForKey:@"LCCertificateData"];
    NSString *legacyPwd = [sharedDefaults objectForKey:@"LCCertificatePassword"];
    if (![legacyCert isKindOfClass:NSData.class]) {
        legacyCert = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificateData"];
    }
    if (![legacyPwd isKindOfClass:NSString.class]) {
        legacyPwd = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificatePassword"];
    }

    if ([legacyCert isKindOfClass:NSData.class] && legacyCert.length > 0 && [legacyPwd isKindOfClass:NSString.class]) {
        NSData *pwdData = [legacyPwd dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        BOOL savedCert = [self writeHostSigningSecret:legacyCert forAccount:@"certificateData"];
        BOOL savedPwd = [self writeHostSigningSecret:pwdData forAccount:@"certificatePassword"];
        if (savedCert && savedPwd) {
            [sharedDefaults removeObjectForKey:@"LCCertificateData"];
            [sharedDefaults removeObjectForKey:@"LCCertificatePassword"];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificateData"];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"LCCertificatePassword"];
            LCInvalidateHostSigningSecretCache();
        }
    }
    [self isJITLessConfigured];
}

+ (nullable NSUUID *)webKitStoreIdentifierForContainerUUID:(NSString *)dataUUID {
    if (![dataUUID isKindOfClass:NSString.class] || dataUUID.length == 0) {
        return nil;
    }
    NSUUID *direct = [[NSUUID alloc] initWithUUIDString:dataUUID];
    if (direct) {
        return direct;
    }
    NSData *input = [[@"com.livecontainer.webkit.container:" stringByAppendingString:dataUUID] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    digest[6] = (digest[6] & 0x0F) | 0x50;
    digest[8] = (digest[8] & 0x3F) | 0x80;
    return [[NSUUID alloc] initWithUUIDBytes:digest];
}

+ (void)removeWebKitDataStoreForContainerUUID:(NSString *)dataUUID {
    NSUUID *storeUUID = [self webKitStoreIdentifierForContainerUUID:dataUUID];
    if (!storeUUID) {
        return;
    }
    dispatch_block_t removeBlock = ^{
        Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
        if (!storeClass) {
            return;
        }
        // Fast-path exit when WebKit has never stored any data in this container.
        NSString *webKitDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/WebKit"];
        if (![NSFileManager.defaultManager fileExistsAtPath:webKitDir]) {
            return;
        }

        // Ensure WebKit2 and WTF::RunLoop::main() are initialized before WebsiteDataStoreIO runs.
        static dispatch_once_t wkInitOnce;
        dispatch_once(&wkInitOnce, ^{
            SEL defaultSel = NSSelectorFromString(@"defaultDataStore");
            if ([storeClass respondsToSelector:defaultSel]) {
                id (*getDefault)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                (void)getDefault(storeClass, defaultSel);
            }
            Class configClass = NSClassFromString(@"WKWebViewConfiguration");
            if (configClass) {
                (void)[[configClass alloc] init];
            }
        });

        SEL removeSel = NSSelectorFromString(@"removeDataStoreForIdentifier:completionHandler:");
        if (![storeClass respondsToSelector:removeSel]) {
            return;
        }
        void (^performRemove)(void) = ^{
            void (*fn)(id, SEL, NSUUID *, void (^)(NSError *)) = (void (*)(id, SEL, NSUUID *, void (^)(NSError *)))objc_msgSend;
            fn(storeClass, removeSel, storeUUID, ^(NSError *error) {
                if (error) {
                    NSLog(@"[LC] Failed to remove WebKit data store %@: %@", storeUUID.UUIDString, error.localizedDescription);
                }
            });
        };

        SEL fetchSel = NSSelectorFromString(@"fetchAllDataStoreIdentifiers:");
        if ([storeClass respondsToSelector:fetchSel]) {
            void (*fetchFn)(id, SEL, void (^)(NSArray<NSUUID *> *)) = (void (*)(id, SEL, void (^)(NSArray<NSUUID *> *)))objc_msgSend;
            fetchFn(storeClass, fetchSel, ^(NSArray<NSUUID *> *identifiers) {
                if ([identifiers containsObject:storeUUID]) {
                    performRemove();
                }
            });
        } else {
            performRemove();
        }
    };
    if (NSThread.isMainThread) {
        removeBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), removeBlock);
    }
}

+ (void)removeKeychainItemsForContainerUUID:(NSString *)dataUUID
                            keychainGroupId:(NSInteger)keychainGroupId
                            wipeEntireGroup:(BOOL)wipeEntireGroup {
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
    NSString *teamId = [self teamIdentifier];
    NSString *scopedGroup = nil;
    if (teamId.length > 0 && keychainGroupId >= 0) {
        scopedGroup = keychainGroupId == 0
            ? [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", teamId]
            : [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared.%ld", teamId, (long)keychainGroupId];
    }

    for (id secClass in secClasses) {
        if (dataUUID.length > 0) {
            NSMutableDictionary *aliasQuery = [@{
                (__bridge id)kSecClass: secClass,
                @"alis": dataUUID,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            } mutableCopy];
            if (scopedGroup.length > 0) {
                aliasQuery[(__bridge id)kSecAttrAccessGroup] = scopedGroup;
            }
            SecItemDelete((__bridge CFDictionaryRef)aliasQuery);

            if (scopedGroup.length > 0) {
                // Also delete unscoped alias entries created when entitlements were stripped.
                [aliasQuery removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
                SecItemDelete((__bridge CFDictionaryRef)aliasQuery);
            }
        }

        // Only wipe an entire access group when it is strictly a dedicated guest group (> 0).
        if (wipeEntireGroup && keychainGroupId > 0 && scopedGroup.length > 0) {
            NSDictionary *groupQuery = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecAttrAccessGroup: scopedGroup,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny
            };
            SecItemDelete((__bridge CFDictionaryRef)groupQuery);
        }
    }
}

+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode {
    void (^completionHandler)(BOOL) = ^(BOOL success) {
        // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
        __asm__ __volatile__ (
                              "mov x0, #31\n"
                              "mov x16, #26\n"
                              "svc #0x80"
                              );
        raise(SIGKILL);
    };
    
    if (!self.isJITLessConfigured) {
        NSString *urlScheme = nil;
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        }
        
        if(urlScheme) {
            NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:launchURL options:@{} completionHandler:completionHandler];
            return YES;
        }
    }

    int tries = 2;
    _LSOpenConfiguration *configuration = [[PrivClass(_LSOpenConfiguration) alloc] init];
    if(classicMode) {
        NSMutableDictionary* dict = [NSMutableDictionary new];
        dict[FBSOpenApplicationOptionKeyActivateAsClassic] = @(classicMode);
        configuration.frontBoardOptions = dict;
    }
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
    
    for (int i = 0; i < tries; i++) {
        [workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier
                                         configuration:configuration
                                     completionHandler:^(BOOL success, NSError* error) {
            completionHandler(success);
        }];
    }
    return YES;
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        bool isSharedApp = false;
        NSBundle *appBundle = [self findBundleWithBundleId:launchBundleId isSharedAppOut:&isSharedApp];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [appBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSUInteger classicMode = [appInfo[@"classicMode"] boolValue]
            ? [appInfo[@"LCClassicModeCache"][@"defaultClassicMode"] unsignedIntegerValue]
            : 0;
        return [self launchToGuestAppWithClassicMode:classicMode];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    if (folderName.length == 0) {
        return nil;
    }
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (![info isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (![appUsageInfo isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like livecontainer or livecontainer2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"LiveContainer was unable to move the data of shared app back because LiveContainer cannot access app group. Please check JITLess diagnose page in LiveContainer settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSString *lcHome = [self cachedLcHomePath] ?: NSHomeDirectory();
    NSString *docPath = [lcHome stringByAppendingPathComponent:@"Documents"];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle = nil;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle && isSharedAppOut) {
            *isSharedAppOut = true;
        }
    } else if(isSharedAppOut) {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"livecontainer", @"livecontainer2", @"livecontainer3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }
    return result;
}

static NSString *sLCCachedHomePath = nil;
static NSString *sLCCachedLpHomePath = nil;
static NSString *sLCCachedGlobalTweaksFolderPath = nil;

+ (void)cacheProcessEnvironmentPaths {
    @synchronized (self) {
        const char *lcHome = getenv("LC_HOME_PATH");
        if (lcHome && lcHome[0] != '\0') {
            sLCCachedHomePath = [NSString stringWithUTF8String:lcHome];
        }
        const char *lpHome = getenv("LP_HOME_PATH");
        if (lpHome && lpHome[0] != '\0') {
            sLCCachedLpHomePath = [NSString stringWithUTF8String:lpHome];
        }
        const char *tweaksFolder = getenv("LC_GLOBAL_TWEAKS_FOLDER");
        if (tweaksFolder && tweaksFolder[0] != '\0') {
            sLCCachedGlobalTweaksFolderPath = [NSString stringWithUTF8String:tweaksFolder];
        }
    }
}

+ (NSString *)cachedLcHomePath {
    const char *env = getenv("LC_HOME_PATH");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    @synchronized (self) {
        return sLCCachedHomePath;
    }
}

+ (NSString *)cachedLpHomePath {
    const char *env = getenv("LP_HOME_PATH");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    @synchronized (self) {
        return sLCCachedLpHomePath;
    }
}

+ (NSString *)cachedGlobalTweaksFolderPath {
    const char *env = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    @synchronized (self) {
        return sLCCachedGlobalTweaksFolderPath;
    }
}

+ (void)ensureContainerDirectoriesAtPath:(NSString *)containerPath {
    if (containerPath.length == 0 || [containerPath isEqualToString:@"/"]) {
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *directories = @[@"Library/Caches", @"Library/Cookies", @"Library/Preferences", @"Documents", @"SystemData", @"tmp"];
    for (NSString *directory in directories) {
        NSString *path = [containerPath stringByAppendingPathComponent:directory];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

+ (void)wipeStrictContainerIfNeededAtPath:(NSString *)containerPath force:(BOOL)force {
    if (containerPath.length == 0 || [containerPath isEqualToString:@"/"]) {
        return;
    }
    static NSString *const kContainerInfoFileName = @"LCContainerInfo.plist";
    NSString *containerInfoPath = [containerPath stringByAppendingPathComponent:kContainerInfoFileName];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    if (![info isKindOfClass:NSDictionary.class]) {
        return;
    }
    if (!force && !([info[@"strictTestMode"] boolValue] && [info[@"strictAutoWipeOnExit"] boolValue])) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *listError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:containerPath error:&listError];
    if (!entries) {
        NSLog(@"[LC][StrictMode] Failed to enumerate container for auto-wipe: %@", listError.localizedDescription);
        return;
    }

    for (NSString *entry in entries) {
        if ([entry isEqualToString:kContainerInfoFileName]) {
            continue;
        }
        NSError *removeError = nil;
        NSString *entryPath = [containerPath stringByAppendingPathComponent:entry];
        if (![fm removeItemAtPath:entryPath error:&removeError] && removeError) {
            NSLog(@"[LC][StrictMode] Failed to remove %@ in container: %@", entry, removeError.localizedDescription);
        }
    }
    NSString *containerDataUUID = containerPath.lastPathComponent;
    NSInteger keychainGroupId = [info[@"keychainGroupId"] isKindOfClass:NSNumber.class]
        ? [info[@"keychainGroupId"] integerValue]
        : -1;
    BOOL wipeEntireGroup = (keychainGroupId > 0) && [info[@"strictWipeEntireKeychainGroup"] boolValue];

    [self removeKeychainItemsForContainerUUID:containerDataUUID
                              keychainGroupId:keychainGroupId
                              wipeEntireGroup:wipeEntireGroup];
    // Avoid bootstrapping WebKit2 inside guest constructors / atexit teardown; guest container Library was already wiped above.
    if (NSUserDefaults.guestAppInfo == nil) {
        [self removeWebKitDataStoreForContainerUUID:containerDataUUID];
    }
    if (containerDataUUID.length > 0) {
        NSString *tmpRoot = NSTemporaryDirectory();
        if (tmpRoot.length > 1 && [tmpRoot hasSuffix:@"/"]) {
            tmpRoot = [tmpRoot substringToIndex:tmpRoot.length - 1];
        }
        if ([tmpRoot.lastPathComponent isEqualToString:containerDataUUID]) {
            NSArray<NSString *> *tmpEntries = [fm contentsOfDirectoryAtPath:tmpRoot error:nil];
            for (NSString *tmpEntry in tmpEntries) {
                [fm removeItemAtPath:[tmpRoot stringByAppendingPathComponent:tmpEntry] error:nil];
            }
        } else {
            NSString *containerTmpPath = [tmpRoot stringByAppendingPathComponent:containerDataUUID];
            BOOL tmpIsDir = NO;
            if ([fm fileExistsAtPath:containerTmpPath isDirectory:&tmpIsDir] && tmpIsDir) {
                [fm removeItemAtPath:containerTmpPath error:nil];
            }
        }
    }

    [self ensureContainerDirectoriesAtPath:containerPath];
}

static nullable NSString *LCContainerInfoPathForDataUUID(NSString *dataUUID) {
    if (dataUUID.length == 0 ||
        [dataUUID rangeOfString:@"/"].location != NSNotFound ||
        [dataUUID isEqualToString:@"."] ||
        [dataUUID isEqualToString:@".."]) {
        return nil;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docURL = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];
    if (docURL) {
        [candidateURLs addObject:[docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]]];
    }
    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if (appGroupPath) {
        [candidateURLs addObject:[appGroupPath URLByAppendingPathComponent:[NSString stringWithFormat:@"LiveContainer/Data/Application/%@", dataUUID]]];
    }

    for (NSURL *candidateURL in candidateURLs) {
        NSString *containerInfoPath = [candidateURL.path stringByAppendingPathComponent:@"LCContainerInfo.plist"];
        if ([fm fileExistsAtPath:containerInfoPath]) {
            return containerInfoPath;
        }
    }
    return nil;
}

+ (nullable NSDictionary *)containerInfoForDataUUID:(NSString *)dataUUID {
    NSString *containerInfoPath = LCContainerInfoPathForDataUUID(dataUUID);
    if (containerInfoPath.length == 0) {
        return nil;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    return [info isKindOfClass:NSDictionary.class] ? info : nil;
}

+ (void)wipeStrictContainerForDataUUIDIfNeeded:(NSString *)dataUUID {
    NSString *containerInfoPath = LCContainerInfoPathForDataUUID(dataUUID);
    if (containerInfoPath.length > 0) {
        [self wipeStrictContainerIfNeededAtPath:containerInfoPath.stringByDeletingLastPathComponent force:NO];
    }
}
@end

//
//  SecItem.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>
#import "../../litehook/src/litehook.h"
#import "LCSharedUtils.h"

extern void* (*msHookFunction)(void *symbol, void *hook, void **old);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = NULL;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = NULL;
static SecKeyRef (*orig_SecKeyCreateRandomKey)(CFDictionaryRef parameters, CFErrorRef *error) = NULL;
static SecKeyRef (*orig_SecKeyCreateWithData)(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus (*orig_SecKeyGeneratePair)(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) = NULL;
#pragma clang diagnostic pop
static NSString* accessGroup = nil;
static NSString* containerId = nil;

static NSMutableDictionary *LCCopyMutableSecDict(CFDictionaryRef dict) {
    if (!dict) {
        return [NSMutableDictionary dictionary];
    }
    NSMutableDictionary *copy = [(__bridge NSDictionary *)dict mutableCopy];
    return copy ?: [NSMutableDictionary dictionary];
}

static BOOL LCQueryRequiresOmittedAccessGroup(CFDictionaryRef query) {
    if (!query) {
        return NO;
    }
    // securityd rejects kSecAttrAccessGroup when combined with persistent ref or item list queries.
    return CFDictionaryContainsKey(query, kSecValuePersistentRef) ||
           CFDictionaryContainsKey(query, kSecMatchItemList) ||
           CFDictionaryContainsKey(query, kSecUseItemList);
}

static void LCApplyIsolatedAccessGroupToNestedKeyAttrs(NSMutableDictionary *paramsCopy, id keyAttrKey) {
    if (accessGroup.length == 0) {
        return;
    }
    id subAttrs = paramsCopy[keyAttrKey];
    if ([subAttrs isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *mutableSub = [(NSDictionary *)subAttrs mutableCopy];
        mutableSub[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        paramsCopy[keyAttrKey] = mutableSub;
    }
}

static BOOL LCKeyParametersAreExplicitlyEphemeral(NSDictionary *params, BOOL defaultEphemeral) {
    if (![params isKindOfClass:NSDictionary.class]) {
        return defaultEphemeral;
    }
    id topPerm = params[(__bridge id)kSecAttrIsPermanent];
    id privAttrs = params[(__bridge id)kSecPrivateKeyAttrs];
    id pubAttrs = params[(__bridge id)kSecPublicKeyAttrs];
    id privPerm = [privAttrs isKindOfClass:NSDictionary.class] ? privAttrs[(__bridge id)kSecAttrIsPermanent] : nil;
    id pubPerm = [pubAttrs isKindOfClass:NSDictionary.class] ? pubAttrs[(__bridge id)kSecAttrIsPermanent] : nil;

    if (([privPerm isKindOfClass:NSNumber.class] && [privPerm boolValue]) ||
        ([pubPerm isKindOfClass:NSNumber.class] && [pubPerm boolValue])) {
        return NO;
    }
    if ([topPerm isKindOfClass:NSNumber.class]) {
        return ![topPerm boolValue];
    }
    if ([privPerm isKindOfClass:NSNumber.class] && ![privPerm boolValue] &&
        (!pubPerm || ([pubPerm isKindOfClass:NSNumber.class] && ![pubPerm boolValue]))) {
        return YES;
    }
    return defaultEphemeral;
}

static OSStatus new_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!orig_SecItemAdd) {
        return errSecUnimplemented;
    }
    NSMutableDictionary *attributesCopy = LCCopyMutableSecDict(attributes);
    if (accessGroup.length > 0) {
        attributesCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    CFTypeRef secClass = attributes ? CFDictionaryGetValue(attributes, kSecClass) : NULL;
    BOOL canAttachAlias = (secClass == NULL || CFEqual(secClass, kSecClassGenericPassword));
    BOOL injectedAlias = NO;
    if (canAttachAlias && containerId.length > 0 && attributesCopy[@"alis"] == nil) {
        // Tag generic passwords with containerId for per-container cleanup.
        attributesCopy[@"alis"] = containerId;
        injectedAlias = YES;
    }

    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    if (status == errSecParam && injectedAlias) {
        [attributesCopy removeObjectForKey:@"alis"];
        status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    }
    return status;
}

static OSStatus new_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!orig_SecItemCopyMatching) {
        return errSecUnimplemented;
    }
    if (LCQueryRequiresOmittedAccessGroup(query)) {
        return orig_SecItemCopyMatching(query, result);
    }
    NSMutableDictionary *queryCopy = LCCopyMutableSecDict(query);
    if (accessGroup.length > 0) {
        queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)queryCopy, result);
}

static OSStatus new_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!orig_SecItemUpdate) {
        return errSecUnimplemented;
    }
    CFDictionaryRef effectiveQuery = query;
    NSMutableDictionary *queryCopy = nil;
    if (!LCQueryRequiresOmittedAccessGroup(query)) {
        queryCopy = LCCopyMutableSecDict(query);
        if (accessGroup.length > 0) {
            queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        }
        effectiveQuery = (__bridge CFDictionaryRef)queryCopy;
    }

    NSMutableDictionary *updateCopy = LCCopyMutableSecDict(attributesToUpdate);
    [updateCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return orig_SecItemUpdate(effectiveQuery, (__bridge CFDictionaryRef)updateCopy);
}

static OSStatus new_SecItemDelete(CFDictionaryRef query) {
    if (!orig_SecItemDelete) {
        return errSecUnimplemented;
    }
    if (LCQueryRequiresOmittedAccessGroup(query)) {
        return orig_SecItemDelete(query);
    }
    NSMutableDictionary *queryCopy = LCCopyMutableSecDict(query);
    if (accessGroup.length > 0) {
        queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
}

static SecKeyRef new_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    if (!orig_SecKeyCreateRandomKey) {
        return NULL;
    }
    NSMutableDictionary *paramsCopy = LCCopyMutableSecDict(parameters);
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(paramsCopy, YES)) {
        paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(paramsCopy, (__bridge id)kSecPrivateKeyAttrs);
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(paramsCopy, (__bridge id)kSecPublicKeyAttrs);
    }
    return orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)paramsCopy, error);
}

static SecKeyRef new_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    if (!orig_SecKeyCreateWithData) {
        return NULL;
    }
    NSMutableDictionary *paramsCopy = LCCopyMutableSecDict(parameters);
    // SecKeyCreateWithData creates in-memory keys by default; only scope if permanent attributes are passed.
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(paramsCopy, YES)) {
        paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)paramsCopy, error);
}

static OSStatus new_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    if (!orig_SecKeyGeneratePair) {
        return errSecUnimplemented;
    }
    NSMutableDictionary *queryCopy = LCCopyMutableSecDict(parameters);
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(queryCopy, YES)) {
        queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(queryCopy, (__bridge id)kSecPrivateKeyAttrs);
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(queryCopy, (__bridge id)kSecPublicKeyAttrs);
    }
    return orig_SecKeyGeneratePair((__bridge CFDictionaryRef)queryCopy, publicKey, privateKey);
}

void SecItemGuestHooksInit(void)  {
    void *securityHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD);
    if (!securityHandle) {
        securityHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    }

    if (!orig_SecItemAdd) {
        orig_SecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))(securityHandle ? dlsym(securityHandle, "SecItemAdd") : NULL) ?: SecItemAdd;
    }
    if (!orig_SecItemCopyMatching) {
        orig_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))(securityHandle ? dlsym(securityHandle, "SecItemCopyMatching") : NULL) ?: SecItemCopyMatching;
    }
    if (!orig_SecItemUpdate) {
        orig_SecItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))(securityHandle ? dlsym(securityHandle, "SecItemUpdate") : NULL) ?: SecItemUpdate;
    }
    if (!orig_SecItemDelete) {
        orig_SecItemDelete = (OSStatus (*)(CFDictionaryRef))(securityHandle ? dlsym(securityHandle, "SecItemDelete") : NULL) ?: SecItemDelete;
    }
    if (!orig_SecKeyCreateRandomKey) {
        orig_SecKeyCreateRandomKey = (SecKeyRef (*)(CFDictionaryRef, CFErrorRef *))(securityHandle ? dlsym(securityHandle, "SecKeyCreateRandomKey") : NULL) ?: SecKeyCreateRandomKey;
    }
    if (!orig_SecKeyCreateWithData) {
        orig_SecKeyCreateWithData = (SecKeyRef (*)(CFDataRef, CFDictionaryRef, CFErrorRef *))(securityHandle ? dlsym(securityHandle, "SecKeyCreateWithData") : NULL) ?: SecKeyCreateWithData;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!orig_SecKeyGeneratePair) {
        orig_SecKeyGeneratePair = (OSStatus (*)(CFDictionaryRef, SecKeyRef *, SecKeyRef *))(securityHandle ? dlsym(securityHandle, "SecKeyGeneratePair") : NULL) ?: SecKeyGeneratePair;
    }
#pragma clang diagnostic pop

    const char *homeEnv = getenv("HOME");
    containerId = (homeEnv ? [NSString stringWithUTF8String:homeEnv] : NSHomeDirectory()).lastPathComponent;
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    NSInteger keychainGroupId = [infoDict[@"keychainGroupId"] isKindOfClass:NSNumber.class]
        ? [infoDict[@"keychainGroupId"] integerValue]
        : 0;
    if (keychainGroupId < 0) {
        keychainGroupId = 0;
    }

    accessGroup = nil;
    NSString* teamId = [LCSharedUtils teamIdentifier];
    if (teamId.length > 0 && orig_SecItemCopyMatching) {
        NSString *candidateGroup = (keychainGroupId == 0)
            ? [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", teamId]
            : [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared.%ld", teamId, (long)keychainGroupId];

        // Check if the dedicated guest access group is entitled.
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"NonExistentKey",
            (__bridge id)kSecAttrService: @"NonExistentService",
            (__bridge id)kSecAttrAccessGroup: candidateGroup,
            (__bridge id)kSecReturnData: @NO
        };
        OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
        if (status != errSecMissingEntitlement) {
            accessGroup = candidateGroup;
        } else {
            // Fall back to default guest group .shared (never leave unhooked if .shared is entitled).
            NSString *fallbackShared = [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", teamId];
            NSMutableDictionary *sharedProbe = [query mutableCopy];
            sharedProbe[(__bridge id)kSecAttrAccessGroup] = fallbackShared;
            if (orig_SecItemCopyMatching((__bridge CFDictionaryRef)sharedProbe, NULL) != errSecMissingEntitlement) {
                accessGroup = fallbackShared;
            } else {
                // Probe app-identifier group(s) when keychain-access-groups were stripped by a signer.
                NSString *lcBundleId = NSUserDefaults.lcMainBundle.bundleIdentifier;
                NSString *mainBundleId = NSBundle.mainBundle.bundleIdentifier;
                NSMutableArray<NSString *> *bundleCandidates = [NSMutableArray array];
                if (lcBundleId.length > 0) {
                    [bundleCandidates addObject:lcBundleId];
                }
                if (mainBundleId.length > 0 && ![bundleCandidates containsObject:mainBundleId]) {
                    [bundleCandidates addObject:mainBundleId];
                }
                for (NSString *bundleId in bundleCandidates) {
                    NSString *appIdGroup = [NSString stringWithFormat:@"%@.%@", teamId, bundleId];
                    sharedProbe[(__bridge id)kSecAttrAccessGroup] = appIdGroup;
                    if (orig_SecItemCopyMatching((__bridge CFDictionaryRef)sharedProbe, NULL) != errSecMissingEntitlement) {
                        accessGroup = appIdGroup;
                        break;
                    }
                }
            }
        }
    }

    if (orig_SecItemAdd) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecItemAdd, new_SecItemAdd, nil);
    if (orig_SecItemCopyMatching) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecItemCopyMatching, new_SecItemCopyMatching, nil);
    if (orig_SecItemUpdate) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecItemUpdate, new_SecItemUpdate, nil);
    if (orig_SecItemDelete) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecItemDelete, new_SecItemDelete, nil);
    if (orig_SecKeyCreateRandomKey) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecKeyCreateRandomKey, new_SecKeyCreateRandomKey, nil);
    if (orig_SecKeyCreateWithData) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecKeyCreateWithData, new_SecKeyCreateWithData, nil);
    if (orig_SecKeyGeneratePair) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_SecKeyGeneratePair, new_SecKeyGeneratePair, nil);
}

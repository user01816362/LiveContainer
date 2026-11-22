//
//  SecItem.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>
#import "../../litehook/src/litehook.h"
#import "LCSharedUtils.h"

extern void* (*msHookFunction)(void *symbol, void *hook, void **old);
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = SecItemAdd;
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = SecItemCopyMatching;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = SecItemUpdate;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = SecItemDelete;
static SecKeyRef (*orig_SecKeyCreateRandomKey)(CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateRandomKey;
static SecKeyRef (*orig_SecKeyCreateWithData)(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateWithData;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus (*orig_SecKeyGeneratePair)(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) = SecKeyGeneratePair;
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
    NSMutableDictionary *paramsCopy = LCCopyMutableSecDict(parameters);
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(paramsCopy, YES)) {
        paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(paramsCopy, (__bridge id)kSecPrivateKeyAttrs);
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(paramsCopy, (__bridge id)kSecPublicKeyAttrs);
    }
    return orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)paramsCopy, error);
}

static SecKeyRef new_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = LCCopyMutableSecDict(parameters);
    // SecKeyCreateWithData creates in-memory keys by default; only scope if permanent attributes are passed.
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(paramsCopy, YES)) {
        paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)paramsCopy, error);
}

static OSStatus new_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    NSMutableDictionary *queryCopy = LCCopyMutableSecDict(parameters);
    if (accessGroup.length > 0 && !LCKeyParametersAreExplicitlyEphemeral(queryCopy, YES)) {
        queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(queryCopy, (__bridge id)kSecPrivateKeyAttrs);
        LCApplyIsolatedAccessGroupToNestedKeyAttrs(queryCopy, (__bridge id)kSecPublicKeyAttrs);
    }
    return orig_SecKeyGeneratePair((__bridge CFDictionaryRef)queryCopy, publicKey, privateKey);
}

void SecItemGuestHooksInit(void)  {
    const char *homeEnv = getenv("HOME");
    containerId = (homeEnv ? [NSString stringWithUTF8String:homeEnv] : NSHomeDirectory()).lastPathComponent;
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    NSInteger keychainGroupId = [infoDict[@"keychainGroupId"] isKindOfClass:NSNumber.class]
        ? [infoDict[@"keychainGroupId"] integerValue]
        : 0;
    if (keychainGroupId < 0) {
        keychainGroupId = 0;
    }

    NSString* teamId = [LCSharedUtils teamIdentifier];
    if (teamId.length > 0) {
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
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
        if (status != errSecMissingEntitlement) {
            accessGroup = candidateGroup;
        } else {
            // Fall back to default guest group .shared (never leave unhooked if .shared is entitled).
            NSString *fallbackShared = [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", teamId];
            NSMutableDictionary *sharedProbe = [query mutableCopy];
            sharedProbe[(__bridge id)kSecAttrAccessGroup] = fallbackShared;
            if (SecItemCopyMatching((__bridge CFDictionaryRef)sharedProbe, NULL) != errSecMissingEntitlement) {
                accessGroup = fallbackShared;
            } else {
                // Keep hooks active using app-id group when keychain-access-groups were stripped by a signer.
                NSString *bundleId = NSUserDefaults.lcMainBundle.bundleIdentifier ?: NSBundle.mainBundle.bundleIdentifier;
                if (bundleId.length > 0) {
                    accessGroup = [NSString stringWithFormat:@"%@.%@", teamId, bundleId];
                }
            }
        }
    }

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, new_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, new_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, new_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, new_SecItemDelete, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, new_SecKeyCreateRandomKey, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, new_SecKeyCreateWithData, nil);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, new_SecKeyGeneratePair, nil);
#pragma clang diagnostic pop
}

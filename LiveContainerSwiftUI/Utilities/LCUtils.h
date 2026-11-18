#import <Foundation/Foundation.h>
#import "LCMachOUtils.h"
#import "utils.h"
@import UIKit;

typedef NS_ENUM(NSInteger, Store){
    SideStore = 0,
    AltStore = 1,
    ADP = 2,
    Unknown = -1
};

void refreshFile(NSString * _Null_unspecified execPath);
int dyld_get_program_sdk_version(void);
uint32_t dyld_get_sdk_version(const struct mach_header * _Null_unspecified mh);

@interface PKZipArchiver : NSObject

- (NSData * _Null_unspecified)zippedDataForURL:(NSURL * _Null_unspecified)url;

@end

@interface UIDevice(private)
@property(readonly, null_unspecified) NSString* buildVersion;
@end

@interface LCUtils : NSObject

+ (void)validateJITLessSetupWithCompletionHandler:(void (^ NS_SWIFT_SENDABLE _Nonnull)(BOOL success, NSError * _Nullable error))completionHandler;
+ (nullable NSURL *)archiveIPAWithBundleName:(nonnull NSString*)newBundleName includingExtraInfoDict:(nullable NSDictionary *)extraInfoDict error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSData *)certificateData;
+ (void)launchMultitaskGuestApp:(nonnull NSString *)displayName completionHandler:(void (^ NS_SWIFT_SENDABLE _Nullable)(NSNumber * _Nullable pid, NSError * _Nullable error))completionHandler;


+ (nullable NSProgress *)signAppBundleWithZSign:(nonnull NSURL *)path completionHandler:(void (^ NS_SWIFT_SENDABLE _Nonnull)(BOOL success, NSError * _Nullable error))completionHandler;
+ (nullable NSProgress *)signFilesWithZSignWithURLs:(nonnull NSArray<NSURL*>*)urls completionHandler:(void (^ NS_SWIFT_SENDABLE _Nonnull)(BOOL success, NSError * _Nullable error))completionHandler;
+ (nullable NSString*)getCertTeamIdWithKeyData:(nonnull NSData*)keyData password:(nullable NSString*)password;
+ (int)validateCertificateWithCompletionHandler:(void(^ NS_SWIFT_SENDABLE _Nonnull)(int status, NSDate * _Nullable expirationDate, NSString * _Nullable organizationalUnitName, NSString * _Nullable error))completionHandler;

+ (BOOL)isTXMScriptRequired;
+ (NSString * _Null_unspecified)base64EncodedUniversalJITScript;

+ (BOOL)isAppGroupAltStoreLike;
+ (Store)store;
+ (NSString * _Null_unspecified)appUrlScheme;
+ (NSString * _Null_unspecified)storeInstallURLScheme;
+ (NSString * _Null_unspecified)getVersionInfo;
+ (NSString * _Null_unspecified)liveProcessBundleIdentifier;
+ (NSData * _Null_unspecified)bookmarkForURL:(NSURL * _Null_unspecified)url;
+ (BOOL)isAppSchemeInstalled:(NSString * _Null_unspecified)scheme;
@end

@interface NSUserDefaults(LiveContainerSideStore)
+ (bool)sideStoreExist;
@end

@interface LCP12CertHelper : NSObject

- (instancetype _Null_unspecified)initWithP12Data:(NSData * _Null_unspecified)p12Data password:(NSString * _Null_unspecified)password error:(NSError * _Null_unspecified * _Null_unspecified)error;
- (NSDate * _Null_unspecified)getNotValidityNotAfterWithError:(NSError * _Null_unspecified * _Null_unspecified)error;
- (NSString * _Null_unspecified)getOrgnizationUnitWithError:(NSError * _Null_unspecified * _Null_unspecified)error;

@end

typedef NS_ENUM(NSInteger, GeneratedIconStyle){
    Original = -1,
    Light = 0,
    Dark = 1
};

@interface UIImage(LiveContainer)
+ (instancetype _Null_unspecified)generateIconForBundleURL:(NSURL * _Null_unspecified)url style:(GeneratedIconStyle)style hasBorder:(BOOL)hasBorder;
@end
BOOL saveCGImage(CGImageRef _Null_unspecified image, NSURL * _Null_unspecified url);
CGImageRef _Null_unspecified loadCGImageFromURL(NSURL * _Null_unspecified url);
NSNumber * _Null_unspecified LCGetDefaultClassicMode(NSURL * _Null_unspecified appURL);

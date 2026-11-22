@import Foundation;

@interface LCSharedUtils : NSObject
+ (nullable NSString *)teamIdentifier;
+ (nullable NSString *)appGroupID;
+ (nullable NSURL *)appGroupPath;
+ (nullable NSString *)hostKeychainAccessGroup;
+ (nullable NSData *)certificateData;
+ (nullable NSString *)certificatePassword;
+ (BOOL)isJITLessConfigured;
+ (void)saveCertificateData:(nonnull NSData *)certData password:(nonnull NSString *)password;
+ (void)clearCertificateData;
+ (void)migrateCertificateToHostKeychainIfNeeded;
+ (nullable NSUUID *)webKitStoreIdentifierForContainerUUID:(nonnull NSString *)dataUUID;
+ (void)removeWebKitDataStoreForContainerUUID:(nonnull NSString *)dataUUID;
+ (void)removeKeychainItemsForContainerUUID:(nonnull NSString *)dataUUID
                            keychainGroupId:(NSInteger)keychainGroupId
                            wipeEntireGroup:(BOOL)wipeEntireGroup;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (void)setWebPageUrlForNextLaunch:(NSString*)urlString;
+ (BOOL)isLCSchemeInUse:(NSString*)lc;
+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName;
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57;
+ (void)moveSharedAppFolderBack;
+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut;
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID;
+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId;
+ (NSArray<NSString*>*)lcUnorderedUrlSchemes;
+ (NSArray<NSString*>*)lcUrlSchemes;
+ (void)cacheProcessEnvironmentPaths;
+ (NSString *)cachedLcHomePath;
+ (NSString *)cachedLpHomePath;
+ (NSString *)cachedGlobalTweaksFolderPath;
+ (void)ensureContainerDirectoriesAtPath:(NSString *)containerPath;
+ (void)wipeStrictContainerIfNeededAtPath:(NSString *)containerPath force:(BOOL)force;
+ (void)wipeStrictContainerForDataUUIDIfNeeded:(NSString *)dataUUID;
+ (nullable NSDictionary *)containerInfoForDataUUID:(nonnull NSString *)dataUUID;
@end

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCUtils.h"

typedef NS_ENUM(NSInteger, LCOrientationLock){
    Disabled = 0,
    Landscape = 1,
    Portrait = 2
};

typedef NS_ENUM(NSInteger, MultitaskSpecified){
    MultitaskSpecifiedDefault = 0,
    MultitaskSpecifiedNo = 1,
    MultitaskSpecifiedYes = 2
};


@interface LCAppInfo : NSObject {
    NSMutableDictionary * _Null_unspecified _info;
    NSMutableDictionary * _Null_unspecified _infoPlist;
    NSString * _Null_unspecified _bundlePath;
}
@property (null_unspecified) NSString* relativeBundlePath;
@property bool isShared;
@property bool isJITNeeded;
@property bool helperProcessesSupport;
@property bool classicMode;
@property (nonatomic, readonly) NSUInteger defaultClassicMode;
@property bool isLocked;
@property bool isHidden;
@property bool doSymlinkInbox;
@property bool hideLiveContainer;
@property bool dontLoadTweakLoader;
@property bool dontInjectTweakLoader;
@property LCOrientationLock orientationLock;
@property MultitaskSpecified multitaskSpecified;
@property bool fixFilePickerNew;
@property bool fixLocalNotification;
@property bool fixBackgroundTaskIdentifiers;
@property bool doUseLCBundleId;
@property (null_unspecified) NSString* selectedLanguage;
@property (null_unspecified) NSString* dataUUID;
@property (null_unspecified) NSString* tweakFolder;
@property (null_unspecified) NSArray<NSDictionary*>* containerInfo;
@property bool autoSaveDisabled;
@property bool dontSign;
@property bool spoofSDKVersion;
@property (nonatomic, strong, null_unspecified) NSString* jitLaunchScriptJs;
@property (nonatomic, strong, null_unspecified) NSString* selected32BitEmulator;
@property (nonatomic, copy, null_unspecified) NSString* sourceURL;
@property (nonatomic, copy, null_unspecified) NSString* installedSourceVersion;
@property (nonatomic, copy, null_unspecified) NSString* installedSourceBuildVersion;
@property (nonatomic, copy, null_unspecified) NSString* ignoredUpdateVersion;
@property bool debugModeEnabled;
@property bool exportTweakSymbolsGlobally;
@property (nullable) NSDate* lastLaunched;
@property (nullable) NSDate* installationDate;
@property (null_unspecified) NSString* remark;
@property bool autoCleanCacheOnLaunch;
@property (null_unspecified) NSDate* lastAutoCleanDate;
@property long long autoCleanTotalBytesSaved;
@property bool is32bit;
@property(readonly) bool is32bitEmulator;
@property (null_unspecified) UIColor* cachedColor;
@property (null_unspecified) UIColor* cachedColorDark;
@property (null_unspecified) UIImage* cachedIcon;
@property (null_unspecified) UIImage* cachedIconDark;

- (void)setBundlePath:(NSString * _Null_unspecified)newBundlePath;
- (NSMutableDictionary * _Null_unspecified)info;
- (UIImage * _Null_unspecified)iconIsDarkIcon:(BOOL)isDarkIcon;
- (void)clearIconCache;
- (NSString * _Null_unspecified)displayName;
- (NSString * _Null_unspecified)bundlePath;
- (NSString * _Null_unspecified)bundleIdentifier;
- (NSString * _Null_unspecified)version;
- (NSString * _Null_unspecified)shortVersion;
- (NSString * _Null_unspecified)buildVersion;
- (nullable NSString *)bundleName;
- (nullable NSString *)executableName;
- (nullable NSString *)minimumOSVersion;
- (BOOL)hasOriginalMetadataBackup;
- (nonnull NSDictionary<NSString *, id> *)editableInfoPlistDictionary;
- (nullable NSDictionary<NSString *, id> *)originalInfoPlistDictionary;
- (nonnull NSArray<NSString *> *)appExtensionNames;
- (BOOL)applyCustomMetadataWithDisplayName:(nullable NSString *)displayName
                                bundleName:(nullable NSString *)bundleName
                          bundleIdentifier:(nullable NSString *)bundleIdentifier
                              shortVersion:(nullable NSString *)shortVersion
                              buildVersion:(nullable NSString *)buildVersion
                          minimumOSVersion:(nullable NSString *)minimumOSVersion
                  updateExtensionBundleIds:(BOOL)updateExtensions
                      updateLocalizedNames:(BOOL)updateLocalized
                                     error:(NSError * _Nullable * _Nullable)error;
- (BOOL)replaceInfoPlistWithDictionary:(nonnull NSDictionary<NSString *, id> *)newInfoPlist
                                 error:(NSError * _Nullable * _Nullable)error;
- (BOOL)resetInfoPlistToOriginalWithError:(NSError * _Nullable * _Nullable)error;
- (void)reloadInfoPlistFromDisk;
- (NSMutableArray<NSString *> * _Null_unspecified)urlSchemes;
- (instancetype _Null_unspecified)initWithBundlePath:(NSString * _Null_unspecified)bundlePath;
- (UIImage * _Null_unspecified)generateLiveContainerWrappedIconWithStyle:(GeneratedIconStyle)style;
- (NSDictionary * _Null_unspecified)generateWebClipConfigWithContainerId:(NSString * _Null_unspecified)containerId iconStyle:(GeneratedIconStyle)style;
- (void)save;
- (void)patchExecAndSignIfNeedWithCompletionHandler:(void(^ NS_SWIFT_SENDABLE _Nonnull)(bool success, NSString * _Nullable errorInfo))completetionHandler progressHandler:(void(^ NS_SWIFT_SENDABLE _Nullable)(NSProgress * _Nonnull progress))progressHandler  forceSign:(BOOL)forceSign;
- (void)recordAutoCleanWithBytesSaved:(long long)bytesSaved;
- (long long)autoCleanBytesSavedInLastDays:(NSInteger)days;
- (long long)lastAutoCleanBytesSaved;
- (void)resetAutoCleanStats;
@end

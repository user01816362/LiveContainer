@import CommonCrypto;
@import MachO;

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCAppInfo.h"
#import "LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"


@implementation LCAppInfo

- (instancetype)initWithBundlePath:(NSString*)bundlePath {
    self = [super init];
    self.isShared = false;
	if(self) {
        _bundlePath = bundlePath;
        _infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
        _info = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];
        if(!_info) {
            _info = [[NSMutableDictionary alloc] init];
        }
        if(!_infoPlist) {
            _infoPlist = [[NSMutableDictionary alloc] init];
        }
        
        // migrate old appInfo
        if(_infoPlist[@"LCPatchRevision"] && [_info count] == 0) {
            NSArray* lcAppInfoKeys = @[
                @"LCPatchRevision",
                @"LCOrignalBundleIdentifier",
                @"LCDataUUID",
                @"LCTweakFolder",
                @"LCJITLessSignID",
                @"LCSelectedLanguage",
                @"LCExpirationDate",
                @"LCTeamId",
                @"isJITNeeded",
                @"isLocked",
                @"isHidden",
                @"doUseLCBundleId",
                @"doSymlinkInbox",
                @"bypassAssertBarrierOnQueue",
                @"signer",
                @"LCOrientationLock",
                @"cachedColor",
                @"LCContainers",
                @"hideLiveContainer",
                @"jitLaunchScriptJs"
            ];
            for(NSString* key in lcAppInfoKeys) {
                _info[key] = _infoPlist[key];
                [_infoPlist removeObjectForKey:key];
            }
            [_infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
            [self save];
        }
        
        // fix bundle id and execName if crash when signing
        if (_infoPlist[@"LCBundleIdentifier"]) {
            _infoPlist[@"CFBundleExecutable"] = _infoPlist[@"LCBundleExecutable"];
            _infoPlist[@"CFBundleIdentifier"] = _infoPlist[@"LCBundleIdentifier"];
            [_infoPlist removeObjectForKey:@"LCBundleExecutable"];
            [_infoPlist removeObjectForKey:@"LCBundleIdentifier"];
            [_infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
        }

        _autoSaveDisabled = false;
    }
    return self;
}

- (void)setBundlePath:(NSString*)newBundlePath {
    _bundlePath = newBundlePath;
}

- (NSMutableArray<NSString *>*)urlSchemes {
    // find all url schemes
    NSMutableArray* urlSchemes = [[NSMutableArray alloc] init];
    id rawUrlTypes = _infoPlist[@"CFBundleURLTypes"];
    if (![rawUrlTypes isKindOfClass:NSArray.class]) {
        return urlSchemes;
    }

    for (id item in (NSArray *)rawUrlTypes) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        id schemes = ((NSDictionary *)item)[@"CFBundleURLSchemes"];
        if (![schemes isKindOfClass:NSArray.class]) {
            continue;
        }
        for (id scheme in (NSArray *)schemes) {
            if ([scheme isKindOfClass:NSString.class] && [(NSString *)scheme length] > 0) {
                [urlSchemes addObject:scheme];
            }
        }
    }

    return urlSchemes;
}

- (NSString*)displayName {
    id disp = _infoPlist[@"CFBundleDisplayName"];
    if ([disp isKindOfClass:NSString.class] && [(NSString *)disp length] > 0) {
        return disp;
    }
    id name = _infoPlist[@"CFBundleName"];
    if ([name isKindOfClass:NSString.class] && [(NSString *)name length] > 0) {
        return name;
    }
    id exec = _infoPlist[@"CFBundleExecutable"];
    if ([exec isKindOfClass:NSString.class] && [(NSString *)exec length] > 0) {
        return exec;
    }
    return @"App Corrupted, Please Reinstall This App";
}

- (NSString*)shortVersion {
    id val = _infoPlist[@"CFBundleShortVersionString"];
    return [val isKindOfClass:NSString.class] ? val : nil;
}

- (NSString*)buildVersion {
    id val = _infoPlist[@"CFBundleVersion"];
    return [val isKindOfClass:NSString.class] ? val : nil;
}

- (NSString*)version {
    NSString* version = [self shortVersion];
    if (!version) {
        version = [self buildVersion];
    }
    return version ?: @"Unknown";
}

- (NSString*)bundleIdentifier {
    id ans = nil;
    if([self doUseLCBundleId]) {
        ans = _info[@"LCOrignalBundleIdentifier"];
    } else {
        ans = _infoPlist[@"CFBundleIdentifier"];
    }
    if([ans isKindOfClass:NSString.class] && [(NSString *)ans length] > 0) {
        return ans;
    } else {
        return @"Unknown";
    }
}

- (NSString*)dataUUID {
    return _info[@"LCDataUUID"];
}

- (NSString*)tweakFolder {
    return _info[@"LCTweakFolder"];
}

- (void)setDataUUID:(NSString *)uuid {
    _info[@"LCDataUUID"] = uuid;
    [self save];
}

- (void)setTweakFolder:(NSString *)tweakFolder {
    _info[@"LCTweakFolder"] = tweakFolder;
    [self save];
}

- (NSString*)selectedLanguage {
    return _info[@"LCSelectedLanguage"];
}

- (void)setSelectedLanguage:(NSString *)selectedLanguage {
    if([selectedLanguage isEqualToString: @""]) {
        _info[@"LCSelectedLanguage"] = nil;
    } else {
        _info[@"LCSelectedLanguage"] = selectedLanguage;
    }
    
    [self save];
}

- (NSString*)bundlePath {
    return _bundlePath;
}

- (NSMutableDictionary*)info {
    return _info;
}

- (UIImage*)iconIsDarkIcon:(BOOL)isDarkIcon {
    // if icon is already loaded in memory, return it
    if(_cachedIcon && !isDarkIcon) {
        return _cachedIcon;
    } else if (_cachedIconDark && isDarkIcon) {
        return _cachedIconDark;
    }
    
    // check if icon is cached on disk
    UIImage* uiIcon;
    NSString* cachedIconPath;
    if(isDarkIcon) {
        cachedIconPath = [_bundlePath stringByAppendingPathComponent:@"LCAppIconDark.png"];
    } else {
        cachedIconPath = [_bundlePath stringByAppendingPathComponent:@"LCAppIconLight.png"];
    }
    NSURL* cachedIconUrl = [NSURL fileURLWithPath:cachedIconPath];
    
    if([NSFileManager.defaultManager fileExistsAtPath:cachedIconPath]) {
        CGImageRef imageRef = loadCGImageFromURL(cachedIconUrl);
        if (imageRef) {
            uiIcon = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
        }
    }
    
    // generate and save icon cache to disk
    if(!uiIcon) {
        uiIcon = [UIImage generateIconForBundleURL:[NSURL fileURLWithPath:_bundlePath] style:isDarkIcon hasBorder:YES];
        saveCGImage([uiIcon CGImage], cachedIconUrl);
    }
    
    // cache icon to memory
    if(isDarkIcon) {
        _cachedIconDark = uiIcon;
    } else {
        _cachedIcon = uiIcon;
    }

    return uiIcon;

}

- (void)clearIconCache {
    NSString* lightModeIconPath = [_bundlePath stringByAppendingPathComponent:@"LCAppIconLight.png"];
    NSString* darkModeIconPath = [_bundlePath stringByAppendingPathComponent:@"LCAppIconDark.png"];
    [NSFileManager.defaultManager removeItemAtPath:lightModeIconPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:darkModeIconPath error:nil];
    [self setCachedColor:nil];
    [self setCachedColorDark:nil];
    _cachedIcon = nil;
    _cachedIconDark = nil;
}

- (UIImage *)generateLiveContainerWrappedIconWithStyle:(GeneratedIconStyle)style {
    UIImage* icon = [UIImage generateIconForBundleURL:[NSURL fileURLWithPath:_bundlePath] style:style hasBorder:NO];
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"LCFrameShortcutIcons"]) {
        return icon;
    }

    UIImage *lcIcon = [UIImage imageNamed:@"AppIcon60x60@2x"];
    if (!lcIcon || lcIcon.size.width <= 0 || lcIcon.size.height <= 0) {
        return icon;
    }
    CGFloat iconXY = (lcIcon.size.width - 40) / 2;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:lcIcon.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [lcIcon drawInRect:CGRectMake(0, 0, lcIcon.size.width, lcIcon.size.height)];
        CGRect rect = CGRectMake(iconXY, iconXY, 40, 40);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:7] addClip];
        [icon drawInRect:rect];
    }];
}

- (NSDictionary *)generateWebClipConfigWithContainerId:(NSString*)containerId iconStyle:(GeneratedIconStyle)style{
    NSString* appClipUrl;
    if(containerId) {
        appClipUrl = [NSString stringWithFormat:@"livecontainer://livecontainer-launch?bundle-name=%@&container-folder-name=%@", self.bundlePath.lastPathComponent, containerId];
    } else {
        appClipUrl = [NSString stringWithFormat:@"livecontainer://livecontainer-launch?bundle-name=%@", self.bundlePath.lastPathComponent];
    }
    
    UIImage* icon = [self generateLiveContainerWrappedIconWithStyle:style];
    
    NSDictionary *payload = @{
        @"FullScreen": @YES,
        @"Icon": UIImagePNGRepresentation(icon),
        @"IgnoreManifestScope": @YES,
        @"IsRemovable": @YES,
        @"Label": self.displayName,
        @"PayloadDescription": [NSString stringWithFormat:@"Web Clip for launching %@ (%@) in LiveContainer", self.displayName, self.bundlePath.lastPathComponent],
        @"PayloadDisplayName": self.displayName,
        @"PayloadIdentifier": self.bundleIdentifier,
        @"PayloadType": @"com.apple.webClip.managed",
        @"PayloadUUID": NSUUID.UUID.UUIDString,
        @"PayloadVersion": @(1),
        @"Precomposed": @NO,
        @"toPayloadOrganization": @"LiveContainer",
        @"URL": appClipUrl
    };
    return @{
        @"ConsentText": @{
            @"default": [NSString stringWithFormat:@"This profile installs a web clip which opens %@ (%@) in LiveContainer", self.displayName, self.bundlePath.lastPathComponent]
        },
        @"PayloadContent": @[payload],
        @"PayloadDescription": payload[@"PayloadDescription"],
        @"PayloadDisplayName": self.displayName,
        @"PayloadIdentifier": self.bundleIdentifier,
        @"PayloadOrganization": @"LiveContainer",
        @"PayloadRemovalDisallowed": @(NO),
        @"PayloadType": @"Configuration",
        @"PayloadUUID": @"345097fb-d4f7-4a34-ab90-2e3f1ad62eed",
        @"PayloadVersion": @(1),
    };
}

- (void)save {
    if(!_autoSaveDisabled) {
        [_info writeBinToFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", _bundlePath] atomically:YES];
    }

}

- (void)patchExecAndSignIfNeedWithCompletionHandler:(void(^)(bool success, NSString* errorInfo))completetionHandler progressHandler:(void(^)(NSProgress* progress))progressHandler forceSign:(BOOL)forceSign {
    [NSUserDefaults.standardUserDefaults setObject:@(YES) forKey:@"SigningInProgress"];
    NSString *appPath = self.bundlePath;

    NSMutableDictionary *info = _info;
    NSMutableDictionary *infoPlist = _infoPlist;
    if (!info) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"Info.plist not found");
        return;
    }
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString *execPath = [NSString stringWithFormat:@"%@/%@", appPath, _infoPlist[@"CFBundleExecutable"]];
    
    // Update patch
    int currentPatchRev = 7;
    bool needPatch = [info[@"LCPatchRevision"] intValue] < currentPatchRev;
    if (needPatch || forceSign) {
        // copy-delete-move to avoid EXC_BAD_ACCESS (SIGKILL - CODESIGNING)
        NSString *backupPath = [NSString stringWithFormat:@"%@/%@_LiveContainerPatchBackUp", appPath, _infoPlist[@"CFBundleExecutable"]];
        NSError *err;
        [fm copyItemAtPath:execPath toPath:backupPath error:&err];
        [fm removeItemAtPath:execPath error:&err];
        [fm moveItemAtPath:backupPath toPath:execPath error:&err];
    }
    
    bool is32bit = false;
    if (needPatch) {
        __block bool has64bitSlice = NO;
        __block bool isEncrypted = false;
        NSString *error = LCParseMachO(execPath.UTF8String, false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
            if(header->cputype == CPU_TYPE_ARM64) {
                has64bitSlice |= YES;
                int patchResult = LCPatchExecSlice(path, header, ![self dontInjectTweakLoader]);
                if(patchResult & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER) {
                    info[@"LCTweakLoaderCantInject"] = @YES;
                    info[@"dontInjectTweakLoader"] = @YES;
                }
                if(patchResult & (PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH | PATCH_EXEC_RESULT_MISALIGNED_LINKEDIT_STRING_POOL)) {
                    info[@"segCountMismatch"] = @YES;
                }
            }
            isEncrypted |= LCIsMachOEncrypted(header);
        });
        is32bit = !has64bitSlice;
        if (isEncrypted) {
            error = @"The app you tried to install is encrypted. Please provide decrypted app.";
        }
        if (error) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
            completetionHandler(NO, error);
            return;
        }
        self.is32bit = is32bit;
        if (!is32bit) {
            LCPatchAppBundleFixupARM64eSlice([NSURL fileURLWithPath:appPath]);
        } else {
            self.isJITNeeded = YES;
            self.classicMode = YES;
            self.spoofSDKVersion = YES;
        }
        error = [self patchGuestExtensions];
        if (error) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
            completetionHandler(NO, error);
            return;
        }
        info[@"LCPatchRevision"] = @(currentPatchRev);
        forceSign = true;
        
        [self save];
    }

    if (!LCSharedUtils.certificatePassword || self.is32bit || self.dontSign) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(YES, nil);
        return;
    }

    // check if iOS think this app's signature is valid, if so, we can skip any further signature check
    NSString* executablePath = [appPath stringByAppendingPathComponent:infoPlist[@"CFBundleExecutable"]];
    if(!forceSign) {
        bool signatureValid = checkCodeSignature(executablePath.UTF8String);
        
        if(signatureValid) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
            completetionHandler(YES, nil);
            return;
        }
    }
    
    if (!LCUtils.certificateData) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"lc.signer.noCertificateFoundErr");
        return;
    }
    
    // Sign app if JIT-less is set up
        NSURL *appPathURL = [NSURL fileURLWithPath:appPath];
            void (^signCompletionHandler)(BOOL success, NSError *error)  = ^(BOOL success, NSError *_Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
                    if(!success) {
                        completetionHandler(NO, error.localizedDescription);
                    } else {
                        bool signatureValid = checkCodeSignature(executablePath.UTF8String);
                        if(signatureValid) {
                            completetionHandler(YES, [error localizedDescription]);
                        } else {
                            completetionHandler(NO, @"lc.signer.latestCertificateInvalidErr");
                        }
                    }
                    
                });
            };
            
            __block NSProgress *progress = [LCUtils signAppBundleWithZSign:appPathURL completionHandler:signCompletionHandler];

            if (progress && progressHandler) {
                progressHandler(progress);
            }
}

- (NSString *)patchGuestExtensions {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *pluginsPath = [self.bundlePath stringByAppendingPathComponent:@"PlugIns"];
    NSArray *plugins = [fm contentsOfDirectoryAtPath:pluginsPath error:nil];
    for (NSString *name in plugins) {
        if (![name.pathExtension isEqualToString:@"appex"]) continue;
        NSString *bundlePath = [pluginsPath stringByAppendingPathComponent:name];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];

        // copy remove rename
        NSString *executable = plist[@"CFBundleExecutable"];
        if (![executable isKindOfClass:NSString.class] || executable.length == 0) continue;
        NSString *path = [bundlePath stringByAppendingPathComponent:executable];
        NSString *temporaryPath = [path stringByAppendingString:@".lcpatch"];
        NSError *fileError = nil;
        [fm removeItemAtPath:temporaryPath error:nil];
        if (![fm copyItemAtPath:path toPath:temporaryPath error:&fileError]) return fileError.localizedDescription;
        
        __block BOOL hasARM64 = NO;
        __block BOOL encrypted = NO;
        __block BOOL mismatch = NO;
        NSString *error = LCParseMachO(temporaryPath.fileSystemRepresentation, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
            if (header->cputype != CPU_TYPE_ARM64) return;
            hasARM64 = YES;
            encrypted |= LCIsMachOEncrypted(header);
            if (!encrypted) {
                int patchResult = LCPatchExecSlice(slicePath, header, false);
                mismatch |= (patchResult & (PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH | PATCH_EXEC_RESULT_MISALIGNED_LINKEDIT_STRING_POOL)) != 0;
            }
        });
        if (!error && (!hasARM64 || encrypted)) {
            error = [NSString stringWithFormat:@"%@ requires a decrypted arm64 executable", name];
        }
        if (!error && ![fm replaceItemAtURL:[NSURL fileURLWithPath:path] withItemAtURL:[NSURL fileURLWithPath:temporaryPath] backupItemName:nil options:0 resultingItemURL:nil error:&fileError]) {
            error = fileError.localizedDescription;
        }
        [fm removeItemAtPath:temporaryPath error:nil];
        if (error) return error;
        // Keep extension-specific loader information separate from the app's.
        [@{@"segCountMismatch": @(mismatch)} writeToFile:[bundlePath stringByAppendingPathComponent:@"LCAppExtension.plist"] atomically:YES];
    }
    return nil;
}

- (bool)isJITNeeded {
    if(_info[@"isJITNeeded"] != nil) {
        return [_info[@"isJITNeeded"] boolValue];
    } else {
        return NO;
    }
}

- (bool)helperProcessesSupport {
    // Preserve settings saved before this feature was renamed.
    return [_info[@"helperProcessesSupport"] boolValue];
}

- (void)setHelperProcessesSupport:(bool)enabled {
    _info[@"helperProcessesSupport"] = @(enabled);
    [self save];
}
- (void)setIsJITNeeded:(bool)isJITNeeded {
    _info[@"isJITNeeded"] = [NSNumber numberWithBool:isJITNeeded];
    [self save];
    
}

- (bool)classicMode {
    return [_info[@"classicMode"] boolValue];
}

- (void)setClassicMode:(bool)classicMode {
    _info[@"classicMode"] = @(classicMode);

    if(classicMode) {
        [self defaultClassicMode];
    } else {
        _info[@"LCClassicModeCache"] = nil;
        [self save];
    }
}

- (NSUInteger)defaultClassicMode {
    if(!self.classicMode) {
        return 0;
    }

    NSInteger systemMajorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSDictionary *cache = _info[@"LCClassicModeCache"];
    NSNumber *cachedMode = cache[@"defaultClassicMode"];
    NSNumber *cachedSystemMajorVersion = cache[@"systemMajorVersion"];
    if([cachedMode isKindOfClass:NSNumber.class] &&
       [cachedSystemMajorVersion isKindOfClass:NSNumber.class] &&
       cachedSystemMajorVersion.integerValue == systemMajorVersion) {
        return cachedMode.unsignedIntegerValue;
    }

    NSNumber *mode = LCGetDefaultClassicMode([NSURL fileURLWithPath:self.bundlePath]);

    _info[@"LCClassicModeCache"] = @{
        @"defaultClassicMode": mode,
        @"systemMajorVersion": @(systemMajorVersion),
    };
    [self save];
    return mode.unsignedIntegerValue;
}

- (bool)isLocked {
    if(_info[@"isLocked"] != nil) {
        return [_info[@"isLocked"] boolValue];
    } else {
        return NO;
    }
}
- (void)setIsLocked:(bool)isLocked {
    _info[@"isLocked"] = [NSNumber numberWithBool:isLocked];
    [self save];
    
}

- (bool)isHidden {
    if(_info[@"isHidden"] != nil) {
        return [_info[@"isHidden"] boolValue];
    } else {
        return NO;
    }
}
- (void)setIsHidden:(bool)isHidden {
    _info[@"isHidden"] = [NSNumber numberWithBool:isHidden];
    [self save];
    
}

- (bool)doSymlinkInbox {
    if(_info[@"doSymlinkInbox"] != nil) {
        return [_info[@"doSymlinkInbox"] boolValue];
    } else {
        return NO;
    }
}
- (void)setDoSymlinkInbox:(bool)doSymlinkInbox {
    _info[@"doSymlinkInbox"] = [NSNumber numberWithBool:doSymlinkInbox];
    [self save];
    
}

- (bool)hideLiveContainer {
    if(_info[@"hideLiveContainer"] != nil) {
        return [_info[@"hideLiveContainer"] boolValue];
    } else {
        return NO;
    }
}
- (void)setHideLiveContainer:(bool)hideLiveContainer {
    _info[@"hideLiveContainer"] = [NSNumber numberWithBool:hideLiveContainer];
    [self save];
}

- (bool)dontInjectTweakLoader {
    if(_info[@"dontInjectTweakLoader"] != nil) {
        return [_info[@"dontInjectTweakLoader"] boolValue];
    } else {
        return NO;
    }
}
- (void)setDontInjectTweakLoader:(bool)dontInjectTweakLoader {
    if([_info[@"dontInjectTweakLoader"] boolValue] == dontInjectTweakLoader) {
        return;
    }
    
    _info[@"dontInjectTweakLoader"] = [NSNumber numberWithBool:dontInjectTweakLoader];
    // we have to update patch to achieve this
    _info[@"LCPatchRevision"] = @(-1);
    [self save];
}

- (bool)dontLoadTweakLoader {
    if(_info[@"dontLoadTweakLoader"] != nil) {
        return [_info[@"dontLoadTweakLoader"] boolValue];
    } else {
        return NO;
    }
}
- (void)setDontLoadTweakLoader:(bool)dontLoadTweakLoader {
    _info[@"dontLoadTweakLoader"] = [NSNumber numberWithBool:dontLoadTweakLoader];
    [self save];
}

- (bool)doUseLCBundleId {
    if(_info[@"doUseLCBundleId"] != nil) {
        return [_info[@"doUseLCBundleId"] boolValue];
    } else {
        return NO;
    }
}
- (void)setDoUseLCBundleId:(bool)doUseLCBundleId {
    _info[@"doUseLCBundleId"] = [NSNumber numberWithBool:doUseLCBundleId];
    NSString *infoPath = [NSString stringWithFormat:@"%@/Info.plist", self.bundlePath];
    if(doUseLCBundleId) {
        _info[@"LCOrignalBundleIdentifier"] = _infoPlist[@"CFBundleIdentifier"];
        _infoPlist[@"CFBundleIdentifier"] = NSBundle.mainBundle.bundleIdentifier;
    } else if (_info[@"LCOrignalBundleIdentifier"]) {
        _infoPlist[@"CFBundleIdentifier"] = _info[@"LCOrignalBundleIdentifier"];
        [_info removeObjectForKey:@"LCOrignalBundleIdentifier"];
    }
    [_infoPlist writeBinToFile:infoPath atomically:YES];
    [self save];
}

- (bool)fixFilePickerNew {
    if(_info[@"fixFilePickerNew"] != nil) {
        return [_info[@"fixFilePickerNew"] boolValue];
    } else {
        return NO;
    }
}

- (void)setFixFilePickerNew:(bool)fixFilePickerNew {
    _info[@"fixFilePickerNew"] = @(fixFilePickerNew);
    [self save];
}

- (bool)fixLocalNotification {
    if(_info[@"fixLocalNotification"] != nil) {
        return [_info[@"fixLocalNotification"] boolValue];
    } else {
        return NO;
    }
}

- (void)setFixLocalNotification:(bool)fixLocalNotification {
    _info[@"fixLocalNotification"] = @(fixLocalNotification);
    [self save];
}

- (bool)fixBackgroundTaskIdentifiers {
    return [_info[@"fixBackgroundTaskIdentifiers"] boolValue];
}

- (void)setFixBackgroundTaskIdentifiers:(bool)fixBackgroundTaskIdentifiers {
    _info[@"fixBackgroundTaskIdentifiers"] = @(fixBackgroundTaskIdentifiers);
    [self save];
}

- (LCOrientationLock)orientationLock {
    return (LCOrientationLock) [((NSNumber*) _info[@"LCOrientationLock"]) intValue];
}
- (void)setOrientationLock:(LCOrientationLock)orientationLock {
    _info[@"LCOrientationLock"] = [NSNumber numberWithInt:(int) orientationLock];
    [self save];
}

- (MultitaskSpecified)multitaskSpecified {
    return (MultitaskSpecified) [((NSNumber*) _info[@"MultitaskSpecified"]) intValue];
}
- (void)setMultitaskSpecified:(MultitaskSpecified)multitaskSpecified {
    _info[@"MultitaskSpecified"] = [NSNumber numberWithInt:(int) multitaskSpecified];
    [self save];
}

- (UIColor*)cachedColor {
    if(_info[@"cachedColor"] != nil) {
        NSData *colorData = _info[@"cachedColor"];
        NSError* error;
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:UIColor.class fromData:colorData error:&error];
        if (!error) {
            return color;
        } else {
            NSLog(@"[LC] failed to get color %@", error);
            return nil;
        }
    } else {
        return nil;
    }
}

- (void)setCachedColor:(UIColor*) color {
    if(color == nil) {
        _info[@"cachedColor"] = nil;
    } else {
        NSError* error;
        NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&error];
        [_info setObject:colorData forKey:@"cachedColor"];
        if(error) {
            NSLog(@"[LC] failed to set color %@", error);
        }

    }
    [self save];
}

- (UIColor*)cachedColorDark {
    if(_info[@"cachedColorDark"] != nil) {
        NSData *colorData = _info[@"cachedColorDark"];
        NSError* error;
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:UIColor.class fromData:colorData error:&error];
        if (!error) {
            return color;
        } else {
            NSLog(@"[LC] failed to get color %@", error);
            return nil;
        }
    } else {
        return nil;
    }
}

- (void)setCachedColorDark:(UIColor*)color {
    if(color == nil) {
        _info[@"cachedColorDark"] = nil;
    } else {
        NSError* error;
        NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&error];
        [_info setObject:colorData forKey:@"cachedColorDark"];
        if(error) {
            NSLog(@"[LC] failed to set color %@", error);
        }

    }
    [self save];
}

- (NSArray<NSDictionary*>* )containerInfo {
    return _info[@"LCContainers"];
}

- (void)setContainerInfo:(NSArray<NSDictionary *> *)containerInfo {
    _info[@"LCContainers"] = containerInfo;
    [self save];
}

- (bool)is32bit {
    if(_info[@"is32bit"] != nil) {
        return [_info[@"is32bit"] boolValue];
    } else {
        return NO;
    }
}
- (void)setIs32bit:(bool)is32bit {
    _info[@"is32bit"] = [NSNumber numberWithBool:is32bit];
    [self save];
    
}
- (bool)is32bitEmulator {
    return [_infoPlist[@"LC32BitTranslationLayer"] boolValue];
}

- (bool)dontSign {
    if(_info[@"dontSign"] != nil) {
        return [_info[@"dontSign"] boolValue];
    } else {
        return NO;
    }
}
- (void)setDontSign:(bool)dontSign {
    _info[@"dontSign"] = [NSNumber numberWithBool:dontSign];
    [self save];
    
}

- (NSString *)jitLaunchScriptJs {
    if (self.is32bit && LCUtils.isTXMScriptRequired) {
        return LCUtils.base64EncodedUniversalJITScript;
    }
    return _info[@"jitLaunchScriptJs"];
}

- (void)setJitLaunchScriptJs:(NSString *)jitLaunchScriptJs {
    if (jitLaunchScriptJs.length > 0) {
        _info[@"jitLaunchScriptJs"] = jitLaunchScriptJs;
    } else {
        [_info removeObjectForKey:@"jitLaunchScriptJs"];
    }
    if (!_autoSaveDisabled) [self save];
}

- (NSString *)selected32BitEmulator {
    return _info[@"selected32BitEmulator"];
}

- (void)setSelected32BitEmulator:(NSString *)selected32BitEmulator {
    if (selected32BitEmulator.length > 0) {
        _info[@"selected32BitEmulator"] = selected32BitEmulator;
    } else {
        [_info removeObjectForKey:@"selected32BitEmulator"];
    }
    if (!_autoSaveDisabled) [self save];
}

- (bool)spoofSDKVersion {
    if(!_info[@"spoofSDKVersion"]) {
        return false;
    } else {
        return [_info[@"spoofSDKVersion"] unsignedIntValue] != 0;
    }
}

- (void)setSpoofSDKVersion:(bool)doSpoof {
    if(!doSpoof) {
        _info[@"spoofSDKVersion"] = 0;
    } else {
        NSString *execPath = [NSString stringWithFormat:@"%@/%@", _bundlePath, _infoPlist[@"CFBundleExecutable"]];
        __block uint32_t sdkVersion = 0;
        LCParseMachO(execPath.UTF8String, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            sdkVersion = dyld_get_sdk_version((const struct mach_header *)header);
        });
        // Hardcode spoofed SDK to iOS 11 if lower, as lower causes `Error in compatibility flow` crashes
        // for 32-bit apps, eg LiveExec32 has special hooks to fix issues, might cherry pick here later if needed
        uint32_t minSDK = self.is32bit ? 0x20000 : 0xb0000;
        if ((self.is32bit || sdkVersion) && sdkVersion < minSDK) {
            sdkVersion = minSDK;
        }
        NSLog(@"[LC] sdkversion = %8x", sdkVersion);
        _info[@"spoofSDKVersion"] = [NSNumber numberWithUnsignedInt:sdkVersion];
    }
    [self save];
}

- (NSDate*)lastLaunched {
    return _info[@"lastLaunched"];
}

- (void)setLastLaunched:(NSDate*)lastLaunched {
    _info[@"lastLaunched"] = lastLaunched;
    [self save];
}

- (NSDate*)installationDate {
    return _info[@"installationDate"];
}

- (void)setInstallationDate:(NSDate*)installationDate {
    _info[@"installationDate"] = installationDate;
    [self save];
}

- (NSString*)remark {
    return _info[@"remark"];
}

- (void)setRemark:(NSString *)remark {
    if([remark isEqualToString: @""]) {
        _info[@"remark"] = nil;
    } else {
        _info[@"remark"] = remark;
    }
    [self save];
}

- (bool)autoCleanCacheOnLaunch {
    if(_info[@"autoCleanCacheOnLaunch"] != nil) {
        return [_info[@"autoCleanCacheOnLaunch"] boolValue];
    } else {
        return NO;
    }
}

- (void)setAutoCleanCacheOnLaunch:(bool)autoCleanCacheOnLaunch {
    _info[@"autoCleanCacheOnLaunch"] = [NSNumber numberWithBool:autoCleanCacheOnLaunch];
    [self save];
}

- (NSDate*)lastAutoCleanDate {
    return _info[@"lastAutoCleanDate"];
}

- (void)setLastAutoCleanDate:(NSDate *)lastAutoCleanDate {
    if(lastAutoCleanDate) {
        _info[@"lastAutoCleanDate"] = lastAutoCleanDate;
    } else {
        [_info removeObjectForKey:@"lastAutoCleanDate"];
    }
    [self save];
}

- (long long)autoCleanTotalBytesSaved {
    if(_info[@"autoCleanTotalBytesSaved"] != nil) {
        return [_info[@"autoCleanTotalBytesSaved"] longLongValue];
    } else {
        return 0;
    }
}

- (void)setAutoCleanTotalBytesSaved:(long long)autoCleanTotalBytesSaved {
    long long value = autoCleanTotalBytesSaved >= 0 ? autoCleanTotalBytesSaved : 0;
    _info[@"autoCleanTotalBytesSaved"] = [NSNumber numberWithLongLong:value];
    [self save];
}

- (void)recordAutoCleanWithBytesSaved:(long long)bytesSaved {
    long long clampedBytesSaved = bytesSaved >= 0 ? bytesSaved : 0;
    NSDate *now = NSDate.date;
    
    NSMutableArray<NSDictionary*>* history = [_info[@"autoCleanHistory"] mutableCopy];
    if(!history) {
        history = [[NSMutableArray alloc] init];
    }
    [history addObject:@{
        @"date": now,
        @"bytesSaved": @(clampedBytesSaved)
    }];
    
    const NSUInteger maxHistoryEntries = 180;
    if(history.count > maxHistoryEntries) {
        NSRange rangeToDelete = NSMakeRange(0, history.count - maxHistoryEntries);
        [history removeObjectsInRange:rangeToDelete];
    }
    
    _info[@"autoCleanHistory"] = history;
    _info[@"lastAutoCleanDate"] = now;
    _info[@"autoCleanTotalBytesSaved"] = @([self autoCleanTotalBytesSaved] + clampedBytesSaved);
    [self save];
}

- (long long)autoCleanBytesSavedInLastDays:(NSInteger)days {
    if(days <= 0) {
        return 0;
    }
    
    NSArray<NSDictionary*>* history = _info[@"autoCleanHistory"];
    if(!history || history.count == 0) {
        return 0;
    }
    
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSDate *startDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:-days toDate:now options:0];
    if(!startDate) {
        return 0;
    }
    
    long long total = 0;
    for(NSDictionary *entry in history) {
        NSDate *entryDate = entry[@"date"];
        if(![entryDate isKindOfClass:NSDate.class]) {
            continue;
        }
        if([entryDate compare:startDate] != NSOrderedAscending) {
            NSNumber *saved = entry[@"bytesSaved"];
            if([saved isKindOfClass:NSNumber.class]) {
                total += saved.longLongValue;
            }
        }
    }
    
    return total;
}

- (long long)lastAutoCleanBytesSaved {
    NSArray<NSDictionary*>* history = _info[@"autoCleanHistory"];
    if(!history || history.count == 0) {
        return 0;
    }
    
    NSDictionary *lastEntry = history.lastObject;
    NSNumber *saved = lastEntry[@"bytesSaved"];
    if(![saved isKindOfClass:NSNumber.class]) {
        return 0;
    }
    return saved.longLongValue;
}

- (void)resetAutoCleanStats {
    [_info removeObjectForKey:@"autoCleanHistory"];
    [_info removeObjectForKey:@"lastAutoCleanDate"];
    [_info removeObjectForKey:@"autoCleanTotalBytesSaved"];
    [self save];
}

- (NSString *)sourceURL {
    return _info[@"LCSourceURL"];
}

- (void)setSourceURL:(NSString *)sourceURL {
    if (sourceURL.length > 0) {
        _info[@"LCSourceURL"] = [sourceURL copy];
    } else {
        [_info removeObjectForKey:@"LCSourceURL"];
    }
    [self save];
}

- (NSString *)installedSourceVersion {
    return _info[@"LCInstalledSourceVersion"];
}

- (void)setInstalledSourceVersion:(NSString *)installedSourceVersion {
    if (installedSourceVersion.length > 0) {
        _info[@"LCInstalledSourceVersion"] = [installedSourceVersion copy];
    } else {
        [_info removeObjectForKey:@"LCInstalledSourceVersion"];
    }
    [self save];
}

- (NSString *)installedSourceBuildVersion {
    return _info[@"LCInstalledSourceBuildVersion"];
}

- (void)setInstalledSourceBuildVersion:(NSString *)installedSourceBuildVersion {
    if (installedSourceBuildVersion.length > 0) {
        _info[@"LCInstalledSourceBuildVersion"] = [installedSourceBuildVersion copy];
    } else {
        [_info removeObjectForKey:@"LCInstalledSourceBuildVersion"];
    }
    [self save];
}

- (NSString *)ignoredUpdateVersion {
    return _info[@"LCIgnoredUpdateVersion"];
}

- (void)setIgnoredUpdateVersion:(NSString *)ignoredUpdateVersion {
    if (ignoredUpdateVersion.length > 0) {
        _info[@"LCIgnoredUpdateVersion"] = [ignoredUpdateVersion copy];
    } else {
        [_info removeObjectForKey:@"LCIgnoredUpdateVersion"];
    }
    [self save];
}

- (bool)debugModeEnabled {
    return [_info[@"LCDebugModeEnabled"] boolValue];
}

- (void)setDebugModeEnabled:(bool)debugModeEnabled {
    _info[@"LCDebugModeEnabled"] = @(debugModeEnabled);
    [self save];
}

- (bool)exportTweakSymbolsGlobally {
    return [_info[@"exportTweakSymbolsGlobally"] boolValue];
}

- (void)setExportTweakSymbolsGlobally:(bool)exportTweakSymbolsGlobally {
    _info[@"exportTweakSymbolsGlobally"] = @(exportTweakSymbolsGlobally);
    [self save];
}

#pragma mark - App Metadata & Info.plist Editing

- (nullable NSString *)bundleName {
    id val = _infoPlist[@"CFBundleName"];
    return [val isKindOfClass:NSString.class] ? val : nil;
}

- (nullable NSString *)executableName {
    id val = _infoPlist[@"CFBundleExecutable"];
    return [val isKindOfClass:NSString.class] ? val : nil;
}

- (nullable NSString *)minimumOSVersion {
    id val = _infoPlist[@"MinimumOSVersion"];
    return [val isKindOfClass:NSString.class] ? val : nil;
}

- (BOOL)hasOriginalMetadataBackup {
    return [_info[@"LCFactoryOriginalInfoPlistData"] isKindOfClass:NSData.class];
}

- (NSDictionary<NSString *, id> *)editableInfoPlistDictionary {
    NSMutableDictionary *snapshot = nil;
    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:_infoPlist ?: @{}
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0
                                                                     error:nil];
    if (serialized) {
        snapshot = [NSPropertyListSerialization propertyListWithData:serialized
                                                             options:NSPropertyListMutableContainersAndLeaves
                                                              format:NULL
                                                               error:nil];
    }
    if (![snapshot isKindOfClass:NSMutableDictionary.class]) {
        snapshot = [_infoPlist mutableCopy] ?: [[NSMutableDictionary alloc] init];
    }
    if ([self doUseLCBundleId]) {
        NSString *originalId = _info[@"LCOrignalBundleIdentifier"];
        if ([originalId isKindOfClass:NSString.class] && originalId.length > 0) {
            snapshot[@"CFBundleIdentifier"] = originalId;
        }
    }
    return snapshot;
}

- (nullable NSDictionary<NSString *, id> *)originalInfoPlistDictionary {
    NSData *backupData = _info[@"LCFactoryOriginalInfoPlistData"];
    if (![backupData isKindOfClass:NSData.class]) {
        return nil;
    }
    id decoded = [NSPropertyListSerialization propertyListWithData:backupData
                                                           options:NSPropertyListImmutable
                                                            format:NULL
                                                             error:nil];
    return [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
}

- (NSArray<NSString *> *)appExtensionNames {
    NSString *pluginsPath = [_bundlePath stringByAppendingPathComponent:@"PlugIns"];
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:pluginsPath error:nil];
    if (!items) {
        return @[];
    }
    NSMutableArray<NSString *> *extensions = [[NSMutableArray alloc] init];
    for (NSString *name in items) {
        if ([name.pathExtension.lowercaseString isEqualToString:@"appex"]) {
            [extensions addObject:name];
        }
    }
    [extensions sortUsingSelector:@selector(localizedStandardCompare:)];
    return extensions;
}

- (NSError *)lcMetadataErrorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"com.livecontainer.metadata"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Metadata operation failed."}];
}

- (BOOL)lcValidateBundleIdentifier:(NSString *)bundleId error:(NSError **)error {
    if (![bundleId isKindOfClass:NSString.class] || bundleId.length == 0) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1001 message:@"Bundle Identifier cannot be empty."];
        }
        return NO;
    }
    if ([bundleId rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [bundleId containsString:@"/"]) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1002 message:@"Bundle Identifier cannot contain spaces, newlines, or slashes."];
        }
        return NO;
    }
    return YES;
}

- (BOOL)lcValidateExecutableName:(NSString *)execName error:(NSError **)error {
    if (![execName isKindOfClass:NSString.class] || execName.length == 0) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1005 message:@"Info.plist must include a non-empty CFBundleExecutable string."];
        }
        return NO;
    }
    if ([execName containsString:@"/"] ||
        [execName containsString:@"\0"] ||
        [execName isEqualToString:@"."] ||
        [execName isEqualToString:@".."]) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1009 message:@"CFBundleExecutable cannot contain path separators or traversal segments."];
        }
        return NO;
    }
    NSString *standardizedBundle = [[NSURL fileURLWithPath:_bundlePath isDirectory:YES] URLByStandardizingPath].path;
    NSString *bundlePrefix = [standardizedBundle hasSuffix:@"/"] ? standardizedBundle : [standardizedBundle stringByAppendingString:@"/"];
    NSString *resolvedExec = [[NSURL fileURLWithPath:[_bundlePath stringByAppendingPathComponent:execName]] URLByStandardizingPath].path;
    if (![resolvedExec hasPrefix:bundlePrefix]) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1010 message:@"CFBundleExecutable must stay inside the app bundle."];
        }
        return NO;
    }
    return YES;
}

- (nullable NSData *)serializedOriginalInfoPlistSnapshot {
    NSMutableDictionary *snapshot = [[self editableInfoPlistDictionary] mutableCopy];
    return [NSPropertyListSerialization dataWithPropertyList:snapshot ?: @{}
                                                      format:NSPropertyListBinaryFormat_v1_0
                                                     options:0
                                                       error:nil];
}

- (void)commitOriginalMetadataBackupSnapshot:(nullable NSData *)backupData {
    if ([self hasOriginalMetadataBackup] || !backupData) {
        return;
    }
    _info[@"LCFactoryOriginalInfoPlistData"] = backupData;
    _info[@"LCFactoryInstalledSourceVersion"] = [_info[@"LCInstalledSourceVersion"] isKindOfClass:NSString.class] ? _info[@"LCInstalledSourceVersion"] : @"";
    _info[@"LCFactoryInstalledSourceBuildVersion"] = [_info[@"LCInstalledSourceBuildVersion"] isKindOfClass:NSString.class] ? _info[@"LCInstalledSourceBuildVersion"] : @"";
}

- (BOOL)writeInfoPlistDictionaryAtomically:(NSDictionary *)dict error:(NSError **)error {
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                   format:NSPropertyListBinaryFormat_v1_0
                                                                  options:0
                                                                    error:error];
    if (!plistData) {
        return NO;
    }
    NSString *infoPath = [_bundlePath stringByAppendingPathComponent:@"Info.plist"];
    return [plistData writeToFile:infoPath options:NSDataWritingAtomic error:error];
}

- (BOOL)applyCustomMetadataWithDisplayName:(nullable NSString *)displayName
                                bundleName:(nullable NSString *)bundleName
                          bundleIdentifier:(nullable NSString *)bundleIdentifier
                              shortVersion:(nullable NSString *)shortVersion
                              buildVersion:(nullable NSString *)buildVersion
                          minimumOSVersion:(nullable NSString *)minimumOSVersion
                  updateExtensionBundleIds:(BOOL)updateExtensions
                      updateLocalizedNames:(BOOL)updateLocalized
                                     error:(NSError * _Nullable * _Nullable)error {
    NSString *trimmedDisplayName = [displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedBundleName = [bundleName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedBundleId = [bundleIdentifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedShortVersion = [shortVersion stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedBuildVersion = [buildVersion stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *trimmedMinOS = [minimumOSVersion stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (bundleIdentifier != nil) {
        if (![self lcValidateBundleIdentifier:trimmedBundleId error:error]) {
            return NO;
        }
    } else {
        trimmedBundleId = [self bundleIdentifier];
        if (![self lcValidateBundleIdentifier:trimmedBundleId error:error]) {
            return NO;
        }
    }

    NSString *effectiveName = trimmedDisplayName.length > 0 ? trimmedDisplayName : trimmedBundleName;
    if (effectiveName.length == 0) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1003 message:@"App Name cannot be empty."];
        }
        return NO;
    }

    NSString *oldBundleId = [[self bundleIdentifier] copy];
    NSString *oldEffectiveDisplayName = [_infoPlist[@"CFBundleDisplayName"] isKindOfClass:NSString.class]
        ? _infoPlist[@"CFBundleDisplayName"]
        : [self displayName];
    NSString *oldBundleName = [_infoPlist[@"CFBundleName"] isKindOfClass:NSString.class]
        ? _infoPlist[@"CFBundleName"]
        : @"";
    BOOL hadExplicitDisplayName = [_infoPlist[@"CFBundleDisplayName"] isKindOfClass:NSString.class] && [(NSString *)_infoPlist[@"CFBundleDisplayName"] length] > 0;
    BOOL displayNameChanged = ![trimmedDisplayName isEqualToString:(oldEffectiveDisplayName ?: @"")];
    BOOL bundleNameChanged = ![trimmedBundleName isEqualToString:(oldBundleName ?: @"")];

    NSData *pendingBackupSnapshot = [self hasOriginalMetadataBackup] ? nil : [self serializedOriginalInfoPlistSnapshot];

    NSMutableDictionary *updatedInfoPlist = [[self editableInfoPlistDictionary] mutableCopy];
    if (!updatedInfoPlist) {
        updatedInfoPlist = [[NSMutableDictionary alloc] init];
    }

    if (hadExplicitDisplayName || displayNameChanged) {
        if (trimmedDisplayName.length > 0) {
            updatedInfoPlist[@"CFBundleDisplayName"] = trimmedDisplayName;
        } else {
            [updatedInfoPlist removeObjectForKey:@"CFBundleDisplayName"];
        }
    }

    NSString *effectiveBundleName = trimmedBundleName.length > 0 ? trimmedBundleName : trimmedDisplayName;
    if (effectiveBundleName.length > 0 && (![oldBundleName isEqualToString:@""] || bundleNameChanged || trimmedBundleName.length > 0)) {
        updatedInfoPlist[@"CFBundleName"] = effectiveBundleName;
    }

    if ([self doUseLCBundleId]) {
        updatedInfoPlist[@"CFBundleIdentifier"] = NSBundle.mainBundle.bundleIdentifier ?: trimmedBundleId;
    } else {
        updatedInfoPlist[@"CFBundleIdentifier"] = trimmedBundleId;
    }

    if (shortVersion != nil) {
        if (trimmedShortVersion.length > 0) {
            updatedInfoPlist[@"CFBundleShortVersionString"] = trimmedShortVersion;
        } else {
            [updatedInfoPlist removeObjectForKey:@"CFBundleShortVersionString"];
        }
    }

    if (buildVersion != nil) {
        if (trimmedBuildVersion.length > 0) {
            updatedInfoPlist[@"CFBundleVersion"] = trimmedBuildVersion;
        } else {
            [updatedInfoPlist removeObjectForKey:@"CFBundleVersion"];
        }
    }

    if (minimumOSVersion != nil) {
        if (trimmedMinOS.length > 0) {
            updatedInfoPlist[@"MinimumOSVersion"] = trimmedMinOS;
        } else {
            [updatedInfoPlist removeObjectForKey:@"MinimumOSVersion"];
        }
    }

    if (![self writeInfoPlistDictionaryAtomically:updatedInfoPlist error:error]) {
        return NO;
    }

    // Only mutate _info / _infoPlist after the atomic Info.plist write succeeded.
    [self commitOriginalMetadataBackupSnapshot:pendingBackupSnapshot];
    if ([self doUseLCBundleId]) {
        _info[@"LCOrignalBundleIdentifier"] = trimmedBundleId;
    }
    _infoPlist = updatedInfoPlist;

    if (shortVersion != nil && [_info[@"LCInstalledSourceVersion"] isKindOfClass:NSString.class]) {
        if (trimmedShortVersion.length > 0) {
            _info[@"LCInstalledSourceVersion"] = trimmedShortVersion;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceVersion"];
        }
    }
    if (buildVersion != nil && [_info[@"LCInstalledSourceBuildVersion"] isKindOfClass:NSString.class]) {
        if (trimmedBuildVersion.length > 0) {
            _info[@"LCInstalledSourceBuildVersion"] = trimmedBuildVersion;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceBuildVersion"];
        }
    }

    if (updateLocalized && (displayNameChanged || bundleNameChanged) && effectiveName.length > 0) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *bundleItems = [fm contentsOfDirectoryAtPath:_bundlePath error:nil];
        NSMutableDictionary<NSString *, NSData *> *stringsBackups = [_info[@"LCFactoryOriginalInfoPlistStrings"] mutableCopy];
        if (![stringsBackups isKindOfClass:NSMutableDictionary.class]) {
            stringsBackups = [[NSMutableDictionary alloc] init];
        }
        BOOL backupAdded = NO;

        for (NSString *item in bundleItems) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"lproj"]) {
                continue;
            }
            NSString *stringsPath = [[_bundlePath stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"InfoPlist.strings"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:stringsPath isDirectory:&isDir] || isDir) {
                continue;
            }
            NSData *rawData = [NSData dataWithContentsOfFile:stringsPath];
            if (!rawData) {
                continue;
            }
            id parsed = [NSPropertyListSerialization propertyListWithData:rawData
                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                   format:NULL
                                                                    error:nil];
            if (![parsed isKindOfClass:NSMutableDictionary.class]) {
                continue;
            }
            NSMutableDictionary *localizedDict = (NSMutableDictionary *)parsed;
            BOOL touched = NO;
            if (localizedDict[@"CFBundleDisplayName"] != nil) {
                localizedDict[@"CFBundleDisplayName"] = effectiveName;
                touched = YES;
            }
            if (localizedDict[@"CFBundleName"] != nil) {
                localizedDict[@"CFBundleName"] = effectiveBundleName.length > 0 ? effectiveBundleName : effectiveName;
                touched = YES;
            }
            if (!touched) {
                continue;
            }
            if ([localizedDict writeBinToFile:stringsPath atomically:YES]) {
                if (!stringsBackups[item]) {
                    stringsBackups[item] = rawData;
                    backupAdded = YES;
                }
            }
        }
        if (backupAdded) {
            _info[@"LCFactoryOriginalInfoPlistStrings"] = stringsBackups;
        }
    }

    if (updateExtensions &&
        oldBundleId.length > 0 &&
        ![oldBundleId isEqualToString:@"Unknown"] &&
        ![oldBundleId isEqualToString:trimmedBundleId]) {
        NSString *pluginsPath = [_bundlePath stringByAppendingPathComponent:@"PlugIns"];
        NSArray<NSString *> *pluginNames = [self appExtensionNames];
        NSMutableDictionary<NSString *, NSData *> *extBackups = [_info[@"LCFactoryOriginalExtensionInfoPlists"] mutableCopy];
        if (![extBackups isKindOfClass:NSMutableDictionary.class]) {
            extBackups = [[NSMutableDictionary alloc] init];
        }
        BOOL extBackupAdded = NO;
        NSString *oldPrefix = [oldBundleId stringByAppendingString:@"."];
        NSString *newPrefix = [trimmedBundleId stringByAppendingString:@"."];

        for (NSString *appexName in pluginNames) {
            NSString *extInfoPath = [[pluginsPath stringByAppendingPathComponent:appexName] stringByAppendingPathComponent:@"Info.plist"];
            NSData *rawExtData = [NSData dataWithContentsOfFile:extInfoPath];
            if (!rawExtData) {
                continue;
            }
            id parsed = [NSPropertyListSerialization propertyListWithData:rawExtData
                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                   format:NULL
                                                                    error:nil];
            if (![parsed isKindOfClass:NSMutableDictionary.class]) {
                continue;
            }
            NSMutableDictionary *extPlist = (NSMutableDictionary *)parsed;
            BOOL touched = NO;
            NSString *extBundleId = extPlist[@"CFBundleIdentifier"];
            if ([extBundleId isKindOfClass:NSString.class]) {
                if ([extBundleId isEqualToString:oldBundleId]) {
                    extPlist[@"CFBundleIdentifier"] = trimmedBundleId;
                    touched = YES;
                } else if ([extBundleId hasPrefix:oldPrefix]) {
                    extPlist[@"CFBundleIdentifier"] = [newPrefix stringByAppendingString:[extBundleId substringFromIndex:oldPrefix.length]];
                    touched = YES;
                }
            }
            id nsExtension = extPlist[@"NSExtension"];
            if ([nsExtension isKindOfClass:NSMutableDictionary.class]) {
                id extAttrs = nsExtension[@"NSExtensionAttributes"];
                if ([extAttrs isKindOfClass:NSMutableDictionary.class]) {
                    NSString *wkAppId = extAttrs[@"WKAppBundleIdentifier"];
                    if ([wkAppId isKindOfClass:NSString.class] && [wkAppId isEqualToString:oldBundleId]) {
                        extAttrs[@"WKAppBundleIdentifier"] = trimmedBundleId;
                        touched = YES;
                    }
                }
            }
            if (!touched) {
                continue;
            }
            if ([extPlist writeBinToFile:extInfoPath atomically:YES]) {
                if (!extBackups[appexName]) {
                    extBackups[appexName] = rawExtData;
                    extBackupAdded = YES;
                }
            }
        }
        if (extBackupAdded) {
            _info[@"LCFactoryOriginalExtensionInfoPlists"] = extBackups;
        }
    }

    [self save];
    return YES;
}

- (BOOL)replaceInfoPlistWithDictionary:(NSDictionary<NSString *, id> *)newInfoPlist
                                 error:(NSError * _Nullable * _Nullable)error {
    if (![newInfoPlist isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1004 message:@"Top-level Info.plist must be a dictionary."];
        }
        return NO;
    }

    id execVal = newInfoPlist[@"CFBundleExecutable"];
    if (![execVal isKindOfClass:NSString.class] || ![self lcValidateExecutableName:execVal error:error]) {
        return NO;
    }

    id bundleIdVal = newInfoPlist[@"CFBundleIdentifier"];
    NSString *trimmedBundleId = [bundleIdVal isKindOfClass:NSString.class]
        ? [(NSString *)bundleIdVal stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
    if (![self lcValidateBundleIdentifier:trimmedBundleId error:error]) {
        return NO;
    }

    NSArray<NSString *> *stringKeys = @[
        @"CFBundleDisplayName",
        @"CFBundleName",
        @"CFBundleShortVersionString",
        @"CFBundleVersion",
        @"MinimumOSVersion"
    ];
    for (NSString *key in stringKeys) {
        id value = newInfoPlist[key];
        if (value != nil && ![value isKindOfClass:NSString.class]) {
            if (error) {
                *error = [self lcMetadataErrorWithCode:1011 message:[NSString stringWithFormat:@"%@ must be a String value.", key]];
            }
            return NO;
        }
    }

    id urlTypes = newInfoPlist[@"CFBundleURLTypes"];
    if (urlTypes != nil) {
        if (![urlTypes isKindOfClass:NSArray.class]) {
            if (error) {
                *error = [self lcMetadataErrorWithCode:1012 message:@"CFBundleURLTypes must be an Array of Dictionaries."];
            }
            return NO;
        }
        for (id entry in (NSArray *)urlTypes) {
            if (![entry isKindOfClass:NSDictionary.class]) {
                if (error) {
                    *error = [self lcMetadataErrorWithCode:1012 message:@"CFBundleURLTypes must contain Dictionary items."];
                }
                return NO;
            }
        }
    }

    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:newInfoPlist
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0
                                                                     error:error];
    if (!serialized) {
        return NO;
    }

    NSMutableDictionary *mutablePlist = [NSPropertyListSerialization propertyListWithData:serialized
                                                                                  options:NSPropertyListMutableContainersAndLeaves
                                                                                   format:NULL
                                                                                    error:error];
    if (![mutablePlist isKindOfClass:NSMutableDictionary.class]) {
        if (error && !*error) {
            *error = [self lcMetadataErrorWithCode:1006 message:@"Failed to encode Info.plist dictionary."];
        }
        return NO;
    }

    NSData *pendingBackupSnapshot = [self hasOriginalMetadataBackup] ? nil : [self serializedOriginalInfoPlistSnapshot];

    if ([self doUseLCBundleId]) {
        mutablePlist[@"CFBundleIdentifier"] = NSBundle.mainBundle.bundleIdentifier ?: trimmedBundleId;
    } else {
        mutablePlist[@"CFBundleIdentifier"] = trimmedBundleId;
    }

    if (![self writeInfoPlistDictionaryAtomically:mutablePlist error:error]) {
        return NO;
    }

    // Commit _info / _infoPlist mutations only after atomic Info.plist write succeeds.
    [self commitOriginalMetadataBackupSnapshot:pendingBackupSnapshot];
    if ([self doUseLCBundleId]) {
        _info[@"LCOrignalBundleIdentifier"] = trimmedBundleId;
    }
    _infoPlist = mutablePlist;

    if ([_info[@"LCInstalledSourceVersion"] isKindOfClass:NSString.class]) {
        NSString *newShortVersion = [mutablePlist[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
            ? mutablePlist[@"CFBundleShortVersionString"]
            : @"";
        if (newShortVersion.length > 0) {
            _info[@"LCInstalledSourceVersion"] = newShortVersion;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceVersion"];
        }
    }
    if ([_info[@"LCInstalledSourceBuildVersion"] isKindOfClass:NSString.class]) {
        NSString *newBuildVersion = [mutablePlist[@"CFBundleVersion"] isKindOfClass:NSString.class]
            ? mutablePlist[@"CFBundleVersion"]
            : @"";
        if (newBuildVersion.length > 0) {
            _info[@"LCInstalledSourceBuildVersion"] = newBuildVersion;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceBuildVersion"];
        }
    }

    [self clearIconCache];
    [self save];
    return YES;
}

- (BOOL)resetInfoPlistToOriginalWithError:(NSError * _Nullable * _Nullable)error {
    NSData *backupData = _info[@"LCFactoryOriginalInfoPlistData"];
    if (![backupData isKindOfClass:NSData.class]) {
        if (error) {
            *error = [self lcMetadataErrorWithCode:1007 message:@"No original Info.plist backup is available for this app."];
        }
        return NO;
    }

    NSMutableDictionary *restored = [NSPropertyListSerialization propertyListWithData:backupData
                                                                              options:NSPropertyListMutableContainersAndLeaves
                                                                               format:NULL
                                                                                error:error];
    if (![restored isKindOfClass:NSMutableDictionary.class]) {
        if (error && !*error) {
            *error = [self lcMetadataErrorWithCode:1008 message:@"Stored Info.plist backup is corrupted."];
        }
        return NO;
    }

    NSString *origId = [restored[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? restored[@"CFBundleIdentifier"] : nil;
    if ([self doUseLCBundleId]) {
        restored[@"CFBundleIdentifier"] = NSBundle.mainBundle.bundleIdentifier ?: origId ?: @"";
    }

    if (![self writeInfoPlistDictionaryAtomically:restored error:error]) {
        return NO;
    }

    if ([self doUseLCBundleId] && origId.length > 0) {
        _info[@"LCOrignalBundleIdentifier"] = origId;
    }

    NSDictionary<NSString *, NSData *> *stringsBackups = _info[@"LCFactoryOriginalInfoPlistStrings"];
    if ([stringsBackups isKindOfClass:NSDictionary.class]) {
        [stringsBackups enumerateKeysAndObjectsUsingBlock:^(NSString *lprojName, NSData *rawData, BOOL *stop) {
            if ([lprojName isKindOfClass:NSString.class] && [rawData isKindOfClass:NSData.class]) {
                NSString *stringsPath = [[_bundlePath stringByAppendingPathComponent:lprojName] stringByAppendingPathComponent:@"InfoPlist.strings"];
                [rawData writeToFile:stringsPath options:NSDataWritingAtomic error:nil];
            }
        }];
    }

    NSDictionary<NSString *, NSData *> *extBackups = _info[@"LCFactoryOriginalExtensionInfoPlists"];
    if ([extBackups isKindOfClass:NSDictionary.class]) {
        NSString *pluginsPath = [_bundlePath stringByAppendingPathComponent:@"PlugIns"];
        [extBackups enumerateKeysAndObjectsUsingBlock:^(NSString *appexName, NSData *rawData, BOOL *stop) {
            if ([appexName isKindOfClass:NSString.class] && [rawData isKindOfClass:NSData.class]) {
                NSString *extInfoPath = [[pluginsPath stringByAppendingPathComponent:appexName] stringByAppendingPathComponent:@"Info.plist"];
                [rawData writeToFile:extInfoPath options:NSDataWritingAtomic error:nil];
            }
        }];
    }

    NSString *factorySrcVer = _info[@"LCFactoryInstalledSourceVersion"];
    if ([factorySrcVer isKindOfClass:NSString.class]) {
        if (factorySrcVer.length > 0) {
            _info[@"LCInstalledSourceVersion"] = factorySrcVer;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceVersion"];
        }
    }
    NSString *factorySrcBuild = _info[@"LCFactoryInstalledSourceBuildVersion"];
    if ([factorySrcBuild isKindOfClass:NSString.class]) {
        if (factorySrcBuild.length > 0) {
            _info[@"LCInstalledSourceBuildVersion"] = factorySrcBuild;
        } else {
            [_info removeObjectForKey:@"LCInstalledSourceBuildVersion"];
        }
    }

    [_info removeObjectForKey:@"LCFactoryOriginalInfoPlistData"];
    [_info removeObjectForKey:@"LCFactoryOriginalInfoPlistStrings"];
    [_info removeObjectForKey:@"LCFactoryOriginalExtensionInfoPlists"];
    [_info removeObjectForKey:@"LCFactoryInstalledSourceVersion"];
    [_info removeObjectForKey:@"LCFactoryInstalledSourceBuildVersion"];

    _infoPlist = restored;
    [self clearIconCache];
    [self save];
    return YES;
}

- (void)reloadInfoPlistFromDisk {
    NSString *infoPath = [_bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *diskDict = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath];
    if (![diskDict isKindOfClass:NSMutableDictionary.class]) {
        return;
    }
    if ([self doUseLCBundleId]) {
        NSString *diskId = diskDict[@"CFBundleIdentifier"];
        NSString *lcId = NSBundle.mainBundle.bundleIdentifier;
        if ([diskId isKindOfClass:NSString.class] && diskId.length > 0 && lcId.length > 0 && ![diskId isEqualToString:lcId]) {
            _info[@"LCOrignalBundleIdentifier"] = diskId;
            diskDict[@"CFBundleIdentifier"] = lcId;
            [self writeInfoPlistDictionaryAtomically:diskDict error:nil];
            [self save];
        }
    }
    _infoPlist = diskDict;
    [self clearIconCache];
}

@end

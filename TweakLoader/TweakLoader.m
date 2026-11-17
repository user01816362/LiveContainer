#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/LCSharedUtils.h"

static NSString *const kDisabledTweaksKey = @"disabledItems";
static NSString *const kContainerInfoFileName = @"LCContainerInfo.plist";
static NSString *const kStrictSessionMarkerFileName = @".lc_strict_session_active";
static BOOL strictTestModeEnabled = NO;
static BOOL strictAutoWipeOnExitEnabled = NO;
static BOOL strictAutoWipePerformed = NO;
static NSString *strictContainerHomePath = nil;
static id strictWillTerminateObserver = nil;

static void LCStrictAutoWipeOnExit(void);

static NSString *LCStrictSessionMarkerPath(NSString *homePath) {
    if(homePath.length == 0) {
        return nil;
    }
    return [homePath stringByAppendingPathComponent:kStrictSessionMarkerFileName];
}

static void LCStrictWriteSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager createFileAtPath:markerPath contents:[NSData data] attributes:nil];
}

static void LCStrictRemoveSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:markerPath error:nil];
}

static BOOL LCStrictSessionMarkerExists(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return NO;
    }
    return [NSFileManager.defaultManager fileExistsAtPath:markerPath];
}

static void LCStrictWipeContainerContentsIfNeeded(void) {
    if(!strictTestModeEnabled || !strictAutoWipeOnExitEnabled) {
        return;
    }
    NSString *homePath = strictContainerHomePath;
    [NSClassFromString(@"LCSharedUtils") wipeStrictContainerIfNeededAtPath:homePath force:NO];
}

static void LCStrictRecoverStaleSessionIfNeeded(void) {
    if(!strictAutoWipeOnExitEnabled || strictContainerHomePath.length == 0) {
        return;
    }
    if(LCStrictSessionMarkerExists(strictContainerHomePath)) {
        NSLog(@"[LC][StrictMode] Detected stale strict session marker. Applying deferred auto-wipe.");
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static void LCStrictRegisterLifecycleObservers(void) {
    if(!strictAutoWipeOnExitEnabled || strictWillTerminateObserver != nil) {
        return;
    }
    strictWillTerminateObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        LCStrictAutoWipeOnExit();
    }];
}

static void LCStrictAutoWipeOnExit(void) {
    @autoreleasepool {
        if(strictAutoWipePerformed) {
            return;
        }
        strictAutoWipePerformed = YES;
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static NSSet<NSString *> *disabledItemsForFolder(NSURL *folderURL) {
    if (!folderURL || !folderURL.isFileURL) {
        return [NSSet set];
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[folderURL URLByAppendingPathComponent:@"TweakInfo.plist"]];
    NSArray<NSString *> *disabled = info[kDisabledTweaksKey];
    if (![disabled isKindOfClass:NSArray.class]) {
        return [NSSet set];
    }
    return [NSSet setWithArray:disabled];
}

static BOOL isTweakURLDisabled(NSURL *url, NSURL *rootFolderURL) {
    if (!url || !rootFolderURL) {
        return NO;
    }
    NSURL *cursor = url;
    NSString *rootPath = [rootFolderURL.path stringByStandardizingPath];
    while (cursor && [[cursor.path stringByStandardizingPath] hasPrefix:rootPath]) {
        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        NSSet<NSString *> *disabled = disabledItemsForFolder(parent);
        if ([disabled containsObject:cursor.lastPathComponent]) {
            return YES;
        }
        if ([[cursor.path stringByStandardizingPath] isEqualToString:rootPath]) {
            break;
        }
        cursor = parent;
    }
    return NO;
}

static BOOL isSubstrateCompatibleTweakName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"cydiasubstrate"] ||
           [lower containsString:@"ellekit"] ||
           [lower containsString:@"libhooker"] ||
           [lower containsString:@"substitute"];
}

static BOOL isTweakConflictingWithLoadedImage(NSURL *url, NSString *executableName) {
    NSString *bundleFrameworksPath = NSBundle.mainBundle.privateFrameworksPath;
    if (bundleFrameworksPath.length > 0) {
        NSString *candidate = [bundleFrameworksPath stringByAppendingPathComponent:url.lastPathComponent];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return YES;
        }
    }

    if (executableName.length == 0) {
        return NO;
    }
    NSString *frameworkSuffix = [NSString stringWithFormat:@"/%@.framework/%@", executableName, executableName];
    NSString *dylibSuffix = [NSString stringWithFormat:@"/%@", executableName];
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; ++i) {
        const char *imgC = _dyld_get_image_name(i);
        if (!imgC) continue;
        NSString *imgPath = [NSString stringWithUTF8String:imgC];
        if ([imgPath hasSuffix:frameworkSuffix] || [imgPath hasSuffix:dylibSuffix]) {
            return YES;
        }
    }
    return NO;
}

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    NSString *binaryName = tweak;
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        binaryName = binary;
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }

    if (isTweakConflictingWithLoadedImage(url, binaryName)) {
        NSLog(@"[TweakLoader] Skipping duplicate/conflicting tweak %@", tweak);
        return nil;
    }

    BOOL exportGlobally = [NSUserDefaults.guestAppInfo[@"exportTweakSymbolsGlobally"] boolValue] ||
        isSubstrateCompatibleTweakName(tweak);
    int dlopenMode = RTLD_LAZY | (exportGlobally ? RTLD_GLOBAL : RTLD_LOCAL);
    void *handle = dlopen(tweakPath.UTF8String, dlopenMode);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@ (%@)", tweak, exportGlobally ? @"GLOBAL" : @"LOCAL");
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void loadTweaksRecursively(NSURL *folderURL, NSURL *rootFolderURL, NSMutableArray *errors) {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"] || isTweakURLDisabled(fileURL, rootFolderURL)) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, rootFolderURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    if (!scene) return;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

extern void LCDebugAgentInitIfNeeded(void);

 __attribute__((constructor))
static void TweakLoaderConstructor(void) {
    NSDictionary *guestContainerInfo = [NSUserDefaults guestContainerInfo];
    strictTestModeEnabled = [guestContainerInfo[@"strictTestMode"] boolValue];
    strictAutoWipeOnExitEnabled = strictTestModeEnabled && [guestContainerInfo[@"strictAutoWipeOnExit"] boolValue];
    if(strictAutoWipeOnExitEnabled) {
        const char *homeEnv = getenv("HOME");
        if(homeEnv) {
            strictContainerHomePath = [NSString stringWithUTF8String:homeEnv];
            LCStrictRecoverStaleSessionIfNeeded();
            LCStrictWriteSessionMarker(strictContainerHomePath);
            LCStrictRegisterLifecycleObservers();
            atexit(LCStrictAutoWipeOnExit);
        }
    }

    NSString *globalTweakFolder = [NSClassFromString(@"LCSharedUtils") cachedGlobalTweaksFolderPath];
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");

    LCDebugAgentInitIfNeeded();

    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }

    if (globalTweakFolder.length == 0) {
        return;
    }
    NSURL *globalTweakFolderURL = [NSURL fileURLWithPath:globalTweakFolder];
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:globalTweakFolderURL
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        NSString *name = fileURL.lastPathComponent;
        if ([name isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if ([name hasSuffix:@".disabled"] || isTweakURLDisabled(fileURL, globalTweakFolderURL)) {
            NSLog(@"Skipping disabled global tweak %@", name);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL);
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSURL *tweakFolderURL = [globalTweakFolderURL URLByAppendingPathComponent:tweakFolderName];
        loadTweaksRecursively(tweakFolderURL, globalTweakFolderURL, errors);
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}

@import UIKit;
@import WebKit;
@import Metal;
@import AVFoundation;
@import Network;
@import CFNetwork;
@import Accessibility;
@import AuthenticationServices;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import "../LiveContainer/LCDeviceProfileCatalog.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"
#pragma clang diagnostic ignored "-Wundeclared-selector"
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <dns_sd.h>
#include <errno.h>
#include <math.h>
#include <mach/machine.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
NSUUID* idForVendorUUID = nil;
BOOL spoofProfileEnabled = NO;
BOOL spoofIdentityCategoryEnabled = YES;
BOOL spoofSystemCategoryEnabled = YES;
BOOL spoofDisplayCategoryEnabled = YES;
BOOL spoofLocaleCategoryEnabled = YES;
BOOL spoofBatteryCategoryEnabled = YES;
BOOL spoofTelephonyCategoryEnabled = YES;
BOOL spoofNetworkHeadersCategoryEnabled = YES;
BOOL spoofAccessibilityCategoryEnabled = YES;
BOOL spoofStorageCategoryEnabled = YES;
BOOL spoofNetworkEnvironmentCategoryEnabled = YES;
BOOL spoofAudioCategoryEnabled = YES;
BOOL spoofGraphicsCategoryEnabled = YES;
BOOL spoofWebViewCategoryEnabled = YES;
BOOL spoofAppPrivacyCategoryEnabled = YES;
BOOL spoofSensorsAndUserDataCategoryEnabled = YES;
NSArray<NSNumber *> *rotateOSMajorVersions = nil;
BOOL rotateUsesRealDeviceTemplates = YES;
BOOL blockDeviceInfoReads = NO;
BOOL strictTestMode = NO;
BOOL isolateWebViewData = NO;
UIPasteboard *strictPrivatePasteboard = nil;
NSString *spoofDeviceName = nil;
NSString *spoofDeviceModel = nil;
NSString *spoofSystemName = nil;
NSString *spoofSystemVersion = nil;
NSLocale *spoofLocale = nil;
NSTimeZone *spoofTimeZone = nil;
NSOperatingSystemVersion spoofOperatingSystemVersion;
BOOL spoofOperatingSystemVersionValid = NO;
float spoofBatteryLevel = -1.0f;
NSInteger spoofBatteryState = UIDeviceBatteryStateUnknown;
BOOL spoofLowPowerModeEnabled = NO;
BOOL spoofLowPowerModeEnabledSet = NO;
NSString *spoofRadioAccessTechnology = nil;
NSString *spoofSubscriberIdentifier = nil;
NSData *spoofSubscriberCarrierToken = nil;
BOOL spoofSubscriberSIMInsertedEnabled = NO;
BOOL spoofSubscriberSIMInserted = NO;
NSString *spoofHardwareModel = nil;
NSString *spoofHostName = nil;
NSString *spoofBoardModel = nil;
NSString *spoofKernelVersion = nil;
time_t spoofBootTime = 0;
int32_t spoofCPUType = 0;
int32_t spoofCPUSubtype = -1;
NSInteger spoofProcessorCount = 0;
unsigned long long spoofPhysicalMemory = 0;
NSInteger spoofThermalState = -1;
CGFloat spoofScreenWidth = 0;
CGFloat spoofScreenHeight = 0;
CGFloat spoofScreenScale = 0;
CGFloat spoofScreenNativeScale = 0;
NSInteger spoofMaximumFramesPerSecond = 0;
CGFloat spoofScreenBrightness = -1;
NSInteger spoofUserInterfaceStyle = UIUserInterfaceStyleLight;
NSInteger spoofAccessibilityContrast = UIAccessibilityContrastNormal;
NSInteger spoofDisplayGamut = UIDisplayGamutP3;
NSInteger spoofHorizontalSizeClass = UIUserInterfaceSizeClassCompact;
NSInteger spoofVerticalSizeClass = UIUserInterfaceSizeClassRegular;
UIContentSizeCategory spoofPreferredContentSizeCategory = nil;
UIEdgeInsets spoofSafeAreaInsets = {59, 0, 34, 0};
long long spoofStorageTotalCapacity = 128LL * 1024LL * 1024LL * 1024LL;
long long spoofStorageAvailableCapacity = 64LL * 1024LL * 1024LL * 1024LL;
NSString *spoofGPUName = @"Apple GPU";
float spoofAudioOutputVolume = 0.5f;
double spoofAudioSampleRate = 48000;
double spoofAudioOutputLatency = 0.01;
double spoofAudioInputLatency = 0.01;
BOOL spoofAudioOtherPlaying = NO;
NSInteger spoofAudioOutputChannels = 2;
NSInteger spoofAudioInputChannels = 1;
unsigned long long spoofGPUWorkingSetSize = 4ULL * 1024ULL * 1024ULL * 1024ULL;
BOOL spoofGraphicsSupportsRayTracing = YES;
BOOL spoofGraphicsSupportsAllFamilies = YES;
NSString *spoofStorageVolumeName = @"Data";
NSString *spoofStorageVolumeUUID = @"00000000-0000-0000-0000-000000000000";
time_t spoofStorageFileCreationTime = 1735689600;
time_t spoofStorageVolumeCreationTime = 1704067200;
NSString *spoofCustomUserAgent = nil;
NSString *spoofWebGLVendor = @"Apple Inc.";
NSString *spoofWebGLRenderer = @"Apple GPU";
uint32_t spoofWebCanvasSeed = 0;
NSInteger spoofWebColorDepth = 24;
NSDictionary<NSString *, NSNumber *> *spoofFeatureOverrides = nil;
NSString *spoofDeviceVariantId = nil;
CGFloat spoofScreenPointWidth = 0;
CGFloat spoofScreenPointHeight = 0;
static BOOL sUIScreenBoundsSwizzled = NO;

static uint32_t LCFNV1a32(const char *str, uint32_t seed) {
    uint32_t hash = seed ? seed : 2166136261u;
    if (!str) return hash;
    for (const unsigned char *p = (const unsigned char *)str; *p; p++) {
        hash ^= *p;
        hash *= 16777619u;
    }
    return hash;
}

static uint32_t LCParseWebCanvasSeedValue(id rawValue) {
    if ([rawValue isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)rawValue unsignedIntValue];
    }
    if ([rawValue isKindOfClass:NSString.class]) {
        NSString *trimmed = [(NSString *)rawValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) return 0;
        unsigned long long parsed = strtoull(trimmed.UTF8String, NULL, 0);
        return (uint32_t)(parsed & 0xFFFFFFFFULL);
    }
    return 0;
}

static uint32_t LCEffectiveWebCanvasSeed(void) {
    if (spoofWebCanvasSeed != 0) {
        return spoofWebCanvasSeed;
    }
    uint32_t h = LCFNV1a32(idForVendorUUID.UUIDString.UTF8String, 2166136261u);
    h = LCFNV1a32(spoofHardwareModel.UTF8String, h);
    h = LCFNV1a32(spoofDeviceName.UTF8String, h);
    if (h == 0) h = 0x5A17C3D1u;
    return h;
}

static NSString *sRealHostMachine = nil;
static _Atomic uint64_t sHardwareInterceptions = 0;
static _Atomic uint64_t sNetworkInterceptions = 0;
static _Atomic uint64_t sWebKitInterceptions = 0;
static atomic_flag sTelemetryFlushScheduled = ATOMIC_FLAG_INIT;
static CFAbsoluteTime sLastTelemetryFlushTimestamp = 0;
static os_unfair_lock sTelemetryLock = OS_UNFAIR_LOCK_INIT;
static NSString *sTelemetryFilePath = nil;

typedef NS_ENUM(NSInteger, LCProfileTelemetryVector) {
    LCProfileTelemetryVectorHardware = 0,
    LCProfileTelemetryVectorNetwork = 1,
    LCProfileTelemetryVectorWebKit = 2
};

/**
 Returns a point-in-time snapshot of spoof interception counters and host comparison
 metrics for Debug Studio, the Mac LAN Web Console, and the Leak Inspector.
 */
NSDictionary *LCProfileGetTelemetrySnapshot(void) {
    uint64_t hwCount = atomic_load_explicit(&sHardwareInterceptions, memory_order_relaxed);
    uint64_t netCount = atomic_load_explicit(&sNetworkInterceptions, memory_order_relaxed);
    uint64_t webCount = atomic_load_explicit(&sWebKitInterceptions, memory_order_relaxed);
    return @{
        @"spoofProfileEnabled": @(spoofProfileEnabled),
        @"blockDeviceInfoReads": @(blockDeviceInfoReads),
        @"realHostMachine": sRealHostMachine ?: @"",
        @"spoofedHardwareModel": spoofHardwareModel ?: @"",
        @"spoofedBoardModel": spoofBoardModel ?: @"",
        @"spoofedSystemVersion": spoofSystemVersion ?: @"",
        @"hardwareInterceptions": @(hwCount),
        @"networkInterceptions": @(netCount),
        @"webkitInterceptions": @(webCount),
        @"updatedAt": @((long long)time(NULL))
    };
}

static void LCFlushProfileTelemetryToDisk(BOOL force) {
    if (sTelemetryFilePath.length == 0) {
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&sTelemetryLock);
    BOOL shouldWrite = force || (now - sLastTelemetryFlushTimestamp >= 2.5);
    if (shouldWrite) {
        sLastTelemetryFlushTimestamp = now;
    }
    os_unfair_lock_unlock(&sTelemetryLock);
    if (!shouldWrite) {
        return;
    }
    NSDictionary *snapshot = LCProfileGetTelemetrySnapshot();
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data.length > 0) {
        [data writeToFile:sTelemetryFilePath atomically:YES];
    }
}

static void LCRecordProfileInterception(LCProfileTelemetryVector vector) {
    switch (vector) {
        case LCProfileTelemetryVectorHardware:
            atomic_fetch_add_explicit(&sHardwareInterceptions, 1, memory_order_relaxed);
            break;
        case LCProfileTelemetryVectorNetwork:
            atomic_fetch_add_explicit(&sNetworkInterceptions, 1, memory_order_relaxed);
            break;
        case LCProfileTelemetryVectorWebKit:
            atomic_fetch_add_explicit(&sWebKitInterceptions, 1, memory_order_relaxed);
            break;
    }
    if (sTelemetryFilePath.length > 0 && !atomic_flag_test_and_set_explicit(&sTelemetryFlushScheduled, memory_order_acq_rel)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            atomic_flag_clear_explicit(&sTelemetryFlushScheduled, memory_order_release);
            LCFlushProfileTelemetryToDisk(NO);
        });
    }
}

static BOOL LCFeatureEnabled(NSString *key) {
    if (spoofProfileEnabled) {
        NSNumber *value = spoofFeatureOverrides[key];
        if ([value isKindOfClass:NSNumber.class]) {
            return value.boolValue;
        }
    }
    return key.length > 0 ? LCDefaultFeatureFlagEnabled(key.UTF8String) : YES;
}

@interface LCTelephonyNetworkInfoHookProvider : NSObject
@end

@interface LCSubscriberHookProvider : NSObject
@end

@interface LCSubscriberInfoHookProvider : NSObject
@end

@interface LCNetworkExtensionStrictHookProvider : NSObject
@end

@interface LCLSApplicationWorkspaceHookProvider : NSObject
@end

static void LCSwizzleIfPresent(Class cls, SEL originalAction, SEL swizzledAction) {
    if(!cls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, originalAction);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledAction);
    if(!originalMethod || !swizzledMethod) {
        return;
    }
    BOOL didAdd = class_addMethod(
        cls,
        originalAction,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    );
    if(didAdd) {
        class_replaceMethod(
            cls,
            swizzledAction,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        );
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void LCSwizzleIfPresentWithSourceClass(Class cls, Class sourceCls, SEL originalAction, SEL swizzledAction) {
    if(!cls || !sourceCls) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, originalAction);
    Method sourceMethod = class_getInstanceMethod(sourceCls, swizzledAction);
    if(!originalMethod || !sourceMethod) {
        return;
    }
    class_addMethod(
        cls,
        swizzledAction,
        method_getImplementation(sourceMethod),
        method_getTypeEncoding(sourceMethod)
    );
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledAction);
    if(!swizzledMethod) {
        return;
    }
    BOOL didAdd = class_addMethod(
        cls,
        originalAction,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    );
    if(didAdd) {
        class_replaceMethod(
            cls,
            swizzledAction,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        );
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void LCSwizzleClassIfPresent(Class cls, SEL originalAction, SEL swizzledAction) {
    if(!cls) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, originalAction);
    Method swizzledMethod = class_getClassMethod(cls, swizzledAction);
    if(!originalMethod || !swizzledMethod) {
        return;
    }
    Class metaClass = object_getClass((id)cls);
    BOOL didAdd = class_addMethod(
        metaClass,
        originalAction,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    );
    if(didAdd) {
        class_replaceMethod(
            metaClass,
            swizzledAction,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        );
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void LCSwizzleClassIfPresentWithSourceClass(Class cls, Class sourceCls, SEL originalAction, SEL swizzledAction) {
    if(!cls || !sourceCls) {
        return;
    }
    Method originalMethod = class_getClassMethod(cls, originalAction);
    Method sourceMethod = class_getClassMethod(sourceCls, swizzledAction);
    if(!originalMethod || !sourceMethod) {
        return;
    }
    Class metaClass = object_getClass((id)cls);
    class_addMethod(
        metaClass,
        swizzledAction,
        method_getImplementation(sourceMethod),
        method_getTypeEncoding(sourceMethod)
    );
    Method swizzledMethod = class_getClassMethod(cls, swizzledAction);
    if(!swizzledMethod) {
        return;
    }
    BOOL didAdd = class_addMethod(
        metaClass,
        originalAction,
        method_getImplementation(swizzledMethod),
        method_getTypeEncoding(swizzledMethod)
    );
    if(didAdd) {
        class_replaceMethod(
            metaClass,
            swizzledAction,
            method_getImplementation(originalMethod),
            method_getTypeEncoding(originalMethod)
        );
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static BOOL LCNeutralAccessibilityFlag(id self, SEL _cmd) { return NO; }

static id LCEmptyArrayGetter(id self, SEL _cmd) { return @[]; }
static NSArray<NSString *> *LCBaselineFontFamiliesGetter(id self, SEL _cmd) {
    return @[@"Arial", @"Courier New", @"Georgia", @"Helvetica Neue", @"San Francisco", @"Times New Roman", @"Verdana"];
}
static NSString *LCNeutralStringGetter(id self, SEL _cmd) {
    LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
    return spoofGPUName.length > 0 ? spoofGPUName : @"Apple GPU";
}
static BOOL LCConfiguredBoolGetter(id self, SEL _cmd) {
    if(sel_isEqual(_cmd, NSSelectorFromString(@"isOtherAudioPlaying"))) return spoofAudioOtherPlaying;
    return spoofGraphicsSupportsRayTracing;
}
static BOOL LCTrueIntegerArgumentGetter(id self, SEL _cmd, NSInteger value) { return spoofGraphicsSupportsAllFamilies; }
static int LCDeniedCLAuthorizationGetter(id self, SEL _cmd) { return 2; }
static NSInteger LCDeniedAuthorizationGetter(id self, SEL _cmd) { return 2; }
static NSInteger LCDeniedMediaAuthorizationGetter(id self, SEL _cmd) { return 1; }
static NSInteger LCDeniedObjectArgumentGetter(id self, SEL _cmd, id value) { return 2; }
static NSInteger LCDeniedAuthorizationArgumentGetter(id self, SEL _cmd, NSInteger value) { return 2; }
static double LCAudioDoubleGetter(id self, SEL _cmd) {
    if(sel_isEqual(_cmd, NSSelectorFromString(@"sampleRate"))) return spoofAudioSampleRate;
    if(sel_isEqual(_cmd, NSSelectorFromString(@"outputLatency"))) return spoofAudioOutputLatency;
    return spoofAudioInputLatency;
}
static float LCNeutralFloatGetter(id self, SEL _cmd) { return spoofAudioOutputVolume; }
static NSInteger LCConfiguredChannelCountGetter(id self, SEL _cmd) {
    return sel_isEqual(_cmd, NSSelectorFromString(@"outputNumberOfChannels"))
        ? spoofAudioOutputChannels : spoofAudioInputChannels;
}
static unsigned long long LCNeutralWorkingSetGetter(id self, SEL _cmd) {
    LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
    return spoofGPUWorkingSetSize;
}

static void LCReplaceInstanceMethod(Class cls, NSString *selectorName, IMP implementation) {
    if(!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if(method) class_replaceMethod(cls, sel, implementation, method_getTypeEncoding(method));
}

static void LCReplaceClassMethod(Class cls, NSString *selectorName, IMP implementation) {
    if(!cls) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, sel);
    Class metaClass = object_getClass((id)cls);
    if(method && metaClass) class_replaceMethod(metaClass, sel, implementation, method_getTypeEncoding(method));
}

static void LCInstallLocalePrivacyProfile(void) {
    if(LCFeatureEnabled(@"locale.inputModes")) {
        LCReplaceClassMethod(UITextInputMode.class, @"activeInputModes", (IMP)LCEmptyArrayGetter);
    }
}

static void LCInstallAudioPrivacyProfile(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    Class sessionClass = object_getClass(session) ? [session class] : AVAudioSession.class;
    if(LCFeatureEnabled(@"audio.availableInputs")) LCReplaceInstanceMethod(sessionClass, @"availableInputs", (IMP)LCEmptyArrayGetter);
    if(LCFeatureEnabled(@"audio.sampleRate")) LCReplaceInstanceMethod(sessionClass, @"sampleRate", (IMP)LCAudioDoubleGetter);
    if(LCFeatureEnabled(@"audio.outputLatency")) LCReplaceInstanceMethod(sessionClass, @"outputLatency", (IMP)LCAudioDoubleGetter);
    if(LCFeatureEnabled(@"audio.inputLatency")) LCReplaceInstanceMethod(sessionClass, @"inputLatency", (IMP)LCAudioDoubleGetter);
    if(LCFeatureEnabled(@"audio.otherPlaying")) LCReplaceInstanceMethod(sessionClass, @"isOtherAudioPlaying", (IMP)LCConfiguredBoolGetter);
    if(LCFeatureEnabled(@"audio.outputVolume")) LCReplaceInstanceMethod(sessionClass, @"outputVolume", (IMP)LCNeutralFloatGetter);
    if(LCFeatureEnabled(@"audio.channels")) {
        LCReplaceInstanceMethod(sessionClass, @"outputNumberOfChannels", (IMP)LCConfiguredChannelCountGetter);
        LCReplaceInstanceMethod(sessionClass, @"inputNumberOfChannels", (IMP)LCConfiguredChannelCountGetter);
    }
    id route = session.currentRoute;
    if(route && LCFeatureEnabled(@"audio.routes")) {
        LCReplaceInstanceMethod([route class], @"outputs", (IMP)LCEmptyArrayGetter);
        LCReplaceInstanceMethod([route class], @"inputs", (IMP)LCEmptyArrayGetter);
    }
}

static BOOL sGraphicsPrivacyProfileEnabled = NO;

static void LCInstallGraphicsPrivacyProfile(void) {
    sGraphicsPrivacyProfileEnabled = YES;
}

static id<MTLDevice> hook_MTLCreateSystemDefaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device && (blockDeviceInfoReads || (spoofProfileEnabled && spoofGraphicsCategoryEnabled && sGraphicsPrivacyProfileEnabled))) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Class cls = [device class];
            if (blockDeviceInfoReads || LCFeatureEnabled(@"graphics.name")) LCReplaceInstanceMethod(cls, @"name", (IMP)LCNeutralStringGetter);
            if (blockDeviceInfoReads || LCFeatureEnabled(@"graphics.workingSet")) LCReplaceInstanceMethod(cls, @"recommendedMaxWorkingSetSize", (IMP)LCNeutralWorkingSetGetter);
            if (blockDeviceInfoReads || LCFeatureEnabled(@"graphics.rayTracing")) LCReplaceInstanceMethod(cls, @"supportsRaytracing", (IMP)LCConfiguredBoolGetter);
            if (blockDeviceInfoReads || LCFeatureEnabled(@"graphics.allFamilies")) LCReplaceInstanceMethod(cls, @"supportsFamily:", (IMP)LCTrueIntegerArgumentGetter);
        });
    }
    return device;
}

static void LCInstallAppEnumerationPrivacyProfile(void) {
    if(LCFeatureEnabled(@"app.fonts")) LCReplaceClassMethod(UIFont.class, @"familyNames", (IMP)LCBaselineFontFamiliesGetter);
    if(LCFeatureEnabled(@"app.voices")) LCReplaceClassMethod(AVSpeechSynthesisVoice.class, @"speechVoices", (IMP)LCEmptyArrayGetter);
}

static void LCInstallSensorsAndUserDataPrivacyProfile(void) {
    Class motionManager = NSClassFromString(@"CMMotionManager");
    if(LCFeatureEnabled(@"sensors.accelerometer")) LCReplaceInstanceMethod(motionManager, @"isAccelerometerAvailable", (IMP)LCNeutralAccessibilityFlag);
    if(LCFeatureEnabled(@"sensors.gyroscope")) LCReplaceInstanceMethod(motionManager, @"isGyroAvailable", (IMP)LCNeutralAccessibilityFlag);
    if(LCFeatureEnabled(@"sensors.magnetometer")) LCReplaceInstanceMethod(motionManager, @"isMagnetometerAvailable", (IMP)LCNeutralAccessibilityFlag);
    if(LCFeatureEnabled(@"sensors.deviceMotion")) LCReplaceInstanceMethod(motionManager, @"isDeviceMotionAvailable", (IMP)LCNeutralAccessibilityFlag);
    Class pedometer = NSClassFromString(@"CMPedometer");
    if(LCFeatureEnabled(@"sensors.pedometer")) {
        for(NSString *selector in @[@"isStepCountingAvailable", @"isDistanceAvailable", @"isFloorCountingAvailable", @"isPaceAvailable", @"isCadenceAvailable", @"isPedometerEventTrackingAvailable"]) {
            LCReplaceClassMethod(pedometer, selector, (IMP)LCNeutralAccessibilityFlag);
        }
    }
    Class altimeter = NSClassFromString(@"CMAltimeter");
    if(LCFeatureEnabled(@"sensors.altimeter")) {
        LCReplaceClassMethod(altimeter, @"isRelativeAltitudeAvailable", (IMP)LCNeutralAccessibilityFlag);
        LCReplaceClassMethod(altimeter, @"isAbsoluteAltitudeAvailable", (IMP)LCNeutralAccessibilityFlag);
    }

    Class location = NSClassFromString(@"CLLocationManager");
    if(LCFeatureEnabled(@"permissions.location")) {
        LCReplaceInstanceMethod(location, @"authorizationStatus", (IMP)LCDeniedCLAuthorizationGetter);
        LCReplaceClassMethod(location, @"authorizationStatus", (IMP)LCDeniedCLAuthorizationGetter);
    }
    if(LCFeatureEnabled(@"permissions.capture")) LCReplaceClassMethod(NSClassFromString(@"AVCaptureDevice"), @"authorizationStatusForMediaType:", (IMP)LCDeniedObjectArgumentGetter);
    if(LCFeatureEnabled(@"permissions.photos")) LCReplaceClassMethod(NSClassFromString(@"PHPhotoLibrary"), @"authorizationStatusForAccessLevel:", (IMP)LCDeniedAuthorizationArgumentGetter);
    if(LCFeatureEnabled(@"permissions.contacts")) LCReplaceClassMethod(NSClassFromString(@"CNContactStore"), @"authorizationStatusForEntityType:", (IMP)LCDeniedAuthorizationArgumentGetter);
    if(LCFeatureEnabled(@"permissions.events")) LCReplaceClassMethod(NSClassFromString(@"EKEventStore"), @"authorizationStatusForEntityType:", (IMP)LCDeniedAuthorizationArgumentGetter);
    if(LCFeatureEnabled(@"permissions.media")) LCReplaceClassMethod(NSClassFromString(@"MPMediaLibrary"), @"authorizationStatus", (IMP)LCDeniedMediaAuthorizationGetter);
    if(LCFeatureEnabled(@"permissions.bluetooth")) LCReplaceClassMethod(NSClassFromString(@"CBCentralManager"), @"authorization", (IMP)LCDeniedAuthorizationGetter);
}

static NSString *LCJSONString(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""] options:0 error:nil];
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return array.length >= 2 ? [array substringWithRange:NSMakeRange(1, array.length - 2)] : @"\"\"";
}

static NSString *LCPreferredWebKitPlatform(void) {
    if([spoofDeviceModel rangeOfString:@"ipad" options:NSCaseInsensitiveSearch].location != NSNotFound ||
       [spoofHardwareModel hasPrefix:@"iPad"]) {
        return @"iPad";
    }
    if(spoofDeviceModel.length > 0 && ![spoofDeviceModel isEqualToString:@"Unknown"]) {
        return spoofDeviceModel;
    }
    return @"iPhone";
}

static NSString *LCBuildWebKitUserAgent(void) {
    if(spoofCustomUserAgent.length > 0) {
        return spoofCustomUserAgent;
    }
    NSString *platform = LCPreferredWebKitPlatform();
    NSString *osVersion = spoofSystemVersion.length > 0 ? spoofSystemVersion : @"27.2";
    NSString *underscored = [osVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *cpuToken = [platform isEqualToString:@"iPad"]
        ? [NSString stringWithFormat:@"CPU OS %@ like Mac OS X", underscored]
        : [NSString stringWithFormat:@"CPU iPhone OS %@ like Mac OS X", underscored];
    return [NSString stringWithFormat:@"Mozilla/5.0 (%@; %@) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 Safari/604.1",
            platform, cpuToken, osVersion];
}

static NSString *LCPreferredAcceptLanguageHeader(void) {
    NSString *identifier = spoofLocale.localeIdentifier;
    if(identifier.length == 0) {
        return nil;
    }
    NSString *bcp47 = [identifier stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSString *langOnly = [spoofLocale objectForKey:NSLocaleLanguageCode];
    if(langOnly.length > 0 && ![bcp47.lowercaseString isEqualToString:langOnly.lowercaseString]) {
        return [NSString stringWithFormat:@"%@,%@;q=0.9", bcp47, langOnly];
    }
    return bcp47;
}

static NSString *LCWebViewProfileScript(void) {
    NSString *platform = LCPreferredWebKitPlatform();
    NSString *language = spoofLocale.localeIdentifier.length > 0
        ? [spoofLocale.localeIdentifier stringByReplacingOccurrencesOfString:@"_" withString:@"-"] : @"en-US";
    NSString *ua = LCBuildWebKitUserAgent();
    NSInteger cores = spoofProcessorCount > 0 ? spoofProcessorCount : 6;
    CGFloat pointsWidth = spoofScreenPointWidth > 0 ? spoofScreenPointWidth
        : (spoofScreenScale > 0 ? spoofScreenWidth / spoofScreenScale : spoofScreenWidth);
    CGFloat pointsHeight = spoofScreenPointHeight > 0 ? spoofScreenPointHeight
        : (spoofScreenScale > 0 ? spoofScreenHeight / spoofScreenScale : spoofScreenHeight);
    CGFloat safePointW = pointsWidth > 0 ? pointsWidth : 402.0;
    CGFloat safePointH = pointsHeight > 0 ? pointsHeight : 874.0;
    NSInteger timezoneOffset = spoofTimeZone ? -[spoofTimeZone secondsFromGMT] / 60 : 0;
    uint32_t canvasSeed = LCEffectiveWebCanvasSeed();

    NSMutableString *script = [@"(()=>{'use strict';"
        "const cloakMap=new WeakMap();"
        "const origToStr=Function.prototype.toString;"
        "const cloakedToStr=function toString(){if(cloakMap.has(this))return cloakMap.get(this);return origToStr.call(this);};"
        "cloakMap.set(cloakedToStr,'function toString() { [native code] }');"
        "Function.prototype.toString=cloakedToStr;"
        "const cloak=(fn,label)=>{cloakMap.set(fn,'function '+(label||fn.name||'')+'() { [native code] }');return fn;};"
        "const d=(o,k,v)=>{try{if(!o)return;const g=cloak(function(){return v},'get '+k);Object.defineProperty(o,k,{get:g,configurable:true});}catch(e){}};" mutableCopy];

    if(LCFeatureEnabled(@"web.navigator")) {
        [script appendFormat:@"d(Navigator.prototype,'userAgent',%@);d(Navigator.prototype,'platform',%@);d(Navigator.prototype,'language',%@);d(Navigator.prototype,'languages',[%@]);d(Navigator.prototype,'hardwareConcurrency',%ld);d(Navigator.prototype,'maxTouchPoints',5);",
            LCJSONString(ua), LCJSONString(platform), LCJSONString(language), LCJSONString(language), (long)cores];
    }
    if(LCFeatureEnabled(@"web.screen")) {
        [script appendFormat:@"d(Screen.prototype,'width',%.0f);d(Screen.prototype,'height',%.0f);d(Screen.prototype,'availWidth',%.0f);d(Screen.prototype,'availHeight',%.0f);d(Screen.prototype,'colorDepth',%ld);d(Screen.prototype,'pixelDepth',%ld);d(window,'devicePixelRatio',%.3f);",
            safePointW, safePointH, safePointW, safePointH,
            (long)spoofWebColorDepth, (long)spoofWebColorDepth, spoofScreenScale > 0 ? spoofScreenScale : 3.0];
    }
    if(LCFeatureEnabled(@"web.timeZone")) {
        [script appendFormat:@"Date.prototype.getTimezoneOffset=cloak(function getTimezoneOffset(){return %ld},'getTimezoneOffset');"
            "const ir=Intl.DateTimeFormat.prototype.resolvedOptions;"
            "Intl.DateTimeFormat.prototype.resolvedOptions=cloak(function resolvedOptions(){const r=ir.call(this);r.timeZone=%@;return r},'resolvedOptions');",
            (long)timezoneOffset, LCJSONString(spoofTimeZone.name ?: @"Etc/UTC")];
    }
    if(LCFeatureEnabled(@"web.webGL") || LCFeatureEnabled(@"web.canvas")) {
        [script appendFormat:
            @"const baseSeed=(%u)>>>0;"
            "const m32=a=>()=>{let t=a=(a+0x6D2B79F5)|0;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);return((t^(t>>>14))>>>0);};"
            "const farbleRGBA=(data,w,h,tag)=>{if(!data||!data.length)return;const rng=m32((baseSeed^tag^Math.imul((w|0)+1,73856093)^Math.imul((h|0)+1,19349663))>>>0);const totalPx=(data.length>>>2);if(totalPx<=0)return;const stride=Math.max(1,Math.floor(totalPx/512));let touched=0;for(let p=0;p<totalPx;p+=stride){const i=p<<2;if(data[i+3]===0)continue;const r=rng();const ch=r&3;if(ch<3){const delta=(r&8)?1:-1;const cur=data[i+ch];data[i+ch]=cur>=255?254:(cur<=0?1:cur+delta);touched=1;}}if(!touched&&data.length>=4){rng();if(data[3]>0){data[0]=data[0]>=255?254:data[0]+1;}}};",
            (unsigned int)canvasSeed];
    }
    if(LCFeatureEnabled(@"web.webGL")) {
        [script appendFormat:
            @"const wglDebugCtx=new WeakSet();"
            "const wglPatch=proto=>{"
            "if(!proto)return;"
            "const ge=proto.getExtension;"
            "if(ge)proto.getExtension=cloak(function getExtension(n){const res=ge.call(this,n);if(n==='WEBGL_debug_renderer_info'&&res)wglDebugCtx.add(this);return res;},'getExtension');"
            "const gp=proto.getParameter;"
            "if(gp)proto.getParameter=cloak(function getParameter(p){const ov=gp.call(this,p);if(p===37445&&(wglDebugCtx.has(this)||ov!=null))return %@;if(p===37446&&(wglDebugCtx.has(this)||ov!=null))return %@;return ov;},'getParameter');"
            "};"
            "if(typeof WebGLRenderingContext!=='undefined')wglPatch(WebGLRenderingContext.prototype);"
            "if(typeof WebGL2RenderingContext!=='undefined')wglPatch(WebGL2RenderingContext.prototype);",
            LCJSONString(spoofWebGLVendor), LCJSONString(spoofWebGLRenderer)];
    }
    if(LCFeatureEnabled(@"web.canvas")) {
        [script appendString:
            @"const orig2DGID=typeof CanvasRenderingContext2D!=='undefined'?CanvasRenderingContext2D.prototype.getImageData:null;"
            "const origOffGID=typeof OffscreenCanvasRenderingContext2D!=='undefined'?OffscreenCanvasRenderingContext2D.prototype.getImageData:null;"
            "if(orig2DGID){CanvasRenderingContext2D.prototype.getImageData=cloak(function getImageData(sx,sy,sw,sh){const img=orig2DGID.apply(this,arguments);farbleRGBA(img.data,img.width,img.height,0x243F6A88);return img;},'getImageData');}"
            "if(origOffGID){OffscreenCanvasRenderingContext2D.prototype.getImageData=cloak(function getImageData(sx,sy,sw,sh){const img=origOffGID.apply(this,arguments);farbleRGBA(img.data,img.width,img.height,0x243F6A88);return img;},'getImageData');}"
            "const makeShadow2D=(src,tag,gid)=>{try{const w=src.width|0,h=src.height|0;if(w<=0||h<=0||!gid)return null;const sh=(typeof document!=='undefined'&&document.createElement)?document.createElement('canvas'):(typeof OffscreenCanvas!=='undefined'?new OffscreenCanvas(w,h):null);if(!sh)return null;sh.width=w;sh.height=h;const ctx=sh.getContext('2d');if(!ctx)return null;ctx.drawImage(src,0,0);const img=gid.call(ctx,0,0,w,h);farbleRGBA(img.data,w,h,tag);ctx.putImageData(img,0,0);return sh;}catch(e){return null;}};"
            "if(typeof HTMLCanvasElement!=='undefined'){"
            "const origTD=HTMLCanvasElement.prototype.toDataURL;"
            "if(origTD)HTMLCanvasElement.prototype.toDataURL=cloak(function toDataURL(){const sh=makeShadow2D(this,0x243F6A88,orig2DGID);return origTD.apply(sh||this,arguments);},'toDataURL');"
            "const origTB=HTMLCanvasElement.prototype.toBlob;"
            "if(origTB)HTMLCanvasElement.prototype.toBlob=cloak(function toBlob(){const sh=makeShadow2D(this,0x243F6A88,orig2DGID);return origTB.apply(sh||this,arguments);},'toBlob');"
            "}"
            "if(typeof OffscreenCanvas!=='undefined'&&typeof OffscreenCanvas.prototype.convertToBlob==='function'){"
            "const origCTB=OffscreenCanvas.prototype.convertToBlob;"
            "OffscreenCanvas.prototype.convertToBlob=cloak(function convertToBlob(){try{const w=this.width|0,h=this.height|0;if(w>0&&h>0&&origOffGID){const sh=new OffscreenCanvas(w,h);const ctx=sh.getContext('2d');if(ctx){ctx.drawImage(this,0,0);const img=origOffGID.call(ctx,0,0,w,h);farbleRGBA(img.data,w,h,0x243F6A88);ctx.putImageData(img,0,0);return origCTB.apply(sh,arguments);}}}catch(e){}return origCTB.apply(this,arguments);},'convertToBlob');"
            "}"
            "const patchWGLRead=proto=>{const rp=proto&&proto.readPixels;if(rp)proto.readPixels=cloak(function readPixels(x,y,w,h,fmt,type,px){const r=rp.apply(this,arguments);if(px&&(px instanceof Uint8Array||px instanceof Uint8ClampedArray))farbleRGBA(px,w,h,0x13198A2E);return r;},'readPixels');};"
            "if(typeof WebGLRenderingContext!=='undefined')patchWGLRead(WebGLRenderingContext.prototype);"
            "if(typeof WebGL2RenderingContext!=='undefined')patchWGLRead(WebGL2RenderingContext.prototype);"
            "if(typeof AudioBuffer!=='undefined'){"
            "const abProto=AudioBuffer.prototype;"
            "const origGetCh=abProto.getChannelData;"
            "const origCopyFrom=abProto.copyFromChannel;"
            "const patchedCh=new WeakMap();"
            "if(origGetCh){abProto.getChannelData=cloak(function getChannelData(ch){const arr=origGetCh.call(this,ch);let set=patchedCh.get(this);if(!set){set=new Set();patchedCh.set(this,set);}if(!set.has(ch)){set.add(ch);const rng=m32((baseSeed^0x85EBCA6B^Math.imul((ch|0)+1,2654435761))>>>0);const step=Math.max(1,Math.floor(arr.length/256));for(let i=0;i<arr.length;i+=step){const r=(rng()/4294967296)-0.5;arr[i]+=r*1e-6;}}return arr;},'getChannelData');}"
            "if(origCopyFrom){abProto.copyFromChannel=cloak(function copyFromChannel(dest,ch,start){origCopyFrom.apply(this,arguments);const rng=m32((baseSeed^0x85EBCA6B^Math.imul((ch|0)+1,2654435761))>>>0);const s0=(start|0);const total=this.length||dest.length;const step=Math.max(1,Math.floor(total/256));for(let idx=0;idx<s0&&idx<total;idx+=step){rng();}for(let i=0;i<dest.length;i++){const srcIdx=s0+i;if(srcIdx>=0&&(srcIdx%step)===0){const r=(rng()/4294967296)-0.5;dest[i]+=r*1e-6;}}},'copyFromChannel');}"
            "}"];
    }
    [script appendString:@"})();"];
    return script;
}

static BOOL LCParseVersionPart(NSString *part, NSInteger *outValue) {
    if(![part isKindOfClass:NSString.class] || part.length == 0) {
        return NO;
    }
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if([part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return NO;
    }
    long long parsedValue = part.longLongValue;
    if(parsedValue < 0 || parsedValue > NSIntegerMax) {
        return NO;
    }
    *outValue = (NSInteger)parsedValue;
    return YES;
}

static BOOL LCBoolWithDefault(NSDictionary *dictionary, NSString *key, BOOL defaultValue) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : defaultValue;
}

static BOOL LCParseSystemVersion(NSString *versionString, NSOperatingSystemVersion *outVersion) {
    if(![versionString isKindOfClass:NSString.class]) {
        return NO;
    }
    NSArray<NSString*> *parts = [versionString componentsSeparatedByString:@"."];
    if(parts.count == 0 || parts.count > 3) {
        return NO;
    }

    NSInteger major = 0;
    NSInteger minor = 0;
    NSInteger patch = 0;
    if(!LCParseVersionPart(parts[0], &major)) {
        return NO;
    }
    if(parts.count > 1 && !LCParseVersionPart(parts[1], &minor)) {
        return NO;
    }
    if(parts.count > 2 && !LCParseVersionPart(parts[2], &patch)) {
        return NO;
    }
    outVersion->majorVersion = major;
    outVersion->minorVersion = minor;
    outVersion->patchVersion = patch;
    return YES;
}

static NSInteger LCCompareOSVersion(NSOperatingSystemVersion lhs, NSOperatingSystemVersion rhs) {
    if(lhs.majorVersion != rhs.majorVersion) {
        return lhs.majorVersion < rhs.majorVersion ? -1 : 1;
    }
    if(lhs.minorVersion != rhs.minorVersion) {
        return lhs.minorVersion < rhs.minorVersion ? -1 : 1;
    }
    if(lhs.patchVersion != rhs.patchVersion) {
        return lhs.patchVersion < rhs.patchVersion ? -1 : 1;
    }
    return 0;
}

static NSTimeZone *LCBlockedTimeZone(void) {
    return [NSTimeZone timeZoneWithAbbreviation:@"GMT"] ?: [NSTimeZone systemTimeZone];
}

static NSLocale *LCBlockedLocale(void) {
    return [[NSLocale alloc] initWithLocaleIdentifier:@"und"];
}

static NSCalendar *LCCalendarForProfile(NSTimeZone *timeZone) {
    NSCalendar *calendar = nil;
    if(!blockDeviceInfoReads && spoofLocaleCategoryEnabled && spoofLocale) {
        id localeCalendar = [spoofLocale objectForKey:NSLocaleCalendar];
        if([localeCalendar isKindOfClass:NSCalendar.class]) {
            calendar = [localeCalendar copy];
        }
    }
    if(!calendar) {
        calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    }
    if(timeZone) {
        calendar.timeZone = timeZone;
    }
    return calendar;
}

static UIWindowScene *LCForegroundWindowScene(void) {
    UIWindowScene *fallbackScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (!fallbackScene) {
            fallbackScene = windowScene;
        }
    }
    return fallbackScene;
}

static UIWindow *LCKeyWindowForScene(UIWindowScene *scene) {
    if (!scene) {
        return nil;
    }
    UIWindow *keyWindow = scene.keyWindow;
    if (keyWindow) {
        return keyWindow;
    }
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return scene.windows.firstObject;
}

static UIWindowLevel LCOverlayWindowLevel(void) {
    UIWindow *keyWindow = LCKeyWindowForScene(LCForegroundWindowScene());
    return (keyWindow ? keyWindow.windowLevel : UIWindowLevelNormal) + 1;
}

static UIWindow *LCCreateOverlayAlertWindow(void) {
    UIWindowScene *scene = LCForegroundWindowScene() ?: (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    if (!scene) return nil;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.rootViewController = [UIViewController new];
    window.windowLevel = LCOverlayWindowLevel();
    return window;
}

static void LCPresentAlertInOverlayWindow(UIWindow *window, UIAlertController *alert) {
    if (!window) return;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - System & Display Profile: kernel identity
// Intercept low-level C APIs (`sysctlbyname`, numeric MIB `sysctl`, `uname`)
// that analytics and anti-fraud SDKs use to read the real hardware identifier,
// board config, memory, CPU count, OS build, and Darwin kernel release.

static NSInteger LCEffectiveOSMajorVersion(void) {
    if (spoofOperatingSystemVersionValid && spoofOperatingSystemVersion.majorVersion > 0) {
        return spoofOperatingSystemVersion.majorVersion;
    }
    return 27;
}

static NSInteger LCEffectiveOSMinorVersion(void) {
    if (spoofOperatingSystemVersionValid && spoofOperatingSystemVersion.majorVersion > 0) {
        return MAX(0, spoofOperatingSystemVersion.minorVersion);
    }
    return (LCEffectiveOSMajorVersion() >= 27) ? 2 : 0;
}

static NSString *LCDerivedDarwinRelease(void) {
    NSInteger osMajor = LCEffectiveOSMajorVersion();
    int32_t darwinMajor = LCExpectedDarwinMajorForOSMajor((int32_t)osMajor);
    NSInteger darwinMinor = LCEffectiveOSMinorVersion();
    return [NSString stringWithFormat:@"%d.%ld.0", darwinMajor, (long)darwinMinor];
}

static NSString *LCDerivedOSBuildVersion(void) {
    NSInteger osMajor = LCEffectiveOSMajorVersion();
    NSInteger osMinor = LCEffectiveOSMinorVersion();
    char minorLetter = (char)('A' + MIN(MAX(osMinor, 0), 10));
    if (osMajor >= 27) {
        if (osMinor == 0) return @"24A340";
        if (osMinor == 1) return @"24B83";
        if (osMinor == 2) return @"24C101";
        return [NSString stringWithFormat:@"24%c85", minorLetter];
    }
    if (osMajor == 26) {
        return (osMinor == 0) ? @"23A340" : [NSString stringWithFormat:@"23%c85", minorLetter];
    }
    if (osMajor == 18) {
        return [NSString stringWithFormat:@"22%c83", minorLetter];
    }
    if (osMajor == 17) {
        return [NSString stringWithFormat:@"21%c329", minorLetter];
    }
    return @"20A362";
}

static NSString *LCDerivedCFNetworkVersion(void) {
    NSInteger osMajor = LCEffectiveOSMajorVersion();
    if (osMajor >= 27) return @"3826.500.131";
    if (osMajor == 26) return @"3826.400.100";
    if (osMajor == 18) return @"1568.300.101";
    if (osMajor == 17) return @"1498.700.2";
    return @"1410.0.3";
}

static NSUUID *LCBlockedZeroUUID(void) {
    static NSUUID *zeroUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        zeroUUID = [[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000000"];
    });
    return zeroUUID;
}

static BOOL LCHostNameSpoofActive(void) {
    if (blockDeviceInfoReads) {
        return YES;
    }
    if (!spoofProfileEnabled) {
        return NO;
    }
    if (spoofIdentityCategoryEnabled && spoofHostName.length > 0) {
        return YES;
    }
    return spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.hostName");
}

static NSString *LCEffectiveSpoofHostName(void) {
    return spoofHostName.length > 0 ? spoofHostName : @"iphone.local";
}

static BOOL LCWriteSysctlString(NSString *value, void *oldp, size_t *oldlenp, int *outErrnoReturn) {
    if (value.length == 0 || !oldlenp) {
        return NO;
    }
    const char *utf8 = value.UTF8String;
    size_t requiredLength = strlen(utf8) + 1;
    if (!oldp) {
        *oldlenp = requiredLength;
        *outErrnoReturn = 0;
        return YES;
    }
    if (*oldlenp < requiredLength) {
        *oldlenp = requiredLength;
        errno = ENOMEM;
        *outErrnoReturn = -1;
        return YES;
    }
    memcpy(oldp, utf8, requiredLength);
    *oldlenp = requiredLength;
    *outErrnoReturn = 0;
    return YES;
}

static BOOL LCWriteSysctlBytes(const void *bytes, size_t length, void *oldp, size_t *oldlenp, int *outErrnoReturn) {
    if (!bytes || length == 0 || !oldlenp) {
        return NO;
    }
    if (!oldp) {
        *oldlenp = length;
        *outErrnoReturn = 0;
        return YES;
    }
    if (*oldlenp < length) {
        *oldlenp = length;
        errno = ENOMEM;
        *outErrnoReturn = -1;
        return YES;
    }
    memcpy(oldp, bytes, length);
    *oldlenp = length;
    *outErrnoReturn = 0;
    return YES;
}

static BOOL LCInterceptSysctlByKey(const char *name, void *oldp, size_t *oldlenp, void *newp, int *outReturn) {
    if (!name || newp || !oldlenp) {
        return NO;
    }
    NSString *spoofedValue = nil;
    if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofIdentityCategoryEnabled)) && strcmp(name, "hw.machine") == 0) {
        spoofedValue = spoofHardwareModel;
    } else if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofIdentityCategoryEnabled)) &&
               (strcmp(name, "hw.model") == 0 || strcmp(name, "hw.target") == 0)) {
        spoofedValue = spoofBoardModel.length > 0 ? spoofBoardModel : spoofHardwareModel;
    } else if (strcmp(name, "kern.hostname") == 0 && LCHostNameSpoofActive()) {
        spoofedValue = LCEffectiveSpoofHostName();
    } else if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) && strcmp(name, "kern.version") == 0) {
        spoofedValue = spoofKernelVersion;
    } else if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) &&
               strcmp(name, "kern.osproductversion") == 0 && spoofSystemVersion.length > 0) {
        spoofedValue = spoofSystemVersion;
    } else if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) &&
               strcmp(name, "kern.osrelease") == 0 && (spoofSystemVersion.length > 0 || blockDeviceInfoReads)) {
        spoofedValue = LCDerivedDarwinRelease();
    } else if ((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) &&
               strcmp(name, "kern.osversion") == 0 && (spoofSystemVersion.length > 0 || blockDeviceInfoReads)) {
        spoofedValue = LCDerivedOSBuildVersion();
    }
    if (spoofedValue.length > 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlString(spoofedValue, oldp, oldlenp, outReturn);
    }

    int32_t cpuType = blockDeviceInfoReads ? CPU_TYPE_ARM64 : ((spoofProfileEnabled && spoofSystemCategoryEnabled) ? spoofCPUType : 0);
    int32_t cpuSubtype = blockDeviceInfoReads ? 0 : ((spoofProfileEnabled && spoofSystemCategoryEnabled) ? spoofCPUSubtype : -1);
    int32_t ncpu = blockDeviceInfoReads ? 6 : ((spoofProfileEnabled && spoofSystemCategoryEnabled && spoofProcessorCount > 0) ? (int32_t)spoofProcessorCount : 0);
    uint64_t memSize = blockDeviceInfoReads
        ? (8ULL * 1024ULL * 1024ULL * 1024ULL)
        : ((spoofProfileEnabled && spoofSystemCategoryEnabled && spoofPhysicalMemory > 0) ? (uint64_t)spoofPhysicalMemory : 0ULL);
    uint32_t physMem32 = (uint32_t)MIN(memSize, (uint64_t)INT32_MAX);
    struct timeval bootTime = {
        .tv_sec = blockDeviceInfoReads ? 0 : ((spoofProfileEnabled && spoofSystemCategoryEnabled) ? spoofBootTime : 0),
        .tv_usec = 0
    };

    if (strcmp(name, "hw.cputype") == 0 && cpuType > 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&cpuType, sizeof(cpuType), oldp, oldlenp, outReturn);
    }
    if (strcmp(name, "hw.cpusubtype") == 0 && cpuSubtype >= 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&cpuSubtype, sizeof(cpuSubtype), oldp, oldlenp, outReturn);
    }
    if (ncpu > 0 && (strcmp(name, "hw.ncpu") == 0 || strcmp(name, "hw.activecpu") == 0 ||
                     strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.physicalcpu_max") == 0 ||
                     strcmp(name, "hw.logicalcpu") == 0 || strcmp(name, "hw.logicalcpu_max") == 0)) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&ncpu, sizeof(ncpu), oldp, oldlenp, outReturn);
    }
    if (memSize > 0 && strcmp(name, "hw.memsize") == 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&memSize, sizeof(memSize), oldp, oldlenp, outReturn);
    }
    if (memSize > 0 && (strcmp(name, "hw.physmem") == 0 || strcmp(name, "hw.usermem") == 0)) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&physMem32, sizeof(physMem32), oldp, oldlenp, outReturn);
    }
    if (strcmp(name, "kern.boottime") == 0 &&
        (blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled && spoofBootTime > 0))) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&bootTime, sizeof(bootTime), oldp, oldlenp, outReturn);
    }
    if (strcmp(name, "hw.cpufamily") == 0 &&
        (blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled && spoofHardwareModel.length > 0))) {
        uint32_t cpuFamily =
#ifdef CPUFAMILY_ARM_TUPAI
            CPUFAMILY_ARM_TUPAI;
#else
            0x204526d0u;
#endif
        if ([spoofHardwareModel hasPrefix:@"iPhone19,"]) {
#ifdef CPUFAMILY_ARM_NEVIS
            cpuFamily = CPUFAMILY_ARM_NEVIS;
#else
            cpuFamily = 0x37652b0cu;
#endif
        } else if ([spoofHardwareModel hasPrefix:@"iPhone18,"]) {
#ifdef CPUFAMILY_ARM_BORNEO
            cpuFamily = CPUFAMILY_ARM_BORNEO;
#else
            cpuFamily = 0x7db56df1u;
#endif
        } else if ([spoofHardwareModel hasPrefix:@"iPhone16,"]) {
#ifdef CPUFAMILY_ARM_COLL
            cpuFamily = CPUFAMILY_ARM_COLL;
#else
            cpuFamily = 0x2876f5b5u;
#endif
        } else if ([spoofHardwareModel hasPrefix:@"iPhone15,"] || [spoofHardwareModel hasPrefix:@"iPhone14,"]) {
#ifdef CPUFAMILY_ARM_EVEREST_SAWTOOTH
            cpuFamily = CPUFAMILY_ARM_EVEREST_SAWTOOTH;
#else
            cpuFamily = 0x8765edeau;
#endif
        }
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCWriteSysctlBytes(&cpuFamily, sizeof(cpuFamily), oldp, oldlenp, outReturn);
    }
    return NO;
}

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!spoofProfileEnabled && !blockDeviceInfoReads) {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    int handledReturn = 0;
    if (LCInterceptSysctlByKey(name, oldp, oldlenp, newp, &handledReturn)) {
        return handledReturn;
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static const char *LCSysctlNameFromMIB(const int *name, u_int namelen) {
    if (!name || namelen < 2 || namelen > CTL_MAXNAME) {
        return NULL;
    }
    typedef struct {
        const char *key;
        int mib[CTL_MAXNAME];
        size_t len;
    } LCSysctlMIBEntry;

    static LCSysctlMIBEntry sTable[24];
    static size_t sTableCount = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static const char *const kKeys[] = {
            "hw.machine", "hw.model", "hw.target",
            "hw.ncpu", "hw.activecpu", "hw.physicalcpu", "hw.physicalcpu_max",
            "hw.logicalcpu", "hw.logicalcpu_max",
            "hw.cputype", "hw.cpusubtype", "hw.cpufamily",
            "hw.memsize", "hw.physmem", "hw.usermem",
            "kern.hostname", "kern.version", "kern.osrelease",
            "kern.osversion", "kern.osproductversion", "kern.boottime"
        };
        for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++) {
            int resolved[CTL_MAXNAME];
            size_t resolvedLen = CTL_MAXNAME;
            if (sysctlnametomib(kKeys[i], resolved, &resolvedLen) == 0 &&
                resolvedLen > 0 && resolvedLen <= CTL_MAXNAME &&
                sTableCount < sizeof(sTable) / sizeof(sTable[0])) {
                LCSysctlMIBEntry *entry = &sTable[sTableCount++];
                entry->key = kKeys[i];
                entry->len = resolvedLen;
                memcpy(entry->mib, resolved, resolvedLen * sizeof(int));
            }
        }
    });

    for (size_t i = 0; i < sTableCount; i++) {
        if (sTable[i].len == namelen && memcmp(sTable[i].mib, name, namelen * sizeof(int)) == 0) {
            return sTable[i].key;
        }
    }

    if (name[0] == CTL_HW) {
        switch (name[1]) {
            case HW_MACHINE: return "hw.machine";
            case HW_MODEL: return "hw.model";
            case HW_NCPU: return "hw.ncpu";
            case HW_PHYSMEM: return "hw.physmem";
            case HW_USERMEM: return "hw.usermem";
#ifdef HW_MEMSIZE
            case HW_MEMSIZE: return "hw.memsize";
#endif
#ifdef HW_AVAILCPU
            case HW_AVAILCPU: return "hw.activecpu";
#endif
#ifdef HW_TARGET
            case HW_TARGET: return "hw.target";
#endif
            default: return NULL;
        }
    }
    if (name[0] == CTL_KERN) {
        switch (name[1]) {
            case KERN_HOSTNAME: return "kern.hostname";
            case KERN_VERSION: return "kern.version";
            case KERN_OSRELEASE: return "kern.osrelease";
            case KERN_BOOTTIME: return "kern.boottime";
#ifdef KERN_OSVERSION
            case KERN_OSVERSION: return "kern.osversion";
#endif
            default: return NULL;
        }
    }
    return NULL;
}

static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!spoofProfileEnabled && !blockDeviceInfoReads) {
        return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    }
    const char *mappedName = LCSysctlNameFromMIB(name, namelen);
    int handledReturn = 0;
    if (mappedName && LCInterceptSysctlByKey(mappedName, oldp, oldlenp, newp, &handledReturn)) {
        return handledReturn;
    }
    return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static int hook_uname(struct utsname *uts) {
    int ret = uname(uts);
    if(ret == 0 && uts) {
        if((blockDeviceInfoReads || (spoofProfileEnabled && spoofIdentityCategoryEnabled)) && spoofHardwareModel.length > 0) {
            strlcpy(uts->machine, spoofHardwareModel.UTF8String, sizeof(uts->machine));
            LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        }
        if(LCHostNameSpoofActive()) {
            strlcpy(uts->nodename, LCEffectiveSpoofHostName().UTF8String, sizeof(uts->nodename));
            LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        }
        if((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) && spoofKernelVersion.length > 0) {
            strlcpy(uts->version, spoofKernelVersion.UTF8String, sizeof(uts->version));
        }
        if((blockDeviceInfoReads || (spoofProfileEnabled && spoofSystemCategoryEnabled)) &&
           (spoofSystemVersion.length > 0 || blockDeviceInfoReads)) {
            strlcpy(uts->release, LCDerivedDarwinRelease().UTF8String, sizeof(uts->release));
        }
    }
    return ret;
}

static int hook_gethostname(char *name, size_t namelen) {
    if(LCHostNameSpoofActive() && namelen > 0 && name) {
        strlcpy(name, LCEffectiveSpoofHostName().UTF8String, namelen);
        LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        return 0;
    }
    return gethostname(name, namelen);
}

static int hook_getifaddrs(struct ifaddrs **ifap) {
    if(blockDeviceInfoReads || (spoofProfileEnabled && spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.interfaces"))) {
        if(ifap) *ifap = NULL;
        return 0;
    }
    return getifaddrs(ifap);
}

#define LC_ACCESSIBILITY_HOOK(_name, _key) \
    static BOOL hook_##_name(void) { \
        if(blockDeviceInfoReads || (spoofProfileEnabled && spoofAccessibilityCategoryEnabled && LCFeatureEnabled(_key))) { \
            LCRecordProfileInterception(LCProfileTelemetryVectorHardware); \
            return NO; \
        } \
        return _name(); \
    }

LC_ACCESSIBILITY_HOOK(UIAccessibilityIsVoiceOverRunning, @"accessibility.voiceOver")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsMonoAudioEnabled, @"accessibility.monoAudio")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsClosedCaptioningEnabled, @"accessibility.closedCaptions")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsInvertColorsEnabled, @"accessibility.invertColors")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsGuidedAccessEnabled, @"accessibility.guidedAccess")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsBoldTextEnabled, @"accessibility.boldText")
LC_ACCESSIBILITY_HOOK(AXShowBordersEnabled, @"accessibility.buttonShapes")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsGrayscaleEnabled, @"accessibility.grayscale")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsReduceTransparencyEnabled, @"accessibility.reduceTransparency")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsReduceMotionEnabled, @"accessibility.reduceMotion")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsVideoAutoplayEnabled, @"accessibility.videoAutoplay")
LC_ACCESSIBILITY_HOOK(UIAccessibilityDarkerSystemColorsEnabled, @"accessibility.darkerColors")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsSwitchControlRunning, @"accessibility.switchControl")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsSpeakSelectionEnabled, @"accessibility.speakSelection")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsSpeakScreenEnabled, @"accessibility.speakScreen")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsShakeToUndoEnabled, @"accessibility.shakeToUndo")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsAssistiveTouchRunning, @"accessibility.assistiveTouch")
LC_ACCESSIBILITY_HOOK(UIAccessibilityShouldDifferentiateWithoutColor, @"accessibility.differentiateWithoutColor")
LC_ACCESSIBILITY_HOOK(UIAccessibilityIsOnOffSwitchLabelsEnabled, @"accessibility.onOffLabels")

static void hook_nw_path_monitor_start(nw_path_monitor_t monitor) {
    if(blockDeviceInfoReads || (spoofProfileEnabled && spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.pathMonitor"))) return;
    nw_path_monitor_start(monitor);
}

static void hook_nw_browser_start(nw_browser_t browser) {
    if(blockDeviceInfoReads || (spoofProfileEnabled && spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.serviceDiscovery"))) return;
    nw_browser_start(browser);
}

static DNSServiceErrorType hook_DNSServiceBrowse(
    DNSServiceRef *sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    const char *regtype,
    const char *domain,
    DNSServiceBrowseReply callback,
    void *context
) {
    if(blockDeviceInfoReads || (spoofProfileEnabled && spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.serviceDiscovery"))) {
        if(sdRef) *sdRef = NULL;
        return kDNSServiceErr_PolicyDenied;
    }
    return DNSServiceBrowse(sdRef, flags, interfaceIndex, regtype, domain, callback, context);
}

static CFDictionaryRef hook_CFNetworkCopySystemProxySettings(void) {
    if(blockDeviceInfoReads || (spoofProfileEnabled && spoofNetworkEnvironmentCategoryEnabled && LCFeatureEnabled(@"network.proxy"))) {
        return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return CFNetworkCopySystemProxySettings();
}

// DYLD_INTERPOSE lets us hook C functions from a loaded dylib without needing litehook or fishhook.
// The linker replaces calls to the original function with our hook at load time.
#define DYLD_INTERPOSE(_hook, _orig) \
    __attribute__((used)) static struct { const void *hook; const void *orig; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&_hook, (const void *)&_orig }

// These interpose entries are conditionally effective — the hook functions
// check runtime spoof configuration and pass through when inactive.
DYLD_INTERPOSE(hook_sysctlbyname, sysctlbyname);
DYLD_INTERPOSE(hook_sysctl, sysctl);
DYLD_INTERPOSE(hook_uname, uname);
DYLD_INTERPOSE(hook_gethostname, gethostname);
DYLD_INTERPOSE(hook_getifaddrs, getifaddrs);
DYLD_INTERPOSE(hook_nw_path_monitor_start, nw_path_monitor_start);
DYLD_INTERPOSE(hook_nw_browser_start, nw_browser_start);
DYLD_INTERPOSE(hook_DNSServiceBrowse, DNSServiceBrowse);
DYLD_INTERPOSE(hook_CFNetworkCopySystemProxySettings, CFNetworkCopySystemProxySettings);
DYLD_INTERPOSE(hook_UIAccessibilityIsVoiceOverRunning, UIAccessibilityIsVoiceOverRunning);
DYLD_INTERPOSE(hook_UIAccessibilityIsMonoAudioEnabled, UIAccessibilityIsMonoAudioEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsClosedCaptioningEnabled, UIAccessibilityIsClosedCaptioningEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsInvertColorsEnabled, UIAccessibilityIsInvertColorsEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsGuidedAccessEnabled, UIAccessibilityIsGuidedAccessEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsBoldTextEnabled, UIAccessibilityIsBoldTextEnabled);
DYLD_INTERPOSE(hook_AXShowBordersEnabled, AXShowBordersEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsGrayscaleEnabled, UIAccessibilityIsGrayscaleEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsReduceTransparencyEnabled, UIAccessibilityIsReduceTransparencyEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsReduceMotionEnabled, UIAccessibilityIsReduceMotionEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsVideoAutoplayEnabled, UIAccessibilityIsVideoAutoplayEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityDarkerSystemColorsEnabled, UIAccessibilityDarkerSystemColorsEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsSwitchControlRunning, UIAccessibilityIsSwitchControlRunning);
DYLD_INTERPOSE(hook_UIAccessibilityIsSpeakSelectionEnabled, UIAccessibilityIsSpeakSelectionEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsSpeakScreenEnabled, UIAccessibilityIsSpeakScreenEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsShakeToUndoEnabled, UIAccessibilityIsShakeToUndoEnabled);
DYLD_INTERPOSE(hook_UIAccessibilityIsAssistiveTouchRunning, UIAccessibilityIsAssistiveTouchRunning);
DYLD_INTERPOSE(hook_UIAccessibilityShouldDifferentiateWithoutColor, UIAccessibilityShouldDifferentiateWithoutColor);
DYLD_INTERPOSE(hook_UIAccessibilityIsOnOffSwitchLabelsEnabled, UIAccessibilityIsOnOffSwitchLabelsEnabled);
DYLD_INTERPOSE(hook_MTLCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice);

// MARK: - HTTP Header Device Identity Rewriting
// Intercepts ALL outgoing HTTP headers to rewrite User-Agent strings containing
// real device info. This covers native iOS (NSURLSession), Flutter (Dart HTTP),
// React Native (fetch/axios), Expo, and all analytics SDKs (Firebase, PostHog,
// Adjust, AppsFlyer, etc.) since they ALL go through NSMutableURLRequest.

// Helper: Rewrite a User-Agent string, replacing real hw.machine and iOS version
// with spoofed values. Handles all known User-Agent formats:
//
// Format 1 (Custom app UAs):
//   ExampleApp/10.0 iOS/18.2 (Apple;iPhoneXX,X;;;;;1;2024)
//
// Format 2 (WebKit/Safari/WKWebView):
//   Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15
//
// Format 3 (NSURLSession default / CFNetwork):
//   AppName/1.0 CFNetwork/1568.200.51 Darwin/24.1.0
//
// Format 4 (Dart/Flutter):
//   Dart/3.5 (dart:io) MyApp/1.0 (iOS 18.0; iPhoneXX,X)
//
// Also catches any raw occurrence of the hw.machine identifier
// embedded anywhere in the string.

static NSRegularExpression *_uaHwMachineRegex = nil;
static NSRegularExpression *_uaIOSVersionSlashRegex = nil;
static NSRegularExpression *_uaIOSVersionCPURegex = nil;
static NSRegularExpression *_uaIOSVersionParenRegex = nil;
static NSRegularExpression *_uaDarwinVersionRegex = nil;
static NSRegularExpression *_uaCFNetworkVersionRegex = nil;

static void LCInitUserAgentRegexes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Match hw.machine identifiers: iPhoneXX,X  iPadXX,X  etc.
        _uaHwMachineRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(iPhone|iPad|iPod)\\d+,\\d+"
            options:0 error:nil];

        // Match "iOS/XX.X" or "iOS/XX.X.X" (common custom UA format)
        _uaIOSVersionSlashRegex = [NSRegularExpression
            regularExpressionWithPattern:@"iOS/[\\d.]+"
            options:0 error:nil];

        // Match "CPU iPhone OS 18_0 like Mac OS X" and iPad "CPU OS 18_0 like Mac OS X"
        _uaIOSVersionCPURegex = [NSRegularExpression
            regularExpressionWithPattern:@"CPU (iPhone )?OS [\\d_]+ like Mac OS X"
            options:0 error:nil];

        // Match "(iOS 18.0;" or "iOS 18.0)" (Dart/Flutter, generic)
        _uaIOSVersionParenRegex = [NSRegularExpression
            regularExpressionWithPattern:@"iOS [\\d.]+"
            options:0 error:nil];

        // Match CFNetwork's "Darwin/25.0.0" token
        _uaDarwinVersionRegex = [NSRegularExpression
            regularExpressionWithPattern:@"Darwin/[\\d.]+"
            options:0 error:nil];

        // Match CFNetwork's "CFNetwork/3826.500.131" token
        _uaCFNetworkVersionRegex = [NSRegularExpression
            regularExpressionWithPattern:@"CFNetwork/[\\d.]+"
            options:0 error:nil];
    });
}

static NSString* LCRewriteUserAgent(NSString *ua) {
    if(!ua || ua.length == 0) return ua;
    if(!blockDeviceInfoReads && !LCFeatureEnabled(@"networkHeaders.userAgent")) return ua;
    if(spoofCustomUserAgent.length > 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        return spoofCustomUserAgent;
    }

    NSMutableString *result = [ua mutableCopy];
    NSRange fullRange = NSMakeRange(0, result.length);
    BOOL isPadProfile = [LCPreferredWebKitPlatform() isEqualToString:@"iPad"];

    if(spoofHardwareModel.length > 0 && (blockDeviceInfoReads || spoofIdentityCategoryEnabled)) {
        [_uaHwMachineRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:spoofHardwareModel];
        fullRange = NSMakeRange(0, result.length);
    }

    if(spoofSystemVersion.length > 0 && (blockDeviceInfoReads || spoofSystemCategoryEnabled)) {
        [_uaIOSVersionSlashRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"iOS/%@", spoofSystemVersion]];
        fullRange = NSMakeRange(0, result.length);

        NSString *underscoreVersion = [spoofSystemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        NSString *cpuReplacement = isPadProfile
            ? [NSString stringWithFormat:@"CPU OS %@ like Mac OS X", underscoreVersion]
            : [NSString stringWithFormat:@"CPU iPhone OS %@ like Mac OS X", underscoreVersion];
        [_uaIOSVersionCPURegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:cpuReplacement];
        fullRange = NSMakeRange(0, result.length);

        [_uaIOSVersionParenRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"iOS %@", spoofSystemVersion]];
        fullRange = NSMakeRange(0, result.length);

        [_uaDarwinVersionRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"Darwin/%@", LCDerivedDarwinRelease()]];
        fullRange = NSMakeRange(0, result.length);

        [_uaCFNetworkVersionRegex replaceMatchesInString:result
            options:0 range:fullRange
            withTemplate:[NSString stringWithFormat:@"CFNetwork/%@", LCDerivedCFNetworkVersion()]];
    }

    if (![result isEqualToString:ua]) {
        LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
    }
    return result;
}

static BOOL LCIsHeaderField(NSString *field, NSString *target) {
    return [field caseInsensitiveCompare:target] == NSOrderedSame;
}

static NSString *LCDefaultSynthesizedCFNetworkUserAgent(void) {
    if (spoofCustomUserAgent.length > 0) {
        return spoofCustomUserAgent;
    }
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *execName = info[@"CFBundleName"] ?: NSProcessInfo.processInfo.processName ?: @"App";
    NSString *buildVer = info[@"CFBundleVersion"] ?: @"1";
    return [NSString stringWithFormat:@"%@/%@ CFNetwork/%@ Darwin/%@",
            execName, buildVer, LCDerivedCFNetworkVersion(), LCDerivedDarwinRelease()];
}

static NSDictionary* LCRewriteHeaderDict(NSDictionary *headers, BOOL injectMissingDefaults) {
    NSMutableDictionary *result = headers ? [headers mutableCopy] : [NSMutableDictionary dictionary];
    BOOL modified = NO;
    BOOL hasUserAgent = NO;
    BOOL hasAcceptLanguage = NO;

    NSString *acceptLang = (blockDeviceInfoReads || (spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale))
        ? (blockDeviceInfoReads ? @"en-US,en;q=0.9" : LCPreferredAcceptLanguageHeader())
        : nil;

    for(NSString *key in [result allKeys]) {
        if(LCIsHeaderField(key, @"User-Agent")) {
            hasUserAgent = YES;
            NSString *val = result[key];
            if([val isKindOfClass:NSString.class]) {
                NSString *rewritten = LCRewriteUserAgent(val);
                if(![rewritten isEqualToString:val]) {
                    result[key] = rewritten;
                    modified = YES;
                }
            }
        } else if(LCIsHeaderField(key, @"Accept-Language") && acceptLang.length > 0) {
            hasAcceptLanguage = YES;
            result[key] = acceptLang;
            modified = YES;
        }
    }

    if (injectMissingDefaults) {
        BOOL shouldSetUA = !hasUserAgent &&
            (spoofCustomUserAgent.length > 0 || blockDeviceInfoReads ||
             (spoofProfileEnabled && spoofNetworkHeadersCategoryEnabled && LCFeatureEnabled(@"networkHeaders.userAgent")));
        if (shouldSetUA) {
            result[@"User-Agent"] = LCDefaultSynthesizedCFNetworkUserAgent();
            modified = YES;
            LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        }
        if (!hasAcceptLanguage && acceptLang.length > 0) {
            result[@"Accept-Language"] = acceptLang;
            modified = YES;
            LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        }
    }

    return modified ? result : headers;
}

// --- NSMutableURLRequest hooks ---
// These intercept User-Agent and Accept-Language being set on outgoing HTTP requests.

@interface NSMutableURLRequest(LCDeviceSpoof)
@end

@implementation NSMutableURLRequest(LCDeviceSpoof)

- (void)hook_setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if(value && LCIsHeaderField(field, @"User-Agent")) {
        value = LCRewriteUserAgent(value);
    } else if(LCIsHeaderField(field, @"Accept-Language") &&
              (blockDeviceInfoReads || (spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale))) {
        NSString *spoofLang = blockDeviceInfoReads ? @"en-US,en;q=0.9" : LCPreferredAcceptLanguageHeader();
        if (spoofLang.length > 0) {
            value = spoofLang;
            LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        }
    }
    [self hook_setValue:value forHTTPHeaderField:field];
}

- (void)hook_addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if(value && LCIsHeaderField(field, @"User-Agent")) {
        value = LCRewriteUserAgent(value);
    } else if(LCIsHeaderField(field, @"Accept-Language") &&
              (blockDeviceInfoReads || (spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale))) {
        NSString *spoofLang = blockDeviceInfoReads ? @"en-US,en;q=0.9" : LCPreferredAcceptLanguageHeader();
        if (spoofLang.length > 0) {
            value = spoofLang;
            LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        }
    }
    [self hook_addValue:value forHTTPHeaderField:field];
}

- (void)hook_setAllHTTPHeaderFields:(NSDictionary *)headerFields {
    [self hook_setAllHTTPHeaderFields:LCRewriteHeaderDict(headerFields, NO)];
}

@end

// --- NSURLSessionConfiguration hooks ---
// Rewrites HTTPAdditionalHeaders and seeds default/ephemeral session configurations
// so CFNetwork does not fall back to real host Darwin version or Accept-Language headers.

@interface NSURLSessionConfiguration(LCDeviceSpoof)
@end

@implementation NSURLSessionConfiguration(LCDeviceSpoof)

- (void)hook_setHTTPAdditionalHeaders:(NSDictionary *)headers {
    [self hook_setHTTPAdditionalHeaders:LCRewriteHeaderDict(headers, YES)];
}

+ (NSURLSessionConfiguration *)hook_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self hook_defaultSessionConfiguration];
    NSDictionary *updated = LCRewriteHeaderDict(config.HTTPAdditionalHeaders, YES);
    if (updated && updated != config.HTTPAdditionalHeaders) {
        [config hook_setHTTPAdditionalHeaders:updated];
    }
    return config;
}

+ (NSURLSessionConfiguration *)hook_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self hook_ephemeralSessionConfiguration];
    NSDictionary *updated = LCRewriteHeaderDict(config.HTTPAdditionalHeaders, YES);
    if (updated && updated != config.HTTPAdditionalHeaders) {
        [config hook_setHTTPAdditionalHeaders:updated];
    }
    return config;
}

@end

// MARK: - Per-launch profile rotation

static id LCRandomArrayValue(NSArray *values) {
    if(values.count == 0) return nil;
    return values[arc4random_uniform((uint32_t)values.count)];
}

static NSArray<NSNumber *> *LCParseRotationOSMajorVersions(id value) {
    if(![value isKindOfClass:NSString.class]) return @[@18, @26, @27];
    NSMutableOrderedSet<NSNumber *> *versions = [NSMutableOrderedSet orderedSet];
    for(NSString *component in [(NSString *)value componentsSeparatedByString:@","]) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner = [NSScanner scannerWithString:trimmed];
        NSInteger major = 0;
        if(trimmed.length == 0 || ![scanner scanInteger:&major] || !scanner.isAtEnd || major < 1 || major > 99) {
            return @[@18, @26, @27];
        }
        [versions addObject:@(major)];
    }
    return versions.count > 0 ? versions.array : @[@18, @26, @27];
}

static void LCApplyHardwareSpecToGlobals(const LCDeviceHardwareSpec *spec) {
    if (!spec) return;
    spoofDeviceVariantId = @(spec->variantId);
    spoofHardwareModel = @(spec->hwMachine);
    spoofBoardModel = @(spec->hwModel);
    spoofDeviceModel = @(spec->deviceModel);
    spoofProcessorCount = spec->cpuCores;
    spoofPhysicalMemory = (unsigned long long)spec->physicalMemoryGB * 1024ULL * 1024ULL * 1024ULL;
    spoofGPUName = @(spec->gpuName);
    spoofGPUWorkingSetSize = (unsigned long long)spec->gpuWorkingSetGB * 1024ULL * 1024ULL * 1024ULL;
    spoofGraphicsSupportsRayTracing = spec->supportsRayTracing;
    spoofGraphicsSupportsAllFamilies = NO;
    spoofWebGLVendor = @"Apple Inc.";
    spoofWebGLRenderer = @"Apple GPU";
    spoofScreenWidth = spec->pixelWidth;
    spoofScreenHeight = spec->pixelHeight;
    spoofScreenPointWidth = spec->pointWidth;
    spoofScreenPointHeight = spec->pointHeight;
    spoofScreenScale = spec->scale;
    spoofScreenNativeScale = spec->nativeScale;
    spoofMaximumFramesPerSecond = spec->maxFPS;
    spoofHorizontalSizeClass = spec->horizontalSizeClass;
    spoofVerticalSizeClass = spec->verticalSizeClass;
    spoofSafeAreaInsets = UIEdgeInsetsMake(spec->safeAreaTop, 0, spec->safeAreaBottom, 0);
}

static void LCRotateSpoofProfile(void) {
    const LCDeviceHardwareSpec *selectedSpec = NULL;
    if(spoofIdentityCategoryEnabled) {
        idForVendorUUID = NSUUID.UUID;
        if(rotateUsesRealDeviceTemplates) {
            BOOL usePad = [spoofDeviceModel.lowercaseString containsString:@"ipad"] ||
                [spoofHardwareModel hasPrefix:@"iPad"];
            NSMutableArray<NSNumber *> *matchingIndices = [NSMutableArray array];
            size_t totalSpecs = LCDeviceHardwareSpecCount();
            for (size_t i = 0; i < totalSpecs; i++) {
                const LCDeviceHardwareSpec *candidate = LCDeviceHardwareSpecAt(i);
                if (!candidate) continue;
                BOOL candidateIsPad = (candidate->userInterfaceIdiom == UIUserInterfaceIdiomPad);
                if (candidateIsPad == usePad) {
                    [matchingIndices addObject:@(i)];
                }
            }
            if (matchingIndices.count > 0) {
                NSUInteger idx = [LCRandomArrayValue(matchingIndices) unsignedIntegerValue];
                selectedSpec = LCDeviceHardwareSpecAt(idx);
                if (selectedSpec) {
                    LCApplyHardwareSpecToGlobals(selectedSpec);
                }
            }
        }
    }

    if(spoofSystemCategoryEnabled) {
        if(spoofSystemVersion.length > 0 || rotateUsesRealDeviceTemplates) {
            NSInteger requestedMajor = [LCRandomArrayValue(rotateOSMajorVersions ?: @[@18, @26, @27]) integerValue];
            if (selectedSpec && requestedMajor < selectedSpec->minOSMajor) {
                requestedMajor = selectedSpec->minOSMajor;
            }
            NSInteger minor = arc4random_uniform(4);
            NSInteger patch = arc4random_uniform(3);
            spoofSystemVersion = patch == 0
                ? [NSString stringWithFormat:@"%ld.%ld", (long)requestedMajor, (long)minor]
                : [NSString stringWithFormat:@"%ld.%ld.%ld", (long)requestedMajor, (long)minor, (long)patch];
            spoofOperatingSystemVersionValid = LCParseSystemVersion(spoofSystemVersion, &spoofOperatingSystemVersion);
            if(rotateUsesRealDeviceTemplates) {
                spoofKernelVersion = [NSString stringWithFormat:@"Darwin Kernel Version %@", LCDerivedDarwinRelease()];
            }
        }
        if(spoofBootTime > 0) spoofBootTime = time(NULL) - (time_t)(3600 + arc4random_uniform(1209600));
        if(!rotateUsesRealDeviceTemplates) {
            if(spoofProcessorCount > 0) spoofProcessorCount = 2 + arc4random_uniform(11);
            if(spoofPhysicalMemory > 0) spoofPhysicalMemory = (2 + arc4random_uniform(15)) * 1024ULL * 1024ULL * 1024ULL;
        }
    }

    if(spoofDisplayCategoryEnabled) {
        if(!rotateUsesRealDeviceTemplates && spoofScreenWidth > 0 && spoofScreenHeight > 0) {
            CGFloat aspectRatio = spoofScreenHeight / spoofScreenWidth;
            spoofScreenWidth = 900 + arc4random_uniform(1201);
            spoofScreenHeight = round(spoofScreenWidth * aspectRatio);
        }
        if(!rotateUsesRealDeviceTemplates && spoofScreenScale > 0) spoofScreenScale = (CGFloat)(200 + arc4random_uniform(101)) / 100.0;
        if(!rotateUsesRealDeviceTemplates && spoofScreenNativeScale > 0) spoofScreenNativeScale = spoofScreenScale;
        if(!rotateUsesRealDeviceTemplates && spoofMaximumFramesPerSecond > 0) spoofMaximumFramesPerSecond = arc4random_uniform(2) == 0 ? 60 : 120;
        if(spoofScreenBrightness >= 0) spoofScreenBrightness = (CGFloat)arc4random_uniform(101) / 100.0;
        spoofUserInterfaceStyle = arc4random_uniform(2) == 0 ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
        spoofDisplayGamut = arc4random_uniform(4) == 0 ? UIDisplayGamutSRGB : UIDisplayGamutP3;
        NSArray<NSString *> *contentSizes = @[
            UIContentSizeCategoryMedium, UIContentSizeCategoryLarge, UIContentSizeCategoryExtraLarge
        ];
        spoofPreferredContentSizeCategory = LCRandomArrayValue(contentSizes);
    }

    if(spoofAccessibilityCategoryEnabled) {
        spoofAccessibilityContrast = arc4random_uniform(6) == 0 ? UIAccessibilityContrastHigh : UIAccessibilityContrastNormal;
    }

    if(spoofStorageCategoryEnabled && spoofStorageTotalCapacity > 0) {
        long long minimumFree = MIN(spoofStorageTotalCapacity, 8LL * 1024LL * 1024LL * 1024LL);
        long long variableRange = MAX(1LL, spoofStorageTotalCapacity - minimumFree);
        double fraction = (double)arc4random_uniform(10001) / 10000.0;
        spoofStorageAvailableCapacity = minimumFree + (long long)(fraction * (double)variableRange);
    }
    if(spoofAudioCategoryEnabled) {
        if(LCFeatureEnabled(@"audio.outputVolume")) spoofAudioOutputVolume = (float)arc4random_uniform(101) / 100.0f;
        if(LCFeatureEnabled(@"audio.sampleRate")) {
            NSArray<NSNumber *> *sampleRates = @[@44100, @48000, @96000];
            spoofAudioSampleRate = [LCRandomArrayValue(sampleRates) doubleValue];
        }
        if(LCFeatureEnabled(@"audio.outputLatency")) spoofAudioOutputLatency = (5 + arc4random_uniform(26)) / 1000.0;
        if(LCFeatureEnabled(@"audio.inputLatency")) spoofAudioInputLatency = (5 + arc4random_uniform(26)) / 1000.0;
        if(LCFeatureEnabled(@"audio.otherPlaying")) spoofAudioOtherPlaying = arc4random_uniform(2) == 1;
        if(LCFeatureEnabled(@"audio.channels")) {
            spoofAudioOutputChannels = 1 + arc4random_uniform(2);
            spoofAudioInputChannels = arc4random_uniform(3);
        }
    }
    if(spoofGraphicsCategoryEnabled && !selectedSpec) {
        if(LCFeatureEnabled(@"graphics.workingSet")) spoofGPUWorkingSetSize = (2 + arc4random_uniform(7)) * 1024ULL * 1024ULL * 1024ULL;
        if(LCFeatureEnabled(@"graphics.rayTracing")) spoofGraphicsSupportsRayTracing = arc4random_uniform(2) == 1;
        if(LCFeatureEnabled(@"graphics.allFamilies")) spoofGraphicsSupportsAllFamilies = arc4random_uniform(2) == 1;
    }
    if(spoofWebViewCategoryEnabled && LCFeatureEnabled(@"web.screen")) {
        spoofWebColorDepth = arc4random_uniform(4) == 0 ? 30 : 24;
    }
    if(spoofWebViewCategoryEnabled && LCFeatureEnabled(@"web.canvas")) {
        spoofWebCanvasSeed = arc4random() | 1u;
    }

    if(spoofLocaleCategoryEnabled) {
        if(spoofLocale) {
            NSArray<NSString *> *localeIdentifiers = [NSLocale availableLocaleIdentifiers];
            NSString *localeIdentifier = nil;
            for(NSUInteger attempt = 0; attempt < 32 && localeIdentifier.length == 0; attempt++) {
                NSString *candidate = LCRandomArrayValue(localeIdentifiers);
                NSLocale *candidateLocale = [[NSLocale alloc] initWithLocaleIdentifier:candidate];
                NSString *countryCode = [candidateLocale objectForKey:NSLocaleCountryCode];
                if(countryCode.length > 0) localeIdentifier = candidate;
            }
            if(localeIdentifier.length > 0) spoofLocale = [[NSLocale alloc] initWithLocaleIdentifier:localeIdentifier];
        }
        NSString *timeZoneName = spoofTimeZone ? LCRandomArrayValue([NSTimeZone knownTimeZoneNames]) : nil;
        if(spoofTimeZone && timeZoneName.length > 0) {
            spoofTimeZone = [NSTimeZone timeZoneWithName:timeZoneName];
            if(spoofTimeZone) [NSTimeZone setDefaultTimeZone:spoofTimeZone];
        }
    }

    if(spoofBatteryCategoryEnabled) {
        spoofBatteryLevel = (float)(15 + arc4random_uniform(86)) / 100.0f;
        spoofBatteryState = 1 + arc4random_uniform(3);
        spoofLowPowerModeEnabled = spoofBatteryLevel < 0.25f;
        spoofLowPowerModeEnabledSet = YES;
        if(spoofThermalState >= 0) spoofThermalState = arc4random_uniform(5) == 0
            ? NSProcessInfoThermalStateFair : NSProcessInfoThermalStateNominal;
    }

    if(spoofTelephonyCategoryEnabled) {
        if(spoofSubscriberIdentifier.length > 0) spoofSubscriberIdentifier = NSUUID.UUID.UUIDString;
        if(spoofSubscriberCarrierToken) {
            uint8_t tokenBytes[24];
            arc4random_buf(tokenBytes, sizeof(tokenBytes));
            spoofSubscriberCarrierToken = [NSData dataWithBytes:tokenBytes length:sizeof(tokenBytes)];
        }
        if(spoofSubscriberSIMInsertedEnabled) spoofSubscriberSIMInserted = arc4random_uniform(2) == 1;
    }
}

BOOL launchURLProcessed = NO;

static CFAbsoluteTime LCProcessStartWallTime(void) {
    static CFAbsoluteTime wallTimeAtLaunch = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSTimeInterval currentUptime = NSProcessInfo.processInfo.systemUptime;
        wallTimeAtLaunch = (CFAbsoluteTime)time(NULL) - currentUptime;
    });
    return wallTimeAtLaunch;
}

static void LCInstallWebAuthSessionHooks(void);

__attribute__((constructor))
static void UIKitGuestHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
    if(!NSUserDefaults.lcGuestAppId) return;

    struct utsname rawUts;
    int (*real_uname)(struct utsname *) = (int (*)(struct utsname *))dlsym(RTLD_NEXT, "uname");
    if ((real_uname ? real_uname(&rawUts) : uname(&rawUts)) == 0) {
        sRealHostMachine = @(rawUts.machine);
    }

    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    if (NSUserDefaults.isLiveProcess) {
        swizzle(UIApplication.class, @selector(sendEvent:), @selector(hook_lc_sendEvent:));
    }
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
//            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(supportedInterfaceOrientations), @selector(hook_supportedInterfaceOrientations));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }

    }
    NSDictionary* guestContainerInfo = [NSUserDefaults guestContainerInfo];
    strictTestMode = [guestContainerInfo[@"strictTestMode"] boolValue];
    isolateWebViewData = strictTestMode || [guestContainerInfo[@"isolateWebViewData"] boolValue];
    blockDeviceInfoReads = strictTestMode || [guestContainerInfo[@"blockDeviceInfoReads"] boolValue];

    if (isolateWebViewData) {
        LCSwizzleClassIfPresent(WKWebsiteDataStore.class, @selector(defaultDataStore), @selector(hook_defaultDataStore));
    }

    if(strictTestMode) {
        strictPrivatePasteboard = [UIPasteboard pasteboardWithUniqueName];
        LCSwizzleClassIfPresent(UIPasteboard.class, @selector(generalPasteboard), @selector(hook_generalPasteboard));
        LCSwizzleClassIfPresent(UIPasteboard.class, @selector(pasteboardWithName:create:), @selector(hook_pasteboardWithName:create:));
    }
    if(strictTestMode) {
        LCSwizzleIfPresent(NSURLSessionTask.class, @selector(resume), @selector(hook_resume));
        Class hotspotNetworkClass = NSClassFromString(@"NEHotspotNetwork");
        LCSwizzleClassIfPresentWithSourceClass(
            hotspotNetworkClass,
            LCNetworkExtensionStrictHookProvider.class,
            @selector(fetchCurrentWithCompletionHandler:),
            @selector(hook_fetchCurrentWithCompletionHandler:)
        );
    }

    BOOL shouldEnableSpoofProfile = [guestContainerInfo[@"spoofProfileEnabled"] boolValue];
    if ((shouldEnableSpoofProfile || blockDeviceInfoReads) && !NSUserDefaults.isSideStore) {
        const char *homeEnv = getenv("HOME");
        NSString *homePath = homeEnv ? @(homeEnv) : NSHomeDirectory();
        if (homePath.length > 0) {
            sTelemetryFilePath = [homePath stringByAppendingPathComponent:@".lc_profile_telemetry.plist"];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification * _Nonnull note) {
                LCFlushProfileTelemetryToDisk(YES);
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification * _Nonnull note) {
                LCFlushProfileTelemetryToDisk(YES);
            }];
        }
    }
    NSDictionary *featureOverrides = guestContainerInfo[@"spoofFeatureOverrides"];
    if([featureOverrides isKindOfClass:NSDictionary.class]) spoofFeatureOverrides = featureOverrides;
    spoofIdentityCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofIdentityCategoryEnabled", YES);
    spoofSystemCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofSystemCategoryEnabled", YES);
    spoofDisplayCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofDisplayCategoryEnabled", YES);
    spoofLocaleCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofLocaleCategoryEnabled", YES);
    spoofBatteryCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofBatteryCategoryEnabled", YES);
    spoofTelephonyCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofTelephonyCategoryEnabled", YES);
    spoofNetworkHeadersCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofNetworkHeadersCategoryEnabled", YES);
    spoofAccessibilityCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofAccessibilityCategoryEnabled", YES);
    spoofStorageCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofStorageCategoryEnabled", YES);
    spoofNetworkEnvironmentCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofNetworkEnvironmentCategoryEnabled", YES);
    spoofAudioCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofAudioCategoryEnabled", YES);
    spoofGraphicsCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofGraphicsCategoryEnabled", YES);
    spoofWebViewCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofWebViewCategoryEnabled", YES);
    spoofAppPrivacyCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofAppPrivacyCategoryEnabled", YES);
    spoofSensorsAndUserDataCategoryEnabled = LCBoolWithDefault(guestContainerInfo, @"spoofSensorsAndUserDataCategoryEnabled", NO);
    if(shouldEnableSpoofProfile) {
        spoofProfileEnabled = YES;
    }
    if(shouldEnableSpoofProfile && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.pasteboard") && !strictTestMode) {
        strictPrivatePasteboard = [UIPasteboard pasteboardWithUniqueName];
        LCSwizzleClassIfPresent(UIPasteboard.class, @selector(generalPasteboard), @selector(hook_generalPasteboard));
        LCSwizzleClassIfPresent(UIPasteboard.class, @selector(pasteboardWithName:create:), @selector(hook_pasteboardWithName:create:));
    }
    rotateOSMajorVersions = LCParseRotationOSMajorVersions(guestContainerInfo[@"rotateOSMajorVersions"]);
    rotateUsesRealDeviceTemplates = LCBoolWithDefault(guestContainerInfo, @"rotateUsesRealDeviceTemplates", YES);
    BOOL rotateSpoofProfileOnLaunch = [guestContainerInfo[@"rotateSpoofProfileOnLaunch"] boolValue];
    BOOL shouldSpoofIdentifierForVendor = shouldEnableSpoofProfile && spoofIdentityCategoryEnabled &&
        [guestContainerInfo[@"spoofIdentifierForVendor"] boolValue];
    if(shouldSpoofIdentifierForVendor) {
        NSString* idForVendorStr = guestContainerInfo[@"spoofedIdentifierForVendor"];
        if([idForVendorStr isKindOfClass:NSString.class]) {
            idForVendorUUID = [[NSUUID alloc] initWithUUIDString:idForVendorStr];
        }
    }
    if(blockDeviceInfoReads || (shouldSpoofIdentifierForVendor && (idForVendorUUID != nil || rotateSpoofProfileOnLaunch))) {
        swizzle(UIDevice.class, @selector(identifierForVendor), @selector(hook_identifierForVendor));
        Class workspaceClass = objc_lookUpClass("LSApplicationWorkspace");
        LCSwizzleIfPresentWithSourceClass(workspaceClass, LCLSApplicationWorkspaceHookProvider.class,
            @selector(deviceIdentifierForVendor), @selector(hook_deviceIdentifierForVendor));
    }

    if(shouldEnableSpoofProfile) {
        NSString *deviceVariantId = guestContainerInfo[@"spoofDeviceVariantId"];
        if([deviceVariantId isKindOfClass:NSString.class] && deviceVariantId.length > 0) {
            spoofDeviceVariantId = deviceVariantId;
        }
        NSString *deviceName = guestContainerInfo[@"spoofDeviceName"];
        NSString *deviceModel = guestContainerInfo[@"spoofDeviceModel"];
        NSString *systemName = guestContainerInfo[@"spoofSystemName"];
        NSString *systemVersion = guestContainerInfo[@"spoofSystemVersion"];
        NSString *localeIdentifier = guestContainerInfo[@"spoofLocaleIdentifier"];
        NSString *timeZoneIdentifier = guestContainerInfo[@"spoofTimeZoneIdentifier"];
        NSNumber *batteryLevelNumber = guestContainerInfo[@"spoofBatteryLevel"];
        NSNumber *batteryStateNumber = guestContainerInfo[@"spoofBatteryState"];
        NSNumber *lowPowerModeNumber = guestContainerInfo[@"spoofLowPowerModeEnabled"];
        NSString *radioAccessTechnology = guestContainerInfo[@"spoofRadioAccessTechnology"];
        NSString *subscriberIdentifier = guestContainerInfo[@"spoofSubscriberIdentifier"];
        NSString *subscriberCarrierTokenBase64 = guestContainerInfo[@"spoofSubscriberCarrierTokenBase64"];
        NSNumber *subscriberSIMInsertedEnabledNumber = guestContainerInfo[@"spoofSubscriberSIMInsertedEnabled"];
        NSNumber *subscriberSIMInsertedNumber = guestContainerInfo[@"spoofSubscriberSIMInserted"];
        NSString *hostName = guestContainerInfo[@"spoofHostName"];
        NSString *boardModel = guestContainerInfo[@"spoofBoardModel"];
        NSNumber *processorCount = guestContainerInfo[@"spoofProcessorCount"];
        NSNumber *physicalMemory = guestContainerInfo[@"spoofPhysicalMemory"];
        NSNumber *thermalState = guestContainerInfo[@"spoofThermalState"];
        NSNumber *screenWidth = guestContainerInfo[@"spoofScreenWidth"];
        NSNumber *screenHeight = guestContainerInfo[@"spoofScreenHeight"];
        NSNumber *screenScale = guestContainerInfo[@"spoofScreenScale"];
        NSNumber *screenNativeScale = guestContainerInfo[@"spoofScreenNativeScale"];
        NSNumber *maximumFramesPerSecond = guestContainerInfo[@"spoofMaximumFramesPerSecond"];
        NSNumber *screenBrightness = guestContainerInfo[@"spoofScreenBrightness"];
        NSNumber *userInterfaceStyle = guestContainerInfo[@"spoofUserInterfaceStyle"];
        NSNumber *accessibilityContrast = guestContainerInfo[@"spoofAccessibilityContrast"];
        NSNumber *displayGamut = guestContainerInfo[@"spoofDisplayGamut"];
        NSNumber *horizontalSizeClass = guestContainerInfo[@"spoofHorizontalSizeClass"];
        NSNumber *verticalSizeClass = guestContainerInfo[@"spoofVerticalSizeClass"];
        NSString *preferredContentSizeCategory = guestContainerInfo[@"spoofPreferredContentSizeCategory"];
        NSNumber *safeAreaTop = guestContainerInfo[@"spoofSafeAreaTop"];
        NSNumber *safeAreaLeft = guestContainerInfo[@"spoofSafeAreaLeft"];
        NSNumber *safeAreaBottom = guestContainerInfo[@"spoofSafeAreaBottom"];
        NSNumber *safeAreaRight = guestContainerInfo[@"spoofSafeAreaRight"];
        NSString *kernelVersion = guestContainerInfo[@"spoofKernelVersion"];
        NSNumber *bootTime = guestContainerInfo[@"spoofBootTime"];
        NSNumber *cpuType = guestContainerInfo[@"spoofCPUType"];
        NSNumber *cpuSubtype = guestContainerInfo[@"spoofCPUSubtype"];
        NSString *hardwareModel = guestContainerInfo[@"spoofHardwareModel"];
        NSNumber *storageTotalCapacity = guestContainerInfo[@"spoofStorageTotalCapacity"];
        NSNumber *storageAvailableCapacity = guestContainerInfo[@"spoofStorageAvailableCapacity"];
        NSString *gpuName = guestContainerInfo[@"spoofGPUName"];
        NSNumber *audioOutputVolume = guestContainerInfo[@"spoofAudioOutputVolume"];
        NSNumber *audioSampleRate = guestContainerInfo[@"spoofAudioSampleRate"];
        NSNumber *audioOutputLatency = guestContainerInfo[@"spoofAudioOutputLatency"];
        NSNumber *audioInputLatency = guestContainerInfo[@"spoofAudioInputLatency"];
        NSNumber *audioOtherPlaying = guestContainerInfo[@"spoofAudioOtherPlaying"];
        NSNumber *audioOutputChannels = guestContainerInfo[@"spoofAudioOutputChannels"];
        NSNumber *audioInputChannels = guestContainerInfo[@"spoofAudioInputChannels"];
        NSNumber *gpuWorkingSetSize = guestContainerInfo[@"spoofGPUWorkingSetSize"];
        NSNumber *graphicsSupportsRayTracing = guestContainerInfo[@"spoofGraphicsSupportsRayTracing"];
        NSNumber *graphicsSupportsAllFamilies = guestContainerInfo[@"spoofGraphicsSupportsAllFamilies"];
        NSString *storageVolumeName = guestContainerInfo[@"spoofStorageVolumeName"];
        NSString *storageVolumeUUID = guestContainerInfo[@"spoofStorageVolumeUUID"];
        NSNumber *storageFileCreationTime = guestContainerInfo[@"spoofStorageFileCreationTime"];
        NSNumber *storageVolumeCreationTime = guestContainerInfo[@"spoofStorageVolumeCreationTime"];
        NSString *customUserAgent = guestContainerInfo[@"spoofCustomUserAgent"];
        NSString *webGLVendor = guestContainerInfo[@"spoofWebGLVendor"];
        NSString *webGLRenderer = guestContainerInfo[@"spoofWebGLRenderer"];
        id webCanvasSeed = guestContainerInfo[@"spoofWebCanvasSeed"];
        NSNumber *webColorDepth = guestContainerInfo[@"spoofWebColorDepth"];

        if([deviceName isKindOfClass:NSString.class] && deviceName.length > 0) {
            spoofDeviceName = deviceName;
        }
        if([deviceModel isKindOfClass:NSString.class] && deviceModel.length > 0) {
            spoofDeviceModel = deviceModel;
        }
        if([systemName isKindOfClass:NSString.class] && systemName.length > 0) {
            spoofSystemName = systemName;
        }
        if([systemVersion isKindOfClass:NSString.class] && systemVersion.length > 0) {
            spoofSystemVersion = systemVersion;
            spoofOperatingSystemVersionValid = LCParseSystemVersion(systemVersion, &spoofOperatingSystemVersion);
        }

        if([localeIdentifier isKindOfClass:NSString.class] && localeIdentifier.length > 0) {
            NSLocale *candidateLocale = [[NSLocale alloc] initWithLocaleIdentifier:localeIdentifier];
            if(candidateLocale.localeIdentifier.length > 0) {
                spoofLocale = candidateLocale;
            }
        }

        if([timeZoneIdentifier isKindOfClass:NSString.class] && timeZoneIdentifier.length > 0) {
            NSTimeZone *candidateTimeZone = [NSTimeZone timeZoneWithName:timeZoneIdentifier];
            if(candidateTimeZone) {
                spoofTimeZone = candidateTimeZone;
            }
        }
        if([batteryLevelNumber isKindOfClass:NSNumber.class]) {
            float level = batteryLevelNumber.floatValue;
            if(level >= 0.0f && level <= 1.0f) {
                spoofBatteryLevel = level;
            }
        }
        if([batteryStateNumber isKindOfClass:NSNumber.class]) {
            NSInteger value = batteryStateNumber.integerValue;
            if(value >= UIDeviceBatteryStateUnknown && value <= UIDeviceBatteryStateFull) {
                spoofBatteryState = value;
            }
        }
        if([lowPowerModeNumber isKindOfClass:NSNumber.class]) {
            spoofLowPowerModeEnabled = lowPowerModeNumber.boolValue;
            spoofLowPowerModeEnabledSet = YES;
        }
        if([radioAccessTechnology isKindOfClass:NSString.class] && radioAccessTechnology.length > 0) {
            spoofRadioAccessTechnology = radioAccessTechnology;
        }
        if([subscriberIdentifier isKindOfClass:NSString.class] && subscriberIdentifier.length > 0) {
            spoofSubscriberIdentifier = subscriberIdentifier;
        }
        if([subscriberCarrierTokenBase64 isKindOfClass:NSString.class] && subscriberCarrierTokenBase64.length > 0) {
            NSData *decodedToken = [[NSData alloc] initWithBase64EncodedString:subscriberCarrierTokenBase64 options:0];
            if(decodedToken.length > 0) {
                spoofSubscriberCarrierToken = decodedToken;
            }
        }
        if([subscriberSIMInsertedEnabledNumber isKindOfClass:NSNumber.class]) {
            spoofSubscriberSIMInsertedEnabled = subscriberSIMInsertedEnabledNumber.boolValue;
        }
        if([subscriberSIMInsertedNumber isKindOfClass:NSNumber.class]) {
            spoofSubscriberSIMInserted = subscriberSIMInsertedNumber.boolValue;
        }
        if([hostName isKindOfClass:NSString.class] && hostName.length > 0) {
            spoofHostName = hostName;
        }
        if([boardModel isKindOfClass:NSString.class] && boardModel.length > 0) {
            spoofBoardModel = boardModel;
        }
        if([processorCount isKindOfClass:NSNumber.class] && processorCount.integerValue > 0) {
            spoofProcessorCount = processorCount.integerValue;
        }
        if([physicalMemory isKindOfClass:NSNumber.class] && physicalMemory.unsignedLongLongValue > 0) {
            spoofPhysicalMemory = physicalMemory.unsignedLongLongValue;
        }
        if([thermalState isKindOfClass:NSNumber.class] && thermalState.integerValue >= 0 && thermalState.integerValue <= 3) {
            spoofThermalState = thermalState.integerValue;
        }
        if([screenWidth isKindOfClass:NSNumber.class] && screenWidth.doubleValue > 0) spoofScreenWidth = screenWidth.doubleValue;
        if([screenHeight isKindOfClass:NSNumber.class] && screenHeight.doubleValue > 0) spoofScreenHeight = screenHeight.doubleValue;
        if([screenScale isKindOfClass:NSNumber.class] && screenScale.doubleValue > 0) spoofScreenScale = screenScale.doubleValue;
        if([screenNativeScale isKindOfClass:NSNumber.class] && screenNativeScale.doubleValue > 0) spoofScreenNativeScale = screenNativeScale.doubleValue;
        if([maximumFramesPerSecond isKindOfClass:NSNumber.class] && maximumFramesPerSecond.integerValue > 0) {
            spoofMaximumFramesPerSecond = maximumFramesPerSecond.integerValue;
        }
        if([screenBrightness isKindOfClass:NSNumber.class] && screenBrightness.doubleValue >= 0 && screenBrightness.doubleValue <= 1) {
            spoofScreenBrightness = screenBrightness.doubleValue;
        }
        if([userInterfaceStyle isKindOfClass:NSNumber.class] && userInterfaceStyle.integerValue >= UIUserInterfaceStyleUnspecified && userInterfaceStyle.integerValue <= UIUserInterfaceStyleDark) {
            spoofUserInterfaceStyle = userInterfaceStyle.integerValue;
        }
        if([accessibilityContrast isKindOfClass:NSNumber.class] && accessibilityContrast.integerValue >= UIAccessibilityContrastNormal && accessibilityContrast.integerValue <= UIAccessibilityContrastHigh) {
            spoofAccessibilityContrast = accessibilityContrast.integerValue;
        }
        if([displayGamut isKindOfClass:NSNumber.class] && displayGamut.integerValue >= UIDisplayGamutUnspecified && displayGamut.integerValue <= UIDisplayGamutP3) {
            spoofDisplayGamut = displayGamut.integerValue;
        }
        if([horizontalSizeClass isKindOfClass:NSNumber.class] && horizontalSizeClass.integerValue >= UIUserInterfaceSizeClassUnspecified && horizontalSizeClass.integerValue <= UIUserInterfaceSizeClassRegular) {
            spoofHorizontalSizeClass = horizontalSizeClass.integerValue;
        }
        if([verticalSizeClass isKindOfClass:NSNumber.class] && verticalSizeClass.integerValue >= UIUserInterfaceSizeClassUnspecified && verticalSizeClass.integerValue <= UIUserInterfaceSizeClassRegular) {
            spoofVerticalSizeClass = verticalSizeClass.integerValue;
        }
        if([preferredContentSizeCategory isKindOfClass:NSString.class] && preferredContentSizeCategory.length > 0) {
            spoofPreferredContentSizeCategory = preferredContentSizeCategory;
        }
        if([safeAreaTop isKindOfClass:NSNumber.class]) spoofSafeAreaInsets.top = MAX(0, safeAreaTop.doubleValue);
        if([safeAreaLeft isKindOfClass:NSNumber.class]) spoofSafeAreaInsets.left = MAX(0, safeAreaLeft.doubleValue);
        if([safeAreaBottom isKindOfClass:NSNumber.class]) spoofSafeAreaInsets.bottom = MAX(0, safeAreaBottom.doubleValue);
        if([safeAreaRight isKindOfClass:NSNumber.class]) spoofSafeAreaInsets.right = MAX(0, safeAreaRight.doubleValue);
        if([kernelVersion isKindOfClass:NSString.class] && kernelVersion.length > 0) spoofKernelVersion = kernelVersion;
        if([bootTime isKindOfClass:NSNumber.class] && bootTime.longLongValue > 0) spoofBootTime = (time_t)bootTime.longLongValue;
        if([cpuType isKindOfClass:NSNumber.class] && cpuType.intValue > 0) spoofCPUType = cpuType.intValue;
        if([cpuSubtype isKindOfClass:NSNumber.class] && cpuSubtype.intValue >= 0) spoofCPUSubtype = cpuSubtype.intValue;
        if([hardwareModel isKindOfClass:NSString.class] && hardwareModel.length > 0) spoofHardwareModel = hardwareModel;
        if([storageTotalCapacity isKindOfClass:NSNumber.class] && storageTotalCapacity.longLongValue > 0) {
            spoofStorageTotalCapacity = storageTotalCapacity.longLongValue;
        }
        if([storageAvailableCapacity isKindOfClass:NSNumber.class] && storageAvailableCapacity.longLongValue >= 0) {
            spoofStorageAvailableCapacity = MIN(spoofStorageTotalCapacity, storageAvailableCapacity.longLongValue);
        }
        if([gpuName isKindOfClass:NSString.class]) spoofGPUName = gpuName;
        if([audioOutputVolume isKindOfClass:NSNumber.class]) {
            spoofAudioOutputVolume = MIN(1, MAX(0, audioOutputVolume.floatValue));
        }
        if([audioSampleRate isKindOfClass:NSNumber.class] && audioSampleRate.doubleValue > 0) spoofAudioSampleRate = audioSampleRate.doubleValue;
        if([audioOutputLatency isKindOfClass:NSNumber.class] && audioOutputLatency.doubleValue >= 0) spoofAudioOutputLatency = audioOutputLatency.doubleValue;
        if([audioInputLatency isKindOfClass:NSNumber.class] && audioInputLatency.doubleValue >= 0) spoofAudioInputLatency = audioInputLatency.doubleValue;
        if([audioOtherPlaying isKindOfClass:NSNumber.class]) spoofAudioOtherPlaying = audioOtherPlaying.boolValue;
        if([audioOutputChannels isKindOfClass:NSNumber.class] && audioOutputChannels.integerValue >= 0) spoofAudioOutputChannels = audioOutputChannels.integerValue;
        if([audioInputChannels isKindOfClass:NSNumber.class] && audioInputChannels.integerValue >= 0) spoofAudioInputChannels = audioInputChannels.integerValue;
        if([gpuWorkingSetSize isKindOfClass:NSNumber.class] && gpuWorkingSetSize.unsignedLongLongValue > 0) spoofGPUWorkingSetSize = gpuWorkingSetSize.unsignedLongLongValue;
        if([graphicsSupportsRayTracing isKindOfClass:NSNumber.class]) spoofGraphicsSupportsRayTracing = graphicsSupportsRayTracing.boolValue;
        if([graphicsSupportsAllFamilies isKindOfClass:NSNumber.class]) spoofGraphicsSupportsAllFamilies = graphicsSupportsAllFamilies.boolValue;
        if([storageVolumeName isKindOfClass:NSString.class]) spoofStorageVolumeName = storageVolumeName;
        if([storageVolumeUUID isKindOfClass:NSString.class]) spoofStorageVolumeUUID = storageVolumeUUID;
        if([storageFileCreationTime isKindOfClass:NSNumber.class]) spoofStorageFileCreationTime = storageFileCreationTime.longLongValue;
        if([storageVolumeCreationTime isKindOfClass:NSNumber.class]) spoofStorageVolumeCreationTime = storageVolumeCreationTime.longLongValue;
        if([customUserAgent isKindOfClass:NSString.class]) spoofCustomUserAgent = customUserAgent;
        if([webGLVendor isKindOfClass:NSString.class]) spoofWebGLVendor = webGLVendor;
        if([webGLRenderer isKindOfClass:NSString.class]) spoofWebGLRenderer = webGLRenderer;
        uint32_t parsedSeed = LCParseWebCanvasSeedValue(webCanvasSeed);
        if(parsedSeed != 0) spoofWebCanvasSeed = parsedSeed;
        if([webColorDepth isKindOfClass:NSNumber.class] && webColorDepth.integerValue > 0) spoofWebColorDepth = webColorDepth.integerValue;

        const LCDeviceHardwareSpec *matchedSpec = spoofDeviceVariantId.length > 0
            ? LCDeviceHardwareSpecFindByVariant(spoofDeviceVariantId.UTF8String)
            : LCDeviceHardwareSpecFindByMachine(spoofHardwareModel.UTF8String);
        BOOL pixelsMatchCatalog = (matchedSpec != NULL) &&
            (spoofScreenWidth <= 0 || spoofScreenHeight <= 0 ||
             (fabs(spoofScreenWidth - matchedSpec->pixelWidth) < 1.0 &&
              fabs(spoofScreenHeight - matchedSpec->pixelHeight) < 1.0));
        if(pixelsMatchCatalog) {
            spoofScreenPointWidth = matchedSpec->pointWidth;
            spoofScreenPointHeight = matchedSpec->pointHeight;
        } else if(spoofScreenWidth > 0 && spoofScreenHeight > 0) {
            CGFloat divisor = spoofScreenScale > 0 ? spoofScreenScale : 3.0;
            spoofScreenPointWidth = round(spoofScreenWidth / divisor);
            spoofScreenPointHeight = round(spoofScreenHeight / divisor);
        }
    }

    if(shouldEnableSpoofProfile && rotateSpoofProfileOnLaunch) {
        LCRotateSpoofProfile();
    }

    if(shouldEnableSpoofProfile && spoofLocaleCategoryEnabled && spoofTimeZone && !blockDeviceInfoReads) {
        [NSTimeZone setDefaultTimeZone:spoofTimeZone];
        setenv("TZ", spoofTimeZone.name.UTF8String, 1);
        tzset();
    } else if(blockDeviceInfoReads) {
        setenv("TZ", "GMT", 1);
        tzset();
    }

    if(!NSUserDefaults.isSideStore) {
        LCInstallWebAuthSessionHooks();
    }

    if(shouldEnableSpoofProfile && spoofAccessibilityCategoryEnabled) {
        LCSwizzleIfPresent(UITraitCollection.class, @selector(accessibilityContrast), @selector(hook_accessibilityContrast));
    }
    if(shouldEnableSpoofProfile && spoofLocaleCategoryEnabled) {
        LCInstallLocalePrivacyProfile();
    }
    if(shouldEnableSpoofProfile && spoofAudioCategoryEnabled) {
        LCInstallAudioPrivacyProfile();
    }
    if(blockDeviceInfoReads || (shouldEnableSpoofProfile && spoofGraphicsCategoryEnabled)) {
        LCInstallGraphicsPrivacyProfile();
    }
    if(shouldEnableSpoofProfile && spoofAppPrivacyCategoryEnabled) {
        LCInstallAppEnumerationPrivacyProfile();
    }
    if(shouldEnableSpoofProfile && spoofSensorsAndUserDataCategoryEnabled) {
        LCInstallSensorsAndUserDataPrivacyProfile();
    }
    if(shouldEnableSpoofProfile && spoofSystemCategoryEnabled) {
        LCSwizzleIfPresent(NSUserDefaults.class, @selector(boolForKey:), @selector(hook_boolForKey:));
    }
    if(shouldEnableSpoofProfile && spoofStorageCategoryEnabled) {
        Class concreteURLClass = [[NSURL fileURLWithPath:NSHomeDirectory()] class];
        LCSwizzleIfPresentWithSourceClass(concreteURLClass, NSURL.class,
            @selector(resourceValuesForKeys:error:), @selector(hook_resourceValuesForKeys:error:));
        LCSwizzleIfPresentWithSourceClass(concreteURLClass, NSURL.class,
            @selector(getResourceValue:forKey:error:), @selector(hook_getResourceValue:forKey:error:));
    }
    if(shouldEnableSpoofProfile && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.iCloud")) {
        LCSwizzleIfPresent(NSFileManager.class, @selector(ubiquityIdentityToken), @selector(hook_ubiquityIdentityToken));
    }
    if(isolateWebViewData || (shouldEnableSpoofProfile && spoofWebViewCategoryEnabled)) {
        LCSwizzleIfPresent(WKWebView.class, @selector(initWithFrame:configuration:), @selector(hook_initWithFrame:configuration:));
    }
    if(shouldEnableSpoofProfile && spoofWebViewCategoryEnabled) {
        LCSwizzleIfPresent(WKWebView.class, @selector(setCustomUserAgent:), @selector(hook_setCustomUserAgent:));
    }

    if(blockDeviceInfoReads) {
        spoofHardwareModel = @"iPhone17,3";
        spoofHostName = @"iphone.local";
        spoofBoardModel = @"D47AP";
        spoofKernelVersion = @"Darwin Kernel Version 26.2.0";
        if(spoofSystemVersion.length == 0) {
            spoofSystemVersion = @"27.2";
            spoofOperatingSystemVersionValid = LCParseSystemVersion(spoofSystemVersion, &spoofOperatingSystemVersion);
        }
    }

    if(blockDeviceInfoReads ||
       (spoofIdentityCategoryEnabled && (spoofDeviceName || spoofDeviceModel)) ||
       (spoofSystemCategoryEnabled && (spoofSystemName || spoofSystemVersion))) {
        swizzle(UIDevice.class, @selector(name), @selector(hook_name));
        swizzle(UIDevice.class, @selector(model), @selector(hook_model));
        swizzle(UIDevice.class, @selector(localizedModel), @selector(hook_localizedModel));
        swizzle(UIDevice.class, @selector(userInterfaceIdiom), @selector(hook_userInterfaceIdiom));
        swizzle(UIDevice.class, @selector(systemName), @selector(hook_systemName));
        swizzle(UIDevice.class, @selector(systemVersion), @selector(hook_systemVersion));
    }
    if(blockDeviceInfoReads || (spoofBatteryCategoryEnabled &&
       (spoofBatteryLevel >= 0.0f || spoofBatteryState != UIDeviceBatteryStateUnknown))) {
        swizzle(UIDevice.class, @selector(batteryLevel), @selector(hook_batteryLevel));
        swizzle(UIDevice.class, @selector(batteryState), @selector(hook_batteryState));
        swizzle(UIDevice.class, @selector(isBatteryMonitoringEnabled), @selector(hook_isBatteryMonitoringEnabled));
    }
    if(blockDeviceInfoReads || (spoofSystemCategoryEnabled && (spoofOperatingSystemVersionValid || spoofSystemVersion))) {
        swizzle(NSProcessInfo.class, @selector(operatingSystemVersion), @selector(hook_operatingSystemVersion));
        swizzle(NSProcessInfo.class, @selector(operatingSystemVersionString), @selector(hook_operatingSystemVersionString));
        swizzle(NSProcessInfo.class, @selector(isOperatingSystemAtLeastVersion:), @selector(hook_isOperatingSystemAtLeastVersion:));
    }
    if(LCHostNameSpoofActive()) {
        LCSwizzleIfPresent(NSProcessInfo.class, @selector(hostName), @selector(hook_hostName));
    }
    if(blockDeviceInfoReads || (spoofSystemCategoryEnabled && spoofBootTime > 0)) {
        (void)LCProcessStartWallTime();
        LCSwizzleIfPresent(NSProcessInfo.class, @selector(systemUptime), @selector(hook_systemUptime));
    }
    if(blockDeviceInfoReads || (spoofBatteryCategoryEnabled && spoofLowPowerModeEnabledSet)) {
        swizzle(NSProcessInfo.class, @selector(isLowPowerModeEnabled), @selector(hook_isLowPowerModeEnabled));
    }
    if(blockDeviceInfoReads || (spoofSystemCategoryEnabled &&
       (spoofProcessorCount > 0 || spoofPhysicalMemory > 0))) {
        swizzle(NSProcessInfo.class, @selector(processorCount), @selector(hook_processorCount));
        swizzle(NSProcessInfo.class, @selector(activeProcessorCount), @selector(hook_activeProcessorCount));
        swizzle(NSProcessInfo.class, @selector(physicalMemory), @selector(hook_physicalMemory));
    }
    if(blockDeviceInfoReads || ((spoofBatteryCategoryEnabled || spoofSystemCategoryEnabled) && spoofThermalState >= 0)) {
        swizzle(NSProcessInfo.class, @selector(thermalState), @selector(hook_thermalState));
    }
    if(blockDeviceInfoReads || (spoofDisplayCategoryEnabled &&
       (spoofScreenWidth > 0 || spoofScreenHeight > 0 || spoofScreenScale > 0 ||
        spoofScreenNativeScale > 0 || spoofMaximumFramesPerSecond > 0 || spoofScreenBrightness >= 0))) {
        swizzle(UIScreen.class, @selector(nativeBounds), @selector(hook_nativeBounds));
        swizzle(UIScreen.class, @selector(bounds), @selector(hook_bounds));
        sUIScreenBoundsSwizzled = YES;
        swizzle(UIScreen.class, @selector(scale), @selector(hook_scale));
        swizzle(UIScreen.class, @selector(nativeScale), @selector(hook_nativeScale));
        swizzle(UIScreen.class, @selector(maximumFramesPerSecond), @selector(hook_maximumFramesPerSecond));
        swizzle(UIScreen.class, @selector(brightness), @selector(hook_brightness));
        LCSwizzleIfPresent(UITraitCollection.class, @selector(displayGamut), @selector(hook_displayGamut));
        LCSwizzleIfPresent(UITraitCollection.class, @selector(horizontalSizeClass), @selector(hook_horizontalSizeClass));
        LCSwizzleIfPresent(UITraitCollection.class, @selector(verticalSizeClass), @selector(hook_verticalSizeClass));
        LCSwizzleIfPresent(UITraitCollection.class, @selector(preferredContentSizeCategory), @selector(hook_preferredContentSizeCategory));
        LCSwizzleIfPresent(UIWindow.class, @selector(safeAreaInsets), @selector(hook_safeAreaInsets));
        if(!blockDeviceInfoReads && spoofUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
            LCSwizzleIfPresent(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_spoof_makeKeyAndVisible));
            LCSwizzleIfPresent(UIWindow.class, @selector(setHidden:), @selector(hook_spoof_setHidden:));
        }
    }
    if(blockDeviceInfoReads || (spoofLocaleCategoryEnabled && spoofLocale)) {
        LCSwizzleClassIfPresent(NSLocale.class, @selector(currentLocale), @selector(hook_currentLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(autoupdatingCurrentLocale), @selector(hook_autoupdatingCurrentLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(systemLocale), @selector(hook_systemLocale));
        LCSwizzleClassIfPresent(NSLocale.class, @selector(preferredLanguages), @selector(hook_preferredLanguages));
    }
    if(blockDeviceInfoReads || (spoofLocaleCategoryEnabled && (spoofTimeZone || spoofLocale))) {
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(localTimeZone), @selector(hook_localTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(systemTimeZone), @selector(hook_systemTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(defaultTimeZone), @selector(hook_defaultTimeZone));
        LCSwizzleClassIfPresent(NSTimeZone.class, @selector(autoupdatingCurrentTimeZone), @selector(hook_autoupdatingCurrentTimeZone));
        LCSwizzleClassIfPresent(NSCalendar.class, @selector(currentCalendar), @selector(hook_currentCalendar));
        LCSwizzleClassIfPresent(NSCalendar.class, @selector(autoupdatingCurrentCalendar), @selector(hook_autoupdatingCurrentCalendar));
    }
    if(blockDeviceInfoReads || (spoofTelephonyCategoryEnabled && spoofRadioAccessTechnology)) {
        Class telephonyClass = NSClassFromString(@"CTTelephonyNetworkInfo");
        LCSwizzleIfPresentWithSourceClass(telephonyClass, LCTelephonyNetworkInfoHookProvider.class, @selector(serviceCurrentRadioAccessTechnology), @selector(hook_serviceCurrentRadioAccessTechnology));
        LCSwizzleIfPresentWithSourceClass(telephonyClass, LCTelephonyNetworkInfoHookProvider.class, @selector(dataServiceIdentifier), @selector(hook_dataServiceIdentifier));
    }
    if(blockDeviceInfoReads || (spoofTelephonyCategoryEnabled &&
       (spoofSubscriberIdentifier || spoofSubscriberCarrierToken || spoofSubscriberSIMInsertedEnabled))) {
        Class subscriberClass = NSClassFromString(@"CTSubscriber");
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"identifier"), @selector(hook_identifier));
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"carrierToken"), @selector(hook_carrierToken));
        LCSwizzleIfPresentWithSourceClass(subscriberClass, LCSubscriberHookProvider.class, NSSelectorFromString(@"isSIMInserted"), @selector(hook_isSIMInserted));

        Class subscriberInfoClass = NSClassFromString(@"CTSubscriberInfo");
        LCSwizzleClassIfPresentWithSourceClass(subscriberInfoClass, LCSubscriberInfoHookProvider.class, @selector(subscribers), @selector(hook_subscribers));
    }

    // HTTP header device identity and locale rewriting across NSMutableURLRequest & NSURLSessionConfiguration.
    if(blockDeviceInfoReads || (shouldEnableSpoofProfile &&
       (spoofNetworkHeadersCategoryEnabled || (spoofLocaleCategoryEnabled && spoofLocale != nil) || spoofCustomUserAgent.length > 0))) {
        LCInitUserAgentRegexes();
        swizzle(NSMutableURLRequest.class,
            @selector(setValue:forHTTPHeaderField:),
            @selector(hook_setValue:forHTTPHeaderField:));
        swizzle(NSMutableURLRequest.class,
            @selector(addValue:forHTTPHeaderField:),
            @selector(hook_addValue:forHTTPHeaderField:));
        swizzle(NSMutableURLRequest.class,
            @selector(setAllHTTPHeaderFields:),
            @selector(hook_setAllHTTPHeaderFields:));
        swizzle(NSURLSessionConfiguration.class,
            @selector(setHTTPAdditionalHeaders:),
            @selector(hook_setHTTPAdditionalHeaders:));
        LCSwizzleClassIfPresent(NSURLSessionConfiguration.class,
            @selector(defaultSessionConfiguration),
            @selector(hook_defaultSessionConfiguration));
        LCSwizzleClassIfPresent(NSURLSessionConfiguration.class,
            @selector(ephemeralSessionConfiguration),
            @selector(hook_ephemeralSessionConfiguration));
    }

    if (shouldEnableSpoofProfile || blockDeviceInfoReads) {
        LCFlushProfileTelemetryToDisk(YES);
    }
    });
}

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];

    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcHome = [NSClassFromString(@"LCSharedUtils") cachedLcHomePath] ?: NSHomeDirectory();
        NSString* lcDocFolder = [lcHome stringByAppendingPathComponent:@"Documents"];

        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }

    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString: [NSString stringWithFormat: @"%@://", scheme]]];
#pragma clang diagnostic pop
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];

    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }

    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = LCCreateOverlayAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];

    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    LCPresentAlertInOverlayWindow(window, alert);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = LCCreateOverlayAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    LCPresentAlertInOverlayWindow(window, alert);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];

        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];

        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }

    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };

    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }

    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }

    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = LCCreateOverlayAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });

    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    LCPresentAlertInOverlayWindow(window, alert);


}

void LCOpenSideStoreURL(NSURL* sidestoreUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
        return;
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = LCCreateOverlayAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    LCPresentAlertInOverlayWindow(window, alert);

}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            return;
        }

        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }

        if(!bundle || ([lcAppInfo[@"isHidden"] boolValue] && [NSUserDefaults.lcSharedDefaults boolForKey:@"LCStrictHiding"])) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }

}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static NSURL *sLaunchExtensionBookmarkedURL = nil;

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    } else {
        [resolvedURL startAccessingSecurityScopedResource];
        sLaunchExtensionBookmarkedURL = resolvedURL;
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];

}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    // pass through sidestore urls
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        return LCControlAppURLHandlingPassThrough;
    }

    if([url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(url);
        return LCControlAppURLHandlingStop;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme]) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;

    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }

        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"LiveContainer", false);
            return LCControlAppURLHandlingStop;
        }

        const char *homeEnv = getenv("HOME");
        NSString* containerId = (homeEnv ? [NSString stringWithUTF8String:homeEnv] : NSHomeDirectory()).lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches OR sidestore is running and we are launching builtinSideStore
        if (([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) ||
            (NSUserDefaults.isSideStore && [bundleName isEqualToString:@"builtinSideStore"])) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            if([bundleName isEqualToString:@"builtinSideStore"]) {
                LCShowSwitchAppConfirmation(url, @"SideStore", NO);
                return LCControlAppURLHandlingStop;
            }
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }

        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;

    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme]) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }

    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }

        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
#pragma clang diagnostic pop
        context.payload = newDict;


        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }

        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];

        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;

    } while(0);

#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

-(BOOL)hook__handleDelegateCallbacksWithOptions:(id)arg1 isSuspended:(BOOL)arg2 restoreState:(BOOL)arg3 {
    BOOL ans = [self hook__handleDelegateCallbacksWithOptions:arg1 isSuspended:arg2 restoreState:arg3];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            LSApplicationWorkspace* workspace = [objc_lookUpClass("LSApplicationWorkspace") defaultWorkspace];
            [workspace openApplicationWithBundleID:@"com.apple.springboard"];
            [workspace openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
        });

    });


    return ans;
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }

    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    if(canAppOpenItself(url) || shouldRedirectOpenURLToHost(url)) return YES;
    if(spoofProfileEnabled && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.canOpenURL")) return NO;
    return [self hook_canOpenURL:url];
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
            swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
            swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
        });
    }
    [self hook_setDelegate:delegate];
}

- (void)hook_lc_sendEvent:(UIEvent *)event {
    [self hook_lc_sendEvent:event];
    if (event.type != UIEventTypeTouches) {
        return;
    }
    static CFAbsoluteTime sLastGuestTouchPostTime = 0;
    BOOL hasTouchBegan = NO;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseBegan) {
            hasTouchBegan = YES;
            break;
        }
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (hasTouchBegan || (now - sLastGuestTouchPostTime) >= 0.4) {
        sLastGuestTouchPostTime = now;
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.kdt.livecontainer.multitask.guestTouch"),
            NULL,
            NULL,
            true
        );
    }
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook_supportedInterfaceOrientations {
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }

}

@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}
- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_resignKeyWindow {
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    for(UIWindowScene *windowScene in UIApplication.sharedApplication.connectedScenes) {
        if(!self.windowScene && self.screen == windowScene.screen) {
            self.windowScene = windowScene;
            break;
        }
    }
}
@end
@implementation UIPasteboard(hook)

+ (UIPasteboard *)hook_generalPasteboard {
    if(strictTestMode || (spoofProfileEnabled && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.pasteboard"))) {
        return strictPrivatePasteboard ?: [self hook_generalPasteboard];
    }
    return [self hook_generalPasteboard];
}

+ (UIPasteboard *)hook_pasteboardWithName:(UIPasteboardName)pasteboardName create:(BOOL)create {
    if ((strictTestMode || (spoofProfileEnabled && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.pasteboard"))) &&
        (pasteboardName == nil || pasteboardName.length == 0 || [pasteboardName isEqualToString:UIPasteboardNameGeneral])) {
        return strictPrivatePasteboard ?: [self hook_pasteboardWithName:pasteboardName create:create];
    }
    return [self hook_pasteboardWithName:pasteboardName create:create];
}

@end

@implementation NSURLSessionTask(hook)

- (void)hook_resume {
    if(strictTestMode) {
        [self cancel];
        return;
    }
    [self hook_resume];
}

@end

@implementation NSUserDefaults(LCFingerprintProfile)

- (BOOL)hook_boolForKey:(NSString *)defaultName {
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && LCFeatureEnabled(@"system.lowDataMode") && [defaultName isEqualToString:@"LDMGlobalEnabled"]) return NO;
    return [self hook_boolForKey:defaultName];
}

@end

static id LCStorageProfileValue(NSURLResourceKey key) {
    if(LCFeatureEnabled(@"storage.creationDates") && [key isEqualToString:NSURLCreationDateKey]) return [NSDate dateWithTimeIntervalSince1970:spoofStorageFileCreationTime];
    if(LCFeatureEnabled(@"storage.capacity") && [key isEqualToString:NSURLVolumeTotalCapacityKey]) return @(spoofStorageTotalCapacity);
    if(LCFeatureEnabled(@"storage.capacity") && [key isEqualToString:NSURLVolumeAvailableCapacityKey]) return @(spoofStorageAvailableCapacity);
    if(LCFeatureEnabled(@"storage.capacity") && [key isEqualToString:NSURLVolumeAvailableCapacityForImportantUsageKey]) return @(spoofStorageAvailableCapacity);
    if(LCFeatureEnabled(@"storage.capacity") && [key isEqualToString:NSURLVolumeAvailableCapacityForOpportunisticUsageKey]) return @(spoofStorageAvailableCapacity);
    if(LCFeatureEnabled(@"storage.creationDates") && [key isEqualToString:NSURLVolumeCreationDateKey]) return [NSDate dateWithTimeIntervalSince1970:spoofStorageVolumeCreationTime];
    if(LCFeatureEnabled(@"storage.identity") && [key isEqualToString:NSURLVolumeUUIDStringKey]) return spoofStorageVolumeUUID;
    if(LCFeatureEnabled(@"storage.identity") && ([key isEqualToString:NSURLVolumeNameKey] || [key isEqualToString:NSURLVolumeLocalizedNameKey])) return spoofStorageVolumeName;
    return nil;
}

@implementation NSURL(LCFingerprintProfile)

- (NSDictionary<NSURLResourceKey, id> *)hook_resourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error {
    NSDictionary *original = [self hook_resourceValuesForKeys:keys error:error];
    if(!spoofProfileEnabled || !spoofStorageCategoryEnabled) return original;
    NSMutableDictionary *values = original ? [original mutableCopy] : [NSMutableDictionary dictionary];
    for(NSURLResourceKey key in keys) {
        id replacement = LCStorageProfileValue(key);
        if(replacement) values[key] = replacement;
    }
    return values;
}

- (BOOL)hook_getResourceValue:(out id _Nullable *)value forKey:(NSURLResourceKey)key error:(NSError **)error {
    if(spoofProfileEnabled && spoofStorageCategoryEnabled) {
        id replacement = LCStorageProfileValue(key);
        if(replacement) {
            if(value) *value = replacement;
            return YES;
        }
    }
    return [self hook_getResourceValue:value forKey:key error:error];
}

@end

@implementation NSFileManager(LCFingerprintProfile)

- (id)hook_ubiquityIdentityToken {
    if(spoofProfileEnabled && spoofAppPrivacyCategoryEnabled && LCFeatureEnabled(@"app.iCloud")) return nil;
    return [self hook_ubiquityIdentityToken];
}

@end

static const char kLCWebUserContentConfiguredKey = 0;

static WKWebsiteDataStore *LCIsolatedWebsiteDataStore(BOOL ephemeral) {
    if (ephemeral) {
        return [WKWebsiteDataStore nonPersistentDataStore];
    }
    if (strictTestMode) {
        static WKWebsiteDataStore *sStrictEphemeralStore = nil;
        static dispatch_once_t strictStoreOnce;
        dispatch_once(&strictStoreOnce, ^{
            sStrictEphemeralStore = [WKWebsiteDataStore nonPersistentDataStore];
        });
        return sStrictEphemeralStore;
    }
    const char *homeEnv = getenv("HOME");
    NSString *homePath = homeEnv ? @(homeEnv) : NSHomeDirectory();
    NSString *containerFolder = homePath.lastPathComponent;
    NSString *storeKey = containerFolder;
    if ([homePath containsString:@"/Extensions/"] && containerFolder.length > 0) {
        NSString *parentContainer = homePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.lastPathComponent;
        storeKey = [NSString stringWithFormat:@"ext:%@:%@", parentContainer ?: @"", containerFolder];
    }
    NSUUID *storeUUID = [NSClassFromString(@"LCSharedUtils") webKitStoreIdentifierForContainerUUID:storeKey];
    if (storeUUID) {
        return [WKWebsiteDataStore dataStoreForIdentifier:storeUUID];
    }
    return [WKWebsiteDataStore nonPersistentDataStore];
}

@interface WKWebViewConfiguration (LCRelatedWebViewPrivate)
@property (nonatomic, readonly, nullable) WKWebView *_relatedWebView;
@end

@implementation WKWebsiteDataStore(LCContainerIsolation)

+ (WKWebsiteDataStore *)hook_defaultDataStore {
    if (isolateWebViewData) {
        return LCIsolatedWebsiteDataStore(NO);
    }
    return [self hook_defaultDataStore];
}

@end

@implementation WKWebView(LCFingerprintProfile)

- (void)hook_setCustomUserAgent:(NSString *)customUserAgent {
    NSString *effectiveUA = customUserAgent;
    if(spoofProfileEnabled && spoofWebViewCategoryEnabled && LCFeatureEnabled(@"web.navigator")) {
        LCRecordProfileInterception(LCProfileTelemetryVectorWebKit);
        NSString *builtUA = LCBuildWebKitUserAgent();
        if(spoofCustomUserAgent.length > 0) {
            effectiveUA = spoofCustomUserAgent;
        } else if(effectiveUA.length > 0 && ![effectiveUA isEqualToString:builtUA]) {
            effectiveUA = LCRewriteUserAgent(effectiveUA);
        } else {
            effectiveUA = builtUA;
        }
    }
    [self hook_setCustomUserAgent:effectiveUA];
}

- (instancetype)hook_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebViewConfiguration *effectiveConfig = configuration ?: [[WKWebViewConfiguration alloc] init];
    BOOL isRelatedWebViewConfig = (configuration &&
        [configuration respondsToSelector:@selector(_relatedWebView)] &&
        configuration._relatedWebView != nil);
    if (!isRelatedWebViewConfig) {
        if (isolateWebViewData && strictTestMode) {
            effectiveConfig.websiteDataStore = LCIsolatedWebsiteDataStore(NO);
        } else if (isolateWebViewData && !configuration) {
            effectiveConfig.websiteDataStore = LCIsolatedWebsiteDataStore(NO);
        }
    }
    NSString *profileScript = nil;
    if(spoofProfileEnabled && spoofWebViewCategoryEnabled) {
        LCRecordProfileInterception(LCProfileTelemetryVectorWebKit);
        profileScript = LCWebViewProfileScript();
        WKUserContentController *ucc = effectiveConfig.userContentController;
        if(ucc && !objc_getAssociatedObject(ucc, &kLCWebUserContentConfiguredKey)) {
            WKUserScript *script = [[WKUserScript alloc] initWithSource:profileScript
                injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                forMainFrameOnly:NO];
            [ucc addUserScript:script];
            objc_setAssociatedObject(ucc, &kLCWebUserContentConfiguredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(spoofSystemVersion.length > 0 && effectiveConfig.applicationNameForUserAgent.length == 0) {
            effectiveConfig.applicationNameForUserAgent = @"Mobile/15E148";
        }
    }
    WKWebView *webView = [self hook_initWithFrame:frame configuration:effectiveConfig];
    if(spoofProfileEnabled && spoofWebViewCategoryEnabled && LCFeatureEnabled(@"web.navigator")) {
        [webView hook_setCustomUserAgent:LCBuildWebKitUserAgent()];
    }
    if(profileScript.length > 0) {
        [webView evaluateJavaScript:profileScript completionHandler:nil];
    }
    return webView;
}

@end

@implementation LCLSApplicationWorkspaceHookProvider

- (id)hook_deviceIdentifierForVendor {
    if(blockDeviceInfoReads) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCBlockedZeroUUID();
    }
    if(spoofIdentityCategoryEnabled && idForVendorUUID) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return idForVendorUUID;
    }
    return [self hook_deviceIdentifierForVendor];
}

@end

@implementation UIDevice(hook)

- (NSUUID*)hook_identifierForVendor {
    if(blockDeviceInfoReads) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return LCBlockedZeroUUID();
    }
    if(spoofIdentityCategoryEnabled && idForVendorUUID) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return idForVendorUUID;
    }
    return [self hook_identifierForVendor];
}

- (NSString *)hook_name {
    if(blockDeviceInfoReads) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return @"iPhone";
    }
    if(spoofProfileEnabled && spoofIdentityCategoryEnabled && spoofDeviceName.length > 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return spoofDeviceName;
    }
    return [self hook_name];
}

- (NSString *)hook_model {
    if(blockDeviceInfoReads) {
        return @"iPhone";
    }
    if(spoofProfileEnabled && spoofIdentityCategoryEnabled && spoofDeviceModel.length > 0) {
        return spoofDeviceModel;
    }
    return [self hook_model];
}

- (NSString *)hook_localizedModel {
    if(blockDeviceInfoReads) {
        return @"iPhone";
    }
    if(spoofProfileEnabled && spoofIdentityCategoryEnabled && spoofDeviceModel.length > 0) {
        return spoofDeviceModel;
    }
    return [self hook_localizedModel];
}

- (UIUserInterfaceIdiom)hook_userInterfaceIdiom {
    if(blockDeviceInfoReads) {
        return UIUserInterfaceIdiomPhone;
    }
    if(spoofProfileEnabled && spoofIdentityCategoryEnabled && spoofDeviceModel.length > 0) {
        if([spoofDeviceModel rangeOfString:@"ipad" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return UIUserInterfaceIdiomPad;
        }
        return UIUserInterfaceIdiomPhone;
    }
    return [self hook_userInterfaceIdiom];
}

- (NSString *)hook_systemName {
    if(blockDeviceInfoReads) {
        return @"iOS";
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofSystemName.length > 0) {
        return spoofSystemName;
    }
    return [self hook_systemName];
}

- (NSString *)hook_systemVersion {
    if(blockDeviceInfoReads) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return spoofSystemVersion.length > 0 ? spoofSystemVersion : @"27.2";
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofSystemVersion.length > 0) {
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
        return spoofSystemVersion;
    }
    return [self hook_systemVersion];
}

- (float)hook_batteryLevel {
    if(blockDeviceInfoReads) {
        return -1.0f;
    }
    if(spoofProfileEnabled && spoofBatteryCategoryEnabled && spoofBatteryLevel >= 0.0f) {
        return spoofBatteryLevel;
    }
    return [self hook_batteryLevel];
}

- (UIDeviceBatteryState)hook_batteryState {
    if(blockDeviceInfoReads) {
        return UIDeviceBatteryStateUnknown;
    }
    if(spoofProfileEnabled && spoofBatteryCategoryEnabled && spoofBatteryState >= UIDeviceBatteryStateUnknown && spoofBatteryState <= UIDeviceBatteryStateFull) {
        return (UIDeviceBatteryState)spoofBatteryState;
    }
    return [self hook_batteryState];
}

- (BOOL)hook_isBatteryMonitoringEnabled {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofBatteryCategoryEnabled && (spoofBatteryLevel >= 0.0f || spoofBatteryState != UIDeviceBatteryStateUnknown)) {
        return YES;
    }
    return [self hook_isBatteryMonitoringEnabled];
}

@end

@implementation NSProcessInfo(hook)

- (NSOperatingSystemVersion)hook_operatingSystemVersion {
    if(blockDeviceInfoReads) {
        return (NSOperatingSystemVersion){ .majorVersion = 27, .minorVersion = 2, .patchVersion = 0 };
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofOperatingSystemVersionValid) {
        return spoofOperatingSystemVersion;
    }
    return [self hook_operatingSystemVersion];
}

- (NSString *)hook_operatingSystemVersionString {
    if(blockDeviceInfoReads) {
        return @"iOS 27.2";
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofSystemVersion.length > 0) {
        NSString *name = spoofSystemName.length > 0 ? spoofSystemName : @"iOS";
        return [NSString stringWithFormat:@"%@ %@", name, spoofSystemVersion];
    }
    return [self hook_operatingSystemVersionString];
}

- (BOOL)hook_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if(blockDeviceInfoReads) {
        NSOperatingSystemVersion blockedVersion = { .majorVersion = 27, .minorVersion = 2, .patchVersion = 0 };
        return LCCompareOSVersion(blockedVersion, version) >= 0;
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofOperatingSystemVersionValid) {
        return LCCompareOSVersion(spoofOperatingSystemVersion, version) >= 0;
    }
    return [self hook_isOperatingSystemAtLeastVersion:version];
}

- (NSString *)hook_hostName {
    if(LCHostNameSpoofActive()) {
        LCRecordProfileInterception(LCProfileTelemetryVectorNetwork);
        return LCEffectiveSpoofHostName();
    }
    return [self hook_hostName];
}

- (NSTimeInterval)hook_systemUptime {
    if(blockDeviceInfoReads) {
        return 3600.0;
    }
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofBootTime > 0) {
        NSTimeInterval delta = (NSTimeInterval)((CFAbsoluteTime)time(NULL) - (CFAbsoluteTime)spoofBootTime);
        return MAX(1.0, delta);
    }
    return [self hook_systemUptime];
}

- (BOOL)hook_isLowPowerModeEnabled {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofBatteryCategoryEnabled && spoofLowPowerModeEnabledSet) {
        return spoofLowPowerModeEnabled;
    }
    return [self hook_isLowPowerModeEnabled];
}

- (NSUInteger)hook_processorCount {
    if(blockDeviceInfoReads) return 6;
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofProcessorCount > 0) return spoofProcessorCount;
    return [self hook_processorCount];
}

- (NSUInteger)hook_activeProcessorCount {
    if(blockDeviceInfoReads) return 6;
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofProcessorCount > 0) return spoofProcessorCount;
    return [self hook_activeProcessorCount];
}

- (unsigned long long)hook_physicalMemory {
    if(blockDeviceInfoReads) return 8ULL * 1024ULL * 1024ULL * 1024ULL;
    if(spoofProfileEnabled && spoofSystemCategoryEnabled && spoofPhysicalMemory > 0) return spoofPhysicalMemory;
    return [self hook_physicalMemory];
}

- (NSProcessInfoThermalState)hook_thermalState {
    if(blockDeviceInfoReads) return NSProcessInfoThermalStateNominal;
    if(spoofProfileEnabled && (spoofBatteryCategoryEnabled || spoofSystemCategoryEnabled) &&
       spoofThermalState >= NSProcessInfoThermalStateNominal &&
       spoofThermalState <= NSProcessInfoThermalStateCritical) {
        return (NSProcessInfoThermalState)spoofThermalState;
    }
    return [self hook_thermalState];
}

@end

// MARK: - System & Display Profile: screen fingerprint

@implementation UIScreen(LCSystemDisplayProfile)

- (CGRect)hook_nativeBounds {
    if(blockDeviceInfoReads) return CGRectMake(0, 0, 1170, 2532);
    CGRect bounds = [self hook_nativeBounds];
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofScreenWidth > 0 && spoofScreenHeight > 0) {
        bounds.size.width = spoofScreenWidth;
        bounds.size.height = spoofScreenHeight;
        LCRecordProfileInterception(LCProfileTelemetryVectorHardware);
    }
    return bounds;
}

- (CGRect)hook_bounds {
    CGRect realBounds = [self hook_bounds];
    if(blockDeviceInfoReads) {
        BOOL landscape = realBounds.size.width > realBounds.size.height;
        return landscape ? CGRectMake(0, 0, 844, 390) : CGRectMake(0, 0, 390, 844);
    }
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofScreenWidth > 0 && spoofScreenHeight > 0) {
        CGFloat scaleFactor = spoofScreenScale > 0 ? spoofScreenScale : 3.0;
        CGFloat ptW = spoofScreenPointWidth > 0 ? spoofScreenPointWidth : round(spoofScreenWidth / scaleFactor);
        CGFloat ptH = spoofScreenPointHeight > 0 ? spoofScreenPointHeight : round(spoofScreenHeight / scaleFactor);
        BOOL landscape = realBounds.size.width > realBounds.size.height;
        return CGRectMake(0, 0, landscape ? MAX(ptW, ptH) : MIN(ptW, ptH), landscape ? MIN(ptW, ptH) : MAX(ptW, ptH));
    }
    return realBounds;
}

- (CGFloat)hook_scale {
    if(blockDeviceInfoReads) return 3.0;
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofScreenScale > 0) return spoofScreenScale;
    return [self hook_scale];
}

- (CGFloat)hook_nativeScale {
    if(blockDeviceInfoReads) return 3.0;
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofScreenNativeScale > 0) return spoofScreenNativeScale;
    return [self hook_nativeScale];
}

- (NSInteger)hook_maximumFramesPerSecond {
    if(blockDeviceInfoReads) return 60;
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofMaximumFramesPerSecond > 0) return spoofMaximumFramesPerSecond;
    return [self hook_maximumFramesPerSecond];
}

- (CGFloat)hook_brightness {
    if(blockDeviceInfoReads) return 0.5;
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofScreenBrightness >= 0) return spoofScreenBrightness;
    return [self hook_brightness];
}

@end

@implementation UITraitCollection(LCFingerprintProfile)

- (UIDisplayGamut)hook_displayGamut {
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled) return (UIDisplayGamut)spoofDisplayGamut;
    return [self hook_displayGamut];
}

- (UIUserInterfaceSizeClass)hook_horizontalSizeClass {
    UIUserInterfaceSizeClass original = [self hook_horizontalSizeClass];
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && original != UIUserInterfaceSizeClassUnspecified &&
       spoofHorizontalSizeClass != UIUserInterfaceSizeClassUnspecified) {
        return (UIUserInterfaceSizeClass)spoofHorizontalSizeClass;
    }
    return original;
}

- (UIUserInterfaceSizeClass)hook_verticalSizeClass {
    UIUserInterfaceSizeClass original = [self hook_verticalSizeClass];
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && original != UIUserInterfaceSizeClassUnspecified &&
       spoofVerticalSizeClass != UIUserInterfaceSizeClassUnspecified) {
        return (UIUserInterfaceSizeClass)spoofVerticalSizeClass;
    }
    return original;
}

- (UIContentSizeCategory)hook_preferredContentSizeCategory {
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled) {
        return spoofPreferredContentSizeCategory ?: UIContentSizeCategoryLarge;
    }
    return [self hook_preferredContentSizeCategory];
}

- (UIAccessibilityContrast)hook_accessibilityContrast {
    if(spoofProfileEnabled && spoofAccessibilityCategoryEnabled) return (UIAccessibilityContrast)spoofAccessibilityContrast;
    return [self hook_accessibilityContrast];
}

@end

@implementation UIWindow(LCFingerprintProfile)

- (void)hook_spoof_makeKeyAndVisible {
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        self.overrideUserInterfaceStyle = (UIUserInterfaceStyle)spoofUserInterfaceStyle;
    }
    [self hook_spoof_makeKeyAndVisible];
}

- (void)hook_spoof_setHidden:(BOOL)hidden {
    if(!hidden && spoofProfileEnabled && spoofDisplayCategoryEnabled && spoofUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        self.overrideUserInterfaceStyle = (UIUserInterfaceStyle)spoofUserInterfaceStyle;
    }
    [self hook_spoof_setHidden:hidden];
}

- (UIEdgeInsets)hook_safeAreaInsets {
    UIEdgeInsets original = [self hook_safeAreaInsets];
    if(spoofProfileEnabled && spoofDisplayCategoryEnabled && self.windowScene) {
        UIScreen *screen = self.windowScene.screen;
        CGRect realScreenBounds = (screen && sUIScreenBoundsSwizzled) ? [screen hook_bounds] : (screen ? screen.bounds : self.bounds);
        CGRect spoofedScreenBounds = screen ? screen.bounds : self.bounds;
        BOOL matchesRealScreen = fabs(CGRectGetWidth(self.bounds) - CGRectGetWidth(realScreenBounds)) < 2.0 &&
                                 fabs(CGRectGetHeight(self.bounds) - CGRectGetHeight(realScreenBounds)) < 2.0;
        BOOL matchesSpoofedScreen = fabs(CGRectGetWidth(self.bounds) - CGRectGetWidth(spoofedScreenBounds)) < 2.0 &&
                                    fabs(CGRectGetHeight(self.bounds) - CGRectGetHeight(spoofedScreenBounds)) < 2.0;
        if(matchesRealScreen || matchesSpoofedScreen) {
            if(self.bounds.size.width > self.bounds.size.height) {
                return UIEdgeInsetsMake(0, MAX(spoofSafeAreaInsets.top, spoofSafeAreaInsets.left),
                                        MIN(21.0, spoofSafeAreaInsets.bottom), MAX(spoofSafeAreaInsets.top, spoofSafeAreaInsets.right));
            }
            return spoofSafeAreaInsets;
        }
    }
    return original;
}

@end

@implementation NSLocale(hook)

+ (NSLocale *)hook_currentLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_currentLocale];
}

+ (NSLocale *)hook_autoupdatingCurrentLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_autoupdatingCurrentLocale];
}

+ (NSLocale *)hook_systemLocale {
    if(blockDeviceInfoReads) {
        return LCBlockedLocale();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale) {
        return spoofLocale;
    }
    return [self hook_systemLocale];
}

+ (NSArray<NSString *> *)hook_preferredLanguages {
    if(blockDeviceInfoReads) {
        return @[@"und"];
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofLocale) {
        NSString *languageIdentifier = [spoofLocale objectForKey:NSLocaleIdentifier];
        if(languageIdentifier.length > 0) {
            return @[languageIdentifier];
        }
    }
    return [self hook_preferredLanguages];
}

@end

@implementation NSTimeZone(hook)

+ (NSTimeZone *)hook_localTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_localTimeZone];
}

+ (NSTimeZone *)hook_systemTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_systemTimeZone];
}

+ (NSTimeZone *)hook_defaultTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_defaultTimeZone];
}

+ (NSTimeZone *)hook_autoupdatingCurrentTimeZone {
    if(blockDeviceInfoReads) {
        return LCBlockedTimeZone();
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && spoofTimeZone) {
        return spoofTimeZone;
    }
    return [self hook_autoupdatingCurrentTimeZone];
}

@end

@implementation NSCalendar(hook)

+ (NSCalendar *)hook_currentCalendar {
    if(blockDeviceInfoReads) {
        return LCCalendarForProfile(LCBlockedTimeZone());
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && (spoofLocale || spoofTimeZone)) {
        return LCCalendarForProfile(spoofTimeZone);
    }
    return [self hook_currentCalendar];
}

+ (NSCalendar *)hook_autoupdatingCurrentCalendar {
    if(blockDeviceInfoReads) {
        return LCCalendarForProfile(LCBlockedTimeZone());
    }
    if(spoofProfileEnabled && spoofLocaleCategoryEnabled && (spoofLocale || spoofTimeZone)) {
        return LCCalendarForProfile(spoofTimeZone);
    }
    return [self hook_autoupdatingCurrentCalendar];
}

@end

@implementation LCTelephonyNetworkInfoHookProvider

- (id)hook_serviceCurrentRadioAccessTechnology {
    if(blockDeviceInfoReads) {
        return @{};
    }
    if(spoofProfileEnabled && spoofTelephonyCategoryEnabled && spoofRadioAccessTechnology.length > 0) {
        return @{
            @"0000000100000001": spoofRadioAccessTechnology
        };
    }
    return [self hook_serviceCurrentRadioAccessTechnology];
}

- (id)hook_dataServiceIdentifier {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(spoofProfileEnabled && spoofTelephonyCategoryEnabled && spoofRadioAccessTechnology.length > 0) {
        return @"0000000100000001";
    }
    return [self hook_dataServiceIdentifier];
}

@end

@implementation LCSubscriberHookProvider

- (id)hook_identifier {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(spoofProfileEnabled && spoofTelephonyCategoryEnabled && spoofSubscriberIdentifier.length > 0) {
        return spoofSubscriberIdentifier;
    }
    return [self hook_identifier];
}

- (id)hook_carrierToken {
    if(blockDeviceInfoReads) {
        return nil;
    }
    if(spoofProfileEnabled && spoofTelephonyCategoryEnabled && spoofSubscriberCarrierToken) {
        return spoofSubscriberCarrierToken;
    }
    return [self hook_carrierToken];
}

- (BOOL)hook_isSIMInserted {
    if(blockDeviceInfoReads) {
        return NO;
    }
    if(spoofProfileEnabled && spoofTelephonyCategoryEnabled && spoofSubscriberSIMInsertedEnabled) {
        return spoofSubscriberSIMInserted;
    }
    return [self hook_isSIMInserted];
}

@end

@implementation LCSubscriberInfoHookProvider

+ (id)hook_subscribers {
    if(blockDeviceInfoReads) {
        return @[];
    }
    return [self hook_subscribers];
}

@end

@implementation LCNetworkExtensionStrictHookProvider

+ (void)hook_fetchCurrentWithCompletionHandler:(void (^)(id currentNetwork))completionHandler {
    if(strictTestMode) {
        if(completionHandler) {
            completionHandler(nil);
        }
        return;
    }
    [self hook_fetchCurrentWithCompletionHandler:completionHandler];
}

@end

// MARK: - In-Process ASWebAuthenticationSession / SFAuthenticationSession OAuth Controller (#162, #242, #986)

static const char kLCAuthURLKey = 0;
static const char kLCAuthCallbackSchemeKey = 0;
static const char kLCAuthCallbackObjKey = 0;
static const char kLCAuthCompletionKey = 0;
static const char kLCAuthActiveVCKey = 0;
static const char kLCAuthInProcessCancelledKey = 0;

static BOOL LCIsSchemeRegisteredInHostBundle(NSString *scheme) {
    if (scheme.length == 0) return NO;
    NSBundle *hostBundle = [NSUserDefaults lcMainBundle];
    if (!hostBundle) return NO;
    NSArray *urlTypes = hostBundle.infoDictionary[@"CFBundleURLTypes"];
    NSString *lower = scheme.lowercaseString;
    for (NSDictionary *entry in urlTypes) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSArray *schemes = entry[@"CFBundleURLSchemes"];
        if (![schemes isKindOfClass:NSArray.class]) continue;
        for (id item in schemes) {
            if ([item isKindOfClass:NSString.class] && [((NSString *)item).lowercaseString isEqualToString:lower]) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL LCShouldInterceptAuthSession(NSURL *authURL, NSString *callbackScheme, ASWebAuthenticationSessionCallback *callbackObj) {
    if (!authURL) return NO;
    if (callbackScheme.length > 0) {
        NSString *lower = callbackScheme.lowercaseString;
        if ([lower isEqualToString:@"http"] || [lower isEqualToString:@"https"]) {
            return NO;
        }
        return !LCIsSchemeRegisteredInHostBundle(callbackScheme);
    }
    if (callbackObj && [callbackObj respondsToSelector:@selector(matchesURL:)]) {
        NSArray *guestURLTypes = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"];
        if ([guestURLTypes isKindOfClass:NSArray.class]) {
            for (NSDictionary *entry in guestURLTypes) {
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                NSArray *schemes = entry[@"CFBundleURLSchemes"];
                if (![schemes isKindOfClass:NSArray.class]) continue;
                for (id item in schemes) {
                    if (![item isKindOfClass:NSString.class]) continue;
                    NSString *s = (NSString *)item;
                    NSURL *probe = [NSURL URLWithString:[NSString stringWithFormat:@"%@://oauth-callback", s]];
                    if (probe && [callbackObj matchesURL:probe] && !LCIsSchemeRegisteredInHostBundle(s)) {
                        return YES;
                    }
                }
            }
        }
        NSURLComponents *comp = [NSURLComponents componentsWithURL:authURL resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *q in comp.queryItems) {
            NSString *n = q.name.lowercaseString;
            if ([n isEqualToString:@"redirect_uri"] || [n isEqualToString:@"redirect_url"] || [n isEqualToString:@"callback"]) {
                NSURL *redir = q.value.length > 0 ? [NSURL URLWithString:q.value] : nil;
                NSString *rs = redir.scheme.lowercaseString;
                if (rs.length > 0 && ![rs isEqualToString:@"http"] && ![rs isEqualToString:@"https"] &&
                    [callbackObj matchesURL:redir] && !LCIsSchemeRegisteredInHostBundle(rs)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

@interface LCWebAuthSessionViewController : UIViewController <WKNavigationDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) NSURL *initialURL;
@property (nonatomic, copy) NSString *callbackScheme;
@property (nonatomic, strong) ASWebAuthenticationSessionCallback *callbackObj;
@property (nonatomic, assign) BOOL prefersEphemeral;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *additionalHeaders;
@property (nonatomic, copy) void (^completionBlock)(NSURL * _Nullable callbackURL, NSError * _Nullable error);
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL didComplete;
@property (nonatomic, weak) id ownerSession;
@end

@implementation LCWebAuthSessionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                           target:self
                                                                                           action:@selector(onCancelTapped)];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    self.navigationItem.title = self.initialURL.host ?: @"Sign In";

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    if (self.prefersEphemeral || strictTestMode) {
        cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    } else if (isolateWebViewData) {
        cfg.websiteDataStore = LCIsolatedWebsiteDataStore(NO);
    } else {
        cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    }
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    if (self.initialURL) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.initialURL];
        [self.additionalHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) {
                [req setValue:v forHTTPHeaderField:k];
            }
        }];
        [self.webView loadRequest:req];
    }
}

- (void)finishWithURL:(NSURL *)url error:(NSError *)error {
    if (self.didComplete) return;
    self.didComplete = YES;
    void (^completion)(NSURL * _Nullable, NSError * _Nullable) = self.completionBlock;
    self.completionBlock = nil;
    id owner = self.ownerSession;
    self.ownerSession = nil;
    if (owner) {
        objc_setAssociatedObject(owner, &kLCAuthActiveVCKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIViewController *toDismiss = self.navigationController ?: self;
    if (toDismiss.presentingViewController) {
        [toDismiss dismissViewControllerAnimated:YES completion:^{
            if (completion) completion(url, error);
        }];
    } else {
        if (completion) completion(url, error);
    }
}

- (void)cancelSessionExternally {
    NSError *err = [NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain
                                       code:ASWebAuthenticationSessionErrorCodeCanceledLogin
                                   userInfo:nil];
    [self finishWithURL:nil error:err];
}

- (void)onCancelTapped {
    [self cancelSessionExternally];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self cancelSessionExternally];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.spinner startAnimating];
    if (webView.URL.host.length > 0) {
        self.navigationItem.title = webView.URL.host;
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    if (webView.title.length > 0) {
        self.navigationItem.title = webView.title;
    } else if (webView.URL.host.length > 0) {
        self.navigationItem.title = webView.URL.host;
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    BOOL matched = NO;
    if (url) {
        if (self.callbackObj && [self.callbackObj respondsToSelector:@selector(matchesURL:)]) {
            matched = [self.callbackObj matchesURL:url];
        } else if (self.callbackScheme.length > 0 && url.scheme.length > 0) {
            matched = ([url.scheme caseInsensitiveCompare:self.callbackScheme] == NSOrderedSame);
        }
    }
    if (matched) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self finishWithURL:url error:nil];
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end

@implementation ASWebAuthenticationSession (LCAuthHook)

- (instancetype)hook_lc_initWithURL:(NSURL *)URL callbackURLScheme:(NSString *)callbackURLScheme completionHandler:(ASWebAuthenticationSessionCompletionHandler)completionHandler {
    id inst = [self hook_lc_initWithURL:URL callbackURLScheme:callbackURLScheme completionHandler:completionHandler];
    if (inst) {
        objc_setAssociatedObject(inst, &kLCAuthURLKey, URL, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(inst, &kLCAuthCallbackSchemeKey, callbackURLScheme, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(inst, &kLCAuthCompletionKey, completionHandler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return inst;
}

- (instancetype)hook_lc_initWithURL:(NSURL *)URL callback:(ASWebAuthenticationSessionCallback *)callback completionHandler:(ASWebAuthenticationSessionCompletionHandler)completionHandler {
    id inst = [self hook_lc_initWithURL:URL callback:callback completionHandler:completionHandler];
    if (inst) {
        objc_setAssociatedObject(inst, &kLCAuthURLKey, URL, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(inst, &kLCAuthCallbackObjKey, callback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(inst, &kLCAuthCompletionKey, completionHandler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return inst;
}

- (BOOL)hook_lc_start {
    NSURL *authURL = objc_getAssociatedObject(self, &kLCAuthURLKey);
    NSString *scheme = objc_getAssociatedObject(self, &kLCAuthCallbackSchemeKey);
    ASWebAuthenticationSessionCallback *cbObj = objc_getAssociatedObject(self, &kLCAuthCallbackObjKey);
    ASWebAuthenticationSessionCompletionHandler completion = objc_getAssociatedObject(self, &kLCAuthCompletionKey);

    if (completion && LCShouldInterceptAuthSession(authURL, scheme, cbObj)) {
        BOOL cancelledBeforeStart = [objc_getAssociatedObject(self, &kLCAuthInProcessCancelledKey) boolValue];
        if (cancelledBeforeStart) {
            return NO;
        }
        BOOL ephemeral = [self respondsToSelector:@selector(prefersEphemeralWebBrowserSession)] ? self.prefersEphemeralWebBrowserSession : NO;
        NSDictionary<NSString *, NSString *> *extraHeaders = [self respondsToSelector:@selector(additionalHeaderFields)] ? self.additionalHeaderFields : nil;
        id<ASWebAuthenticationPresentationContextProviding> provider = [self respondsToSelector:@selector(presentationContextProvider)] ? self.presentationContextProvider : nil;

        void (^presentBlock)(void) = ^{
            if ([objc_getAssociatedObject(self, &kLCAuthInProcessCancelledKey) boolValue]) {
                return;
            }
            UIWindow *anchor = nil;
            if (provider && [provider respondsToSelector:@selector(presentationAnchorForWebAuthenticationSession:)]) {
                anchor = [provider presentationAnchorForWebAuthenticationSession:self];
            }
            UIWindow *targetWindow = anchor ?: LCKeyWindowForScene(LCForegroundWindowScene());
            UIViewController *presenter = targetWindow.rootViewController;
            while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
                presenter = presenter.presentedViewController;
            }
            if (!presenter) {
                NSError *err = [NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain
                                                   code:ASWebAuthenticationSessionErrorCodePresentationContextNotProvided
                                               userInfo:nil];
                completion(nil, err);
                return;
            }
            LCWebAuthSessionViewController *authVC = [[LCWebAuthSessionViewController alloc] init];
            authVC.initialURL = authURL;
            authVC.callbackScheme = scheme;
            authVC.callbackObj = cbObj;
            authVC.prefersEphemeral = ephemeral;
            authVC.additionalHeaders = extraHeaders;
            authVC.completionBlock = completion;
            authVC.ownerSession = self;

            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authVC];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            nav.presentationController.delegate = authVC;
            objc_setAssociatedObject(self, &kLCAuthActiveVCKey, authVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [presenter presentViewController:nav animated:YES completion:nil];
        };
        if (NSThread.isMainThread) {
            presentBlock();
        } else {
            dispatch_async(dispatch_get_main_queue(), presentBlock);
        }
        return YES;
    }

    return [self hook_lc_start];
}

- (void)hook_lc_cancel {
    objc_setAssociatedObject(self, &kLCAuthInProcessCancelledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LCWebAuthSessionViewController *activeVC = objc_getAssociatedObject(self, &kLCAuthActiveVCKey);
    if (activeVC) {
        if (NSThread.isMainThread) {
            [activeVC cancelSessionExternally];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [activeVC cancelSessionExternally];
            });
        }
        return;
    }
    [self hook_lc_cancel];
}

@end

static void LCInstallWebAuthSessionHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class asClass = ASWebAuthenticationSession.class;
        if (asClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            LCSwizzleIfPresent(asClass, @selector(initWithURL:callbackURLScheme:completionHandler:), @selector(hook_lc_initWithURL:callbackURLScheme:completionHandler:));
#pragma clang diagnostic pop
            LCSwizzleIfPresent(asClass, @selector(initWithURL:callback:completionHandler:), @selector(hook_lc_initWithURL:callback:completionHandler:));
            LCSwizzleIfPresent(asClass, @selector(start), @selector(hook_lc_start));
            LCSwizzleIfPresent(asClass, @selector(cancel), @selector(hook_lc_cancel));
        }
        Class sfClass = objc_lookUpClass("SFAuthenticationSession");
        if (sfClass && ![sfClass isSubclassOfClass:asClass]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            SEL initSel = @selector(initWithURL:callbackURLScheme:completionHandler:);
            SEL hookInitSel = @selector(hook_lc_initWithURL:callbackURLScheme:completionHandler:);
#pragma clang diagnostic pop
            LCSwizzleIfPresentWithSourceClass(sfClass, asClass, initSel, hookInitSel);
            LCSwizzleIfPresentWithSourceClass(sfClass, asClass, @selector(start), @selector(hook_lc_start));
            LCSwizzleIfPresentWithSourceClass(sfClass, asClass, @selector(cancel), @selector(hook_lc_cancel));
        }
    });
}

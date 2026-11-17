//
//  LCDeviceProfileCatalog.h
//  LiveContainer
//
//  Canonical hardware specification catalog and shared feature-default policy
//  used across LiveContainer UI (Swift) and TweakLoader runtime hooks (ObjC).
//

#ifndef LC_DEVICE_PROFILE_CATALOG_H
#define LC_DEVICE_PROFILE_CATALOG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#pragma clang assume_nonnull begin

/**
 Immutable description of a verified Apple hardware configuration.

 Every entry pairs a `hw.machine` identifier with its matching `hw.model` board
 configuration, SoC core/memory envelope, Metal GPU device string, display point
 and pixel geometry, trait size classes, safe-area insets, and minimum OS major
 release so spoofed profiles remain internally coherent across C, UIKit, Metal,
 and WebKit APIs.
 */
typedef struct LCDeviceHardwareSpec {
    /** Stable key identifying this catalog variant (e.g. `"iphone-duo-unfolded"`). */
    const char *variantId;
    /** Human-readable Apple product name shown in pickers and presets. */
    const char *marketingName;
    /** Kernel `hw.machine` / `utsname.machine` value (e.g. `"iPhone19,3"`). */
    const char *hwMachine;
    /** Kernel `hw.model` / `hw.target` board configuration (e.g. `"V64AP"`). */
    const char *hwModel;
    /** High-level `UIDevice.model` string (`"iPhone"` or `"iPad"`). */
    const char *deviceModel;
    /** Expected `MTLDevice.name` GPU identifier (e.g. `"Apple A20 Pro GPU"`). */
    const char *gpuName;
    /** Total CPU core count reported by `sysctl` and `NSProcessInfo`. */
    int32_t cpuCores;
    /** Physical memory size in gibibytes (multiplied by `1024^3` for bytes). */
    uint32_t physicalMemoryGB;
    /** Representative Metal `recommendedMaxWorkingSetSize` in gibibytes. */
    uint32_t gpuWorkingSetGB;
    /** Whether the Metal GPU supports hardware ray tracing (`supportsRaytracing`). */
    bool supportsRayTracing;
    /** Native display width in physical pixels (`UIScreen.nativeBounds.width`). */
    double pixelWidth;
    /** Native display height in physical pixels (`UIScreen.nativeBounds.height`). */
    double pixelHeight;
    /** Logical display width in points (`UIScreen.bounds.width`). */
    double pointWidth;
    /** Logical display height in points (`UIScreen.bounds.height`). */
    double pointHeight;
    /** Logical UIKit rendering scale (`UIScreen.scale`). */
    double scale;
    /** Native physical pixel-to-point ratio (`UIScreen.nativeScale`). */
    double nativeScale;
    /** Maximum display refresh rate (`60` or `120` Hz). */
    int32_t maxFPS;
    /** Default portrait `UITraitCollection.horizontalSizeClass` (`1`=Compact, `2`=Regular). */
    int32_t horizontalSizeClass;
    /** Default portrait `UITraitCollection.verticalSizeClass` (`1`=Compact, `2`=Regular). */
    int32_t verticalSizeClass;
    /** Target `UIUserInterfaceIdiom` (`0`=Phone, `1`=Pad). */
    int32_t userInterfaceIdiom;
    /** Default portrait top safe-area inset in points. */
    double safeAreaTop;
    /** Default portrait bottom safe-area inset in points. */
    double safeAreaBottom;
    /** Earliest public iOS/iPadOS major version shipped for this hardware. */
    int32_t minOSMajor;
} LCDeviceHardwareSpec;

/**
 Returns the internal catalog array and its element count.

 Storing the static table inside a `static inline` function avoids
 unused-variable diagnostics across translation units that only query helpers.
 */
static inline const LCDeviceHardwareSpec *LCDeviceHardwareTable(size_t *outCount) {
    static const LCDeviceHardwareSpec kCatalog[] = {
        // 2026–2027 Flagship & Foldable Series (A20 Pro / iOS 27+)
        {
            "iphone18-pro-max", "iPhone 18 Pro Max", "iPhone19,3", "V64AP", "iPhone", "Apple A20 Pro GPU",
            6, 12, 8, true, 1320.0, 2868.0, 440.0, 956.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 27
        },
        {
            "iphone18-pro", "iPhone 18 Pro", "iPhone19,2", "V63AP", "iPhone", "Apple A20 Pro GPU",
            6, 12, 8, true, 1206.0, 2622.0, 402.0, 874.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 27
        },
        {
            "iphone-duo-unfolded", "iPhone Duo (Unfolded 7.6\")", "iPhone19,4", "V68AP", "iPhone", "Apple A20 Pro GPU",
            6, 12, 8, true, 1878.0, 2670.0, 669.0, 951.0, 3.0, 1878.0 / 669.0, 120, 2, 2, 0, 59.0, 34.0, 27
        },
        {
            "iphone-duo-cover", "iPhone Duo (Cover 5.4\")", "iPhone19,4", "V68AP", "iPhone", "Apple A20 Pro GPU",
            6, 12, 8, true, 1398.0, 2034.0, 466.0, 678.0, 3.0, 3.0, 120, 1, 2, 0, 59.0, 34.0, 27
        },

        // 2025–2026 iPhone 17 & Air Series (A19 / A19 Pro / iOS 26+)
        {
            "iphone-air", "iPhone Air", "iPhone18,4", "D23AP", "iPhone", "Apple A19 Pro GPU",
            6, 12, 8, true, 1260.0, 2736.0, 420.0, 912.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 26
        },
        {
            "iphone17-pro-max", "iPhone 17 Pro Max", "iPhone18,2", "V54AP", "iPhone", "Apple A19 Pro GPU",
            6, 12, 8, true, 1320.0, 2868.0, 440.0, 956.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 26
        },
        {
            "iphone17-pro", "iPhone 17 Pro", "iPhone18,1", "V53AP", "iPhone", "Apple A19 Pro GPU",
            6, 12, 8, true, 1206.0, 2622.0, 402.0, 874.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 26
        },
        {
            "iphone17", "iPhone 17", "iPhone18,3", "V57AP", "iPhone", "Apple A19 GPU",
            6, 8, 6, true, 1206.0, 2622.0, 402.0, 874.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 26
        },
        {
            "iphone17e", "iPhone 17e", "iPhone18,5", "V159AP", "iPhone", "Apple A19 GPU",
            6, 8, 6, true, 1170.0, 2532.0, 390.0, 844.0, 3.0, 3.0, 60, 1, 2, 0, 47.0, 34.0, 26
        },

        // iPhone 16 Series (A18 / A18 Pro / iOS 18+)
        {
            "iphone16-pro-max", "iPhone 16 Pro Max", "iPhone17,2", "D94AP", "iPhone", "Apple A18 Pro GPU",
            6, 8, 6, true, 1320.0, 2868.0, 440.0, 956.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 18
        },
        {
            "iphone16-pro", "iPhone 16 Pro", "iPhone17,1", "D93AP", "iPhone", "Apple A18 Pro GPU",
            6, 8, 6, true, 1206.0, 2622.0, 402.0, 874.0, 3.0, 3.0, 120, 1, 2, 0, 62.0, 34.0, 18
        },
        {
            "iphone16-plus", "iPhone 16 Plus", "iPhone17,4", "D48AP", "iPhone", "Apple A18 GPU",
            6, 8, 6, true, 1290.0, 2796.0, 430.0, 932.0, 3.0, 3.0, 60, 1, 2, 0, 59.0, 34.0, 18
        },
        {
            "iphone16", "iPhone 16", "iPhone17,3", "D47AP", "iPhone", "Apple A18 GPU",
            6, 8, 6, true, 1179.0, 2556.0, 393.0, 852.0, 3.0, 3.0, 60, 1, 2, 0, 59.0, 34.0, 18
        },
        {
            "iphone16e", "iPhone 16e", "iPhone17,5", "V59AP", "iPhone", "Apple A18 GPU",
            6, 8, 6, true, 1170.0, 2532.0, 390.0, 844.0, 3.0, 3.0, 60, 1, 2, 0, 47.0, 34.0, 18
        },

        // iPhone 15 Series
        {
            "iphone15-pro-max", "iPhone 15 Pro Max", "iPhone16,2", "D84AP", "iPhone", "Apple A17 Pro GPU",
            6, 8, 6, true, 1290.0, 2796.0, 430.0, 932.0, 3.0, 3.0, 120, 1, 2, 0, 59.0, 34.0, 17
        },
        {
            "iphone15-pro", "iPhone 15 Pro", "iPhone16,1", "D83AP", "iPhone", "Apple A17 Pro GPU",
            6, 8, 6, true, 1179.0, 2556.0, 393.0, 852.0, 3.0, 3.0, 120, 1, 2, 0, 59.0, 34.0, 17
        },
        {
            "iphone15-plus", "iPhone 15 Plus", "iPhone15,5", "D38AP", "iPhone", "Apple A16 GPU",
            6, 6, 4, false, 1290.0, 2796.0, 430.0, 932.0, 3.0, 3.0, 60, 1, 2, 0, 59.0, 34.0, 17
        },
        {
            "iphone15", "iPhone 15", "iPhone15,4", "D37AP", "iPhone", "Apple A16 GPU",
            6, 6, 4, false, 1179.0, 2556.0, 393.0, 852.0, 3.0, 3.0, 60, 1, 2, 0, 59.0, 34.0, 17
        },

        // iPhone 14 Series
        {
            "iphone14-pro-max", "iPhone 14 Pro Max", "iPhone15,3", "D74AP", "iPhone", "Apple A16 GPU",
            6, 6, 4, false, 1290.0, 2796.0, 430.0, 932.0, 3.0, 3.0, 120, 1, 2, 0, 59.0, 34.0, 16
        },
        {
            "iphone14-pro", "iPhone 14 Pro", "iPhone15,2", "D73AP", "iPhone", "Apple A16 GPU",
            6, 6, 4, false, 1179.0, 2556.0, 393.0, 852.0, 3.0, 3.0, 120, 1, 2, 0, 59.0, 34.0, 16
        },
        {
            "iphone14-plus", "iPhone 14 Plus", "iPhone14,8", "D28AP", "iPhone", "Apple A15 GPU",
            6, 6, 4, false, 1284.0, 2778.0, 428.0, 926.0, 3.0, 3.0, 60, 1, 2, 0, 47.0, 34.0, 16
        },
        {
            "iphone14", "iPhone 14", "iPhone14,7", "D27AP", "iPhone", "Apple A15 GPU",
            6, 6, 4, false, 1170.0, 2532.0, 390.0, 844.0, 3.0, 3.0, 60, 1, 2, 0, 47.0, 34.0, 16
        },

        // iPad Pro & Air Series
        {
            "ipad-pro-m5-13", "iPad Pro M5 13\"", "iPad17,3", "J820AP", "iPad", "Apple M5 GPU",
            9, 12, 8, true, 2064.0, 2752.0, 1032.0, 1376.0, 2.0, 2.0, 120, 2, 2, 1, 24.0, 20.0, 26
        },
        {
            "ipad-pro-m5-11", "iPad Pro M5 11\"", "iPad17,1", "J817AP", "iPad", "Apple M5 GPU",
            9, 12, 8, true, 1668.0, 2420.0, 834.0, 1210.0, 2.0, 2.0, 120, 2, 2, 1, 24.0, 20.0, 26
        },
        {
            "ipad-pro-m4-13", "iPad Pro M4 13\"", "iPad16,5", "J720AP", "iPad", "Apple M4 GPU",
            9, 8, 6, true, 2064.0, 2752.0, 1032.0, 1376.0, 2.0, 2.0, 120, 2, 2, 1, 24.0, 20.0, 17
        },
        {
            "ipad-pro-m4-11", "iPad Pro M4 11\"", "iPad16,3", "J717AP", "iPad", "Apple M4 GPU",
            9, 8, 6, true, 1668.0, 2420.0, 834.0, 1210.0, 2.0, 2.0, 120, 2, 2, 1, 24.0, 20.0, 17
        },
        {
            "ipad-air-m2-13", "iPad Air M2 13\"", "iPad14,10", "J617AP", "iPad", "Apple M2 GPU",
            8, 8, 6, false, 2048.0, 2732.0, 1024.0, 1366.0, 2.0, 2.0, 60, 2, 2, 1, 24.0, 20.0, 17
        },
        {
            "ipad-air-m2-11", "iPad Air M2 11\"", "iPad14,8", "J607AP", "iPad", "Apple M2 GPU",
            8, 8, 6, false, 1640.0, 2360.0, 820.0, 1180.0, 2.0, 2.0, 60, 2, 2, 1, 24.0, 20.0, 17
        }
    };
    *outCount = sizeof(kCatalog) / sizeof(kCatalog[0]);
    return kCatalog;
}

/** Returns the total number of verified hardware entries in the catalog. */
static inline size_t LCDeviceHardwareSpecCount(void) {
    size_t count = 0;
    (void)LCDeviceHardwareTable(&count);
    return count;
}

/** Returns the catalog entry at `index`, or `NULL` if out of range. */
static inline const LCDeviceHardwareSpec * _Nullable LCDeviceHardwareSpecAt(size_t index) {
    size_t count = 0;
    const LCDeviceHardwareSpec *table = LCDeviceHardwareTable(&count);
    if (index >= count) {
        return NULL;
    }
    return &table[index];
}

/** Finds a hardware entry by its unique `variantId` (e.g. `"iphone-duo-unfolded"`). */
static inline const LCDeviceHardwareSpec * _Nullable LCDeviceHardwareSpecFindByVariant(const char * _Nullable variantId) {
    if (!variantId || variantId[0] == '\0') {
        return NULL;
    }
    size_t count = 0;
    const LCDeviceHardwareSpec *table = LCDeviceHardwareTable(&count);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(table[i].variantId, variantId) == 0) {
            return &table[i];
        }
    }
    return NULL;
}

/**
 Finds the first catalog entry matching `hwMachine` (e.g. `"iPhone19,3"`).
 For dual-screen devices sharing a `hw.machine` (such as iPhone Duo `iPhone19,4`),
 prefer `LCDeviceHardwareSpecFindByVariant` first when a variant ID is available.
 */
static inline const LCDeviceHardwareSpec * _Nullable LCDeviceHardwareSpecFindByMachine(const char * _Nullable hwMachine) {
    if (!hwMachine || hwMachine[0] == '\0') {
        return NULL;
    }
    size_t count = 0;
    const LCDeviceHardwareSpec *table = LCDeviceHardwareTable(&count);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(table[i].hwMachine, hwMachine) == 0) {
            return &table[i];
        }
    }
    return NULL;
}

/**
 Maps an iOS/iPadOS major version (`16`, `17`, `18`, `26`, `27`, ...) to the
 corresponding XNU Darwin kernel major release (`22`, `23`, `24`, `25`, `26`, ...).
 */
static inline int32_t LCExpectedDarwinMajorForOSMajor(int32_t osMajor) {
    if (osMajor >= 26) {
        return osMajor - 1;
    }
    if (osMajor >= 1) {
        return osMajor + 6;
    }
    return 26;
}

/**
 Safe default policy for granular per-feature spoof overrides (`spoofFeatureOverrides`).

 Destructive or app-breaking toggles (such as dropping `nw_path_monitor_start`
 reachability callbacks, emptying `UIFont.familyNames`, forcing all permissions to
 Denied, zeroing sensors, or reporting all `MTLGPUFamily` flags true) default to
 `false` unless explicitly enabled by the user or a high-isolation preset.
 */
static inline bool LCDefaultFeatureFlagEnabled(const char *key) {
    if (!key || key[0] == '\0') {
        return true;
    }
    static const char *const kOptInKeys[] = {
        "network.pathMonitor",
        "network.interfaces",
        "network.serviceDiscovery",
        "app.fonts",
        "app.voices",
        "audio.routes",
        "audio.availableInputs",
        "locale.inputModes",
        "graphics.allFamilies",
        "web.canvas"
    };
    for (size_t i = 0; i < sizeof(kOptInKeys) / sizeof(kOptInKeys[0]); i++) {
        if (strcmp(key, kOptInKeys[i]) == 0) {
            return false;
        }
    }
    if (strncmp(key, "sensors.", 8) == 0 || strncmp(key, "permissions.", 12) == 0) {
        return false;
    }
    return true;
}

#pragma clang assume_nonnull end

#endif /* LC_DEVICE_PROFILE_CATALOG_H */

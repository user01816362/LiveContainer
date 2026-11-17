//
//  Tweaks.h
//  LiveContainer
//
//  Created by s s on 2025/2/7.
//

#ifndef LC_TWEAKS_H
#define LC_TWEAKS_H

#import <Foundation/Foundation.h>
#include <mach-o/loader.h>

#import "../utils.h"
bool performHookDyldApi(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction);

void NUDGuestHooksInit(void);
void SecItemGuestHooksInit(void);
void DyldHooksInit(bool hideLiveContainer, bool hookDlopen, uint32_t spoofSDKVersion);
void NSFMGuestHooksInit(void);
void NSFMGuestExtensionHooksInit(NSString *parentContainerPath);
void NSURLSCGuestHooksInit(void);
void initDead10ccFix(void);
void IDFVHookInit(NSUUID* uuid);
void NSExtensionGuestHooksInit(NSURL *appURL, NSURL *containerURL);
void GuestExtensionHooksInit(void);
void LCStealthHideInit(void);
bool LCStealthIsHiddenPath(const char *path);
bool LCStealthIsInternalAddress(const void *addr);

@interface NSBundle(LiveContainer)
- (instancetype)initWithPathForMainBundle:(NSString *)path;
@end


extern uint32_t appMainImageIndex;
extern const char *lcMainBundlePath;
extern const char *lcGuestExecutablePath;
extern uint32_t (*orig_dyld_image_count)(void);
extern const struct mach_header* (*orig_dyld_get_image_header)(uint32_t image_index);
extern intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t image_index);
extern const char* (*orig_dyld_get_image_name)(uint32_t image_index);
extern void* appExecutableHandle;
extern bool tweakLoaderLoaded;
void* getGuestAppHeader(void);
void* getDSCAddr(void);
void* getCachedSymbol(NSString* symbolName, struct mach_header_64* header);
void saveCachedSymbol(NSString* symbolName, struct mach_header_64* header, uint64_t offset);
void* dlopen_nolock(const char *path, int mode);
void bypass_seg_count_check(void (^block)(void));

static inline void hook_do_nothing(void) {}

#endif /* LC_TWEAKS_H */

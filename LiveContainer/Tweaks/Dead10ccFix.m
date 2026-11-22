//
//  Dead10ccFix.m
//  LiveContainer
//
//  Created by s s on 2025/5/21.
//
#include <sys/xattr.h>
#include "utils.h"
#include <unistd.h>
#include "./libproc.h"
#include <sys/stat.h>
#include "./proc_info.h"
#include <fcntl.h>
#include <spawn.h>
#include <dlfcn.h>
@import Foundation;

//extern int _sqlite3_lockstate(const char *path, int pid);

static const NSInteger kDead10ccMaxBackgroundRescans = 2;

@interface Dead10ccFix : NSObject
@property(nonatomic) BOOL methodInited;
@property(nonatomic) int deboundeToken;
@property(nonatomic) NSInteger backgroundRescanCount;
@property(nonatomic, strong) dispatch_queue_t lockScanQueue;
- (void)handleAppDidEnterBackground:(NSNotification *)notification;
- (void)handleAppDidBecomeActive:(NSNotification *)notification;
@end

@interface Dead10ccFix (RuntimeStolen)
- (void)_handleTaskCompletionAndTerminate:(id)arg1;
@end
@interface UIApplication : NSObject
@property (nonatomic, readonly) NSTimeInterval backgroundTimeRemaining;
+ (instancetype)sharedApplication;
- (int)applicationState;
- (NSUInteger)beginBackgroundTaskWithName:(NSString *)taskName expirationHandler:(void (^)(void))handler;
- (void)endBackgroundTask:(NSUInteger)identifier;
@end

Dead10ccFix* fix = nil;

/**
 Initializes RunningBoard lock-file background tagging (`0xdead10cc` prevention).

 Registers both `NSExtensionHostDidEnterBackgroundNotification` and
 `UIApplicationDidEnterBackgroundNotification` because iOS 27 scene hosting
 (`_UISceneHostingController`) inside `LiveProcess` can deliver either lifecycle
 notification when backgrounding.
 */
void initDead10ccFix(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fix = [[Dead10ccFix alloc] init];
        // Note on LiveProcess: depending on Scene API, it could invoke either of these, so register both.
        [NSNotificationCenter.defaultCenter addObserver:fix selector:@selector(handleAppDidEnterBackground:) name:NSExtensionHostDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:fix selector:@selector(handleAppDidEnterBackground:) name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:fix selector:@selector(handleAppDidBecomeActive:) name:NSExtensionHostDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:fix selector:@selector(handleAppDidBecomeActive:) name:@"UIApplicationDidBecomeActiveNotification" object:nil];
    });
}

@implementation Dead10ccFix

- (instancetype)init {
    self = [super init];
    if (self) {
        _lockScanQueue = dispatch_queue_create("com.kdt.livecontainer.dead10cc", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)performLockScan {
    @autoreleasepool {
        NSSet *locks = [self _lock_lockedFilePathsIgnoring:[NSMutableSet set]];
        for (NSString *path in locks) {
            unsigned char value = 0x01;
            setxattr([path UTF8String], "com.apple.runningboard.can-suspend-locked", &value, sizeof(value), 0, 0);
        }
    }
}

- (void)handleAppDidEnterBackgroundReal {
    UIApplication *app = [NSClassFromString(@"UIApplication") sharedApplication];
    if (app &&
        [app respondsToSelector:@selector(beginBackgroundTaskWithName:expirationHandler:)] &&
        [app respondsToSelector:@selector(endBackgroundTask:)]) {
        __block NSUInteger bgTaskID = 0; // UIBackgroundTaskInvalid
        void (^endTaskOnMain)(void) = ^{
            dispatch_block_t finish = ^{
                NSUInteger taskToEnd = bgTaskID;
                bgTaskID = 0;
                if (taskToEnd != 0) {
                    [app endBackgroundTask:taskToEnd];
                }
            };
            if ([NSThread isMainThread]) {
                finish();
            } else {
                dispatch_async(dispatch_get_main_queue(), finish);
            }
        };
        bgTaskID = [app beginBackgroundTaskWithName:@"com.kdt.livecontainer.dead10cc" expirationHandler:^{
            endTaskOnMain();
        }];
        if (bgTaskID != 0) {
            dispatch_async(self.lockScanQueue, ^{
                [self performLockScan];
                endTaskOnMain();
            });
            return;
        }
    }
    dispatch_sync(self.lockScanQueue, ^{
        [self performLockScan];
    });
}

// https://gist.github.com/JJTech0130/07e2458df592faad1d2ba72283a0ca50
- (NSMutableSet *)_lock_lockedFilePathsIgnoring: (NSMutableSet *)ignoring {
    int pid = getpid();
    int pidinfo_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (pidinfo_size <= 0) {
        return nil;
    }

    void *pidinfo = malloc(pidinfo_size);
    if (!pidinfo) {
        return nil;
    }
    pidinfo_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, pidinfo, pidinfo_size);
    if (pidinfo_size <= 0) {
        free(pidinfo);
        return nil;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *openFileFds = [NSMutableDictionary dictionary];

    if (pidinfo_size >= (int)sizeof(struct proc_fdinfo)) {
        uint64_t count = (uint64_t)pidinfo_size / sizeof(struct proc_fdinfo);
        struct proc_fdinfo *fdinfo = (struct proc_fdinfo *)pidinfo;

        for (uint64_t i = 0; i < count; i++) {
            struct proc_fdinfo *entry = &fdinfo[i];
            if (entry->proc_fdtype == PROX_FDTYPE_VNODE) {
                struct vnode_fdinfowithpath vnodeinfo = {0};
                int vnodeinfo_size = proc_pidfdinfo(pid, entry->proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeinfo, sizeof(vnodeinfo));
                if (vnodeinfo_size <= 0 || vnodeinfo_size < (int)sizeof(vnodeinfo)) {
                    continue;
                }

                size_t pathlen = strnlen(vnodeinfo.pvip.vip_path, sizeof(vnodeinfo.pvip.vip_path));
                if (pathlen == 0 || pathlen == sizeof(vnodeinfo.pvip.vip_path)) {
                    continue;
                }

                NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:vnodeinfo.pvip.vip_path length:pathlen];
                if (path == nil) {
                    continue;
                }

                path = [path stringByStandardizingPath];
                NSMutableArray<NSNumber *> *fds = openFileFds[path];
                if (!fds) {
                    fds = [NSMutableArray array];
                    openFileFds[path] = fds;
                }
                [fds addObject:@(entry->proc_fd)];
            }
        }
    }
    free(pidinfo);

    NSMutableSet *lockedFilePaths = [NSMutableSet set];

    for (NSString *path in openFileFds) {
        char *path_c = (char *)[path UTF8String];
        struct stat statbuf;
        if (stat(path_c, &statbuf) != 0) {
            continue;
        }

        if ((statbuf.st_mode & S_IFMT) != S_IFREG) {
            continue;
        }

        BOOL shouldIgnore = NO;
        for (NSString *ignoringPath in ignoring) {
            if ([path hasPrefix:ignoringPath]) {
                shouldIgnore = YES;
                break;
            }
        }
        if (shouldIgnore) {
            continue;
        }

        if ([path hasSuffix:@"-shm"] || [path hasSuffix:@"-wal"] || [path hasSuffix:@"-journal"]) {
            continue;
        }

        if (getxattr(path_c, "com.apple.runningboard.can-suspend-locked", NULL, 0, 0, 0) == 1) {
            char value = 0;
            getxattr(path_c, "com.apple.runningboard.can-suspend-locked", &value, sizeof(value), 0, 0);
            if (value != 0) {
                continue;
            }
        }
        static int (*sqlite3LockStateFn)(char*, int) = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            sqlite3LockStateFn = dlsym(RTLD_DEFAULT, "_sqlite3_lockstate");
        });
        int sqlite_lock = sqlite3LockStateFn ? sqlite3LockStateFn(path_c, pid) : -1;
        if (sqlite_lock == 0) {
            continue;
        }

        if (sqlite_lock == 1) {
            [lockedFilePaths addObject:path];
        } else {
            // Query lock status using existing open FDs rather than open()+close(), which drops POSIX fcntl locks process-wide
            for (NSNumber *fdNum in openFileFds[path]) {
                struct flock fl;
                memset(&fl, 0, sizeof(fl));
                fl.l_type = F_WRLCK;
                fl.l_pid = pid;

                int lock = fcntl(fdNum.intValue, F_GETLKPID, &fl);
                if (lock != -1 && (fl.l_type == F_RDLCK || fl.l_type == F_WRLCK)) {
                    [lockedFilePaths addObject:path];
                    break;
                }
            }
        }
    }

    return lockedFilePaths;
}

- (void)handleAppDidBecomeActive:(NSNotification *)notification {
    dispatch_block_t activeBlock = ^{
        self.deboundeToken += 1;
        self.backgroundRescanCount = 0;
    };
    if ([NSThread isMainThread]) {
        activeBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), activeBlock);
    }
}

- (void)handleAppDidEnterBackground:(NSNotification *)notification {
    dispatch_block_t handleBlock = ^{
        self.backgroundRescanCount = 0;
        if(!self->_methodInited) {
            self->_methodInited = YES;
            // hack: steal -[UIApplication _handleTaskCompletionAndTerminate:]
            Class class = NSClassFromString(@"UIApplication");
            SEL sel = @selector(_handleTaskCompletionAndTerminate:);
            Method method = class_getInstanceMethod(class, sel);
            if(method) {
                class_addMethod(Dead10ccFix.class, sel, method_getImplementation(method), method_getTypeEncoding(method));
            }
        }
        // this will call _UIApplicationCallWhenBackgroundTaskCountReachesZero which calls _terminateWithStatus: when no background tasks are left
        if ([self respondsToSelector:@selector(_handleTaskCompletionAndTerminate:)]) {
            [self _handleTaskCompletionAndTerminate:self];
        } else {
            [self handleAppDidEnterBackgroundReal];
        }
    };
    if ([NSThread isMainThread]) {
        handleBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), handleBlock);
    }
}

- (void)_terminateWithStatus:(int)status {
    [self handleAppDidEnterBackgroundReal];
    int appState = [[NSClassFromString(@"UIApplication") sharedApplication] applicationState];
    if (appState != 0 && self.backgroundRescanCount < kDead10ccMaxBackgroundRescans) {
        self.backgroundRescanCount += 1;
        int64_t delaySeconds = 2 * self.backgroundRescanCount;
        self.deboundeToken += 1;
        int curToken = self.deboundeToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delaySeconds * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self.deboundeToken != curToken) {
                return;
            }
            if ([[NSClassFromString(@"UIApplication") sharedApplication] applicationState] == 0) {
                return;
            }
            if ([self respondsToSelector:@selector(_handleTaskCompletionAndTerminate:)]) {
                [self _handleTaskCompletionAndTerminate:self];
            } else {
                [self handleAppDidEnterBackgroundReal];
            }
        });
    }
}

- (BOOL)waitForBackgroundTaskCompletion {
    // Fake implementation from UIApplicationSceneTransitionContext for _handleTaskCompletionAndTerminate:
    return YES;
}

@end

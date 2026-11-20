//
//  LCDebugAgent.m
//  TweakLoader
//
//  100% JIT-less in-process live developer instrumentation agent for LiveContainer.
//  Provides unified logging (stdout/stderr with line buffering, NSLog/NSLogv GOT hook,
//  OSLogStore incremental capture, crash/exception/signal capture), non-invasive
//  NSURLSession + WKWebView network inspection, UI/Window/Tab/Navigation/Touch/Notification
//  event hooks, multi-scene view hierarchy + dynamic X-Ray + Tap-to-Inspect, Mach telemetry,
//  a full in-app Liquid Glass floating debugger overlay, and a non-blocking HTTP/SSE
//  local + LAN Web Console server.
//

@import Foundation;
@import UIKit;
@import QuartzCore;
@import Security;
@import OSLog;
@import WebKit;

#include <arpa/inet.h>
#include <dlfcn.h>
#include <dns_sd.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <net/if.h>
#include <netinet/in.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/lock.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#import "../LiveContainer/utils.h"

extern NSDictionary *LCProfileGetTelemetrySnapshot(void);

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif

static _Atomic uint16_t gLCDebugLocalPort = 0;
static _Atomic uint16_t gLCDebugLANPort = 0;
static _Atomic BOOL gLCDebugXRayAtomic = NO;
static _Atomic BOOL gLCDebugNotifMonitorAtomic = NO;
static _Atomic BOOL gLCDebugAgentActive = NO;

static uint32_t (*g_orig_dyld_image_count)(void) = NULL;
static const char *(*g_orig_dyld_get_image_name)(uint32_t) = NULL;
static const struct mach_header *(*g_orig_dyld_get_image_header)(uint32_t) = NULL;

static void (*g_orig_NSLogv)(NSString *format, va_list args) = NULL;
static _Thread_local BOOL gLCInNSLogHook = NO;
static _Thread_local BOOL gLCInNotifHook = NO;
static _Thread_local BOOL gLCInURLSessionTaskCreate = NO;
static _Thread_local BOOL gLCInDidReceiveDataHook = NO;
static _Thread_local BOOL gLCInTabSelectHook = NO;

static char gLCCrashLogPath[PATH_MAX] = {0};

static os_unfair_lock gLCRecentNSLogLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *gLCRecentNSLogMessages = nil;

static void LCRecordRecentNSLogMessage(NSString *msg) {
    if (msg.length == 0) return;
    os_unfair_lock_lock(&gLCRecentNSLogLock);
    if (!gLCRecentNSLogMessages) {
        gLCRecentNSLogMessages = [NSMutableArray arrayWithCapacity:24];
    }
    [gLCRecentNSLogMessages addObject:msg];
    if (gLCRecentNSLogMessages.count > 24) {
        [gLCRecentNSLogMessages removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&gLCRecentNSLogLock);
}

static BOOL LCMatchesRecentNSLogMessage(NSString *msg) {
    if (msg.length == 0) return NO;
    os_unfair_lock_lock(&gLCRecentNSLogLock);
    BOOL found = NO;
    for (NSString *recent in gLCRecentNSLogMessages) {
        if ([msg isEqualToString:recent] || [msg hasSuffix:recent]) {
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&gLCRecentNSLogLock);
    return found;
}

static uint32_t LCDebugImageCount(void) {
    return g_orig_dyld_image_count ? g_orig_dyld_image_count() : _dyld_image_count();
}

static const char *LCDebugImageName(uint32_t idx) {
    return g_orig_dyld_get_image_name ? g_orig_dyld_get_image_name(idx) : _dyld_get_image_name(idx);
}

static const struct mach_header *LCDebugImageHeader(uint32_t idx) {
    return g_orig_dyld_get_image_header ? g_orig_dyld_get_image_header(idx) : _dyld_get_image_header(idx);
}

static BOOL LCDebugSafeSwizzleInstanceMethod(Class cls, SEL originalSel, SEL swizzledSel) {
    if (!cls || !originalSel || !swizzledSel) return NO;
    Method origMethod = class_getInstanceMethod(cls, originalSel);
    Method swizMethod = class_getInstanceMethod(cls, swizzledSel);
    if (!origMethod || !swizMethod) return NO;

    BOOL didAdd = class_addMethod(cls,
                                  originalSel,
                                  method_getImplementation(swizMethod),
                                  method_getTypeEncoding(swizMethod));
    if (didAdd) {
        class_replaceMethod(cls,
                            swizzledSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
    return YES;
}

static BOOL LCDebugIsInternalDebugClass(Class cls) {
    if (!cls) return NO;
    const char *name = class_getName(cls);
    return name && strncmp(name, "LCDebug", 7) == 0;
}

static BOOL LCDebugIsOwnDebugRequestURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) {
        NSNumber *port = url.port;
        if (port) {
            uint16_t reqPort = port.unsignedShortValue;
            uint16_t localPort = atomic_load(&gLCDebugLocalPort);
            uint16_t lanPort = atomic_load(&gLCDebugLANPort);
            if ((localPort > 0 && reqPort == localPort) || (lanPort > 0 && reqPort == lanPort)) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *LCEscapeSingleQuotes(NSString *raw) {
    return [(raw ?: @"") stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

// MARK: - JSON Safety Helper

static id LCSanitizeJSONValue(id obj) {
    if (!obj || obj == (id)kCFNull) {
        return NSNull.null;
    }
    if ([obj isKindOfClass:NSString.class]) {
        return obj;
    }
    if ([obj isKindOfClass:NSNumber.class]) {
        double v = ((NSNumber *)obj).doubleValue;
        if (isnan(v) || isinf(v)) {
            return @(0);
        }
        return obj;
    }
    if ([obj isKindOfClass:NSDate.class]) {
        static NSISO8601DateFormatter *isoFmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            isoFmt = [[NSISO8601DateFormatter alloc] init];
        });
        return [isoFmt stringFromDate:(NSDate *)obj] ?: @"";
    }
    if ([obj isKindOfClass:NSData.class]) {
        NSData *d = (NSData *)obj;
        return [NSString stringWithFormat:@"<Data %lu bytes>", (unsigned long)d.length];
    }
    if ([obj isKindOfClass:NSURL.class]) {
        return ((NSURL *)obj).absoluteString ?: @"";
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:((NSArray *)obj).count];
        for (id item in (NSArray *)obj) {
            [arr addObject:LCSanitizeJSONValue(item)];
        }
        return arr;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:((NSDictionary *)obj).count];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            NSString *keyStr = [key isKindOfClass:NSString.class] ? key : [key description];
            if (keyStr) {
                dict[keyStr] = LCSanitizeJSONValue(val);
            }
        }];
        return dict;
    }
    return [obj description] ?: @"";
}

static NSData *LCJSONDataFromObject(id obj) {
    id safeObj = LCSanitizeJSONValue(obj);
    if (![NSJSONSerialization isValidJSONObject:safeObj]) {
        safeObj = @{ @"value": [obj description] ?: @"" };
    }
    return [NSJSONSerialization dataWithJSONObject:safeObj options:0 error:nil] ?: [NSData dataWithBytes:"{}" length:2];
}

static NSString *LCJSONStringFromObject(id obj) {
    return [[NSString alloc] initWithData:LCJSONDataFromObject(obj) encoding:NSUTF8StringEncoding] ?: @"{}";
}

// MARK: - Networking & Window Helpers

static NSString *LCBestLANIPv4Address(void) {
    int (*real_getifaddrs)(struct ifaddrs **) = (int (*)(struct ifaddrs **))dlsym(RTLD_NEXT, "getifaddrs");
    void (*real_freeifaddrs)(struct ifaddrs *) = (void (*)(struct ifaddrs *))dlsym(RTLD_NEXT, "freeifaddrs");
    struct ifaddrs *interfaces = NULL;
    int rc = real_getifaddrs ? real_getifaddrs(&interfaces) : getifaddrs(&interfaces);
    if (rc != 0 || !interfaces) {
        return nil;
    }
    NSString *wifiIP = nil;
    NSString *fallbackIP = nil;
    for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if (!(cursor->ifa_flags & IFF_UP) || (cursor->ifa_flags & IFF_LOOPBACK)) {
            continue;
        }
        const struct sockaddr_in *addr = (const struct sockaddr_in *)cursor->ifa_addr;
        char ipBuf[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &addr->sin_addr, ipBuf, sizeof(ipBuf))) {
            continue;
        }
        NSString *name = cursor->ifa_name ? @(cursor->ifa_name) : @"";
        NSString *ip = @(ipBuf);
        if ([name isEqualToString:@"en0"] || [name isEqualToString:@"en1"]) {
            wifiIP = ip;
            break;
        }
        if ([name hasPrefix:@"en"] || [name hasPrefix:@"bridge"]) {
            fallbackIP = fallbackIP ?: ip;
        }
    }
    if (real_freeifaddrs) {
        real_freeifaddrs(interfaces);
    } else {
        freeifaddrs(interfaces);
    }
    return wifiIP ?: fallbackIP;
}

static NSArray<UIWindow *> *LCVisibleGuestWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (LCDebugIsInternalDebugClass(win.class)) continue;
            if (!win.isHidden && win.alpha > 0.01) {
                [result addObject:win];
            }
        }
    }
    [result sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel != b.windowLevel) {
            return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.isKeyWindow != b.isKeyWindow) {
            return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return result;
}

static UIWindowScene *LCActiveForegroundWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) {
            return ws;
        }
        if (!fallback && ws.activationState == UISceneActivationStateForegroundInactive) {
            fallback = ws;
        }
        if (!fallback) {
            fallback = ws;
        }
    }
    return fallback;
}

static UIWindow *LCActiveGuestWindow(void) {
    NSArray<UIWindow *> *wins = LCVisibleGuestWindows();
    for (UIWindow *win in wins) {
        if (win.isKeyWindow) return win;
    }
    return wins.firstObject;
}

static NSString *LCBuildCurlCommand(NSURLRequest *req, NSData *overrideBody) {
    if (!req) return @"";
    NSMutableString *curl = [NSMutableString stringWithFormat:@"curl -X %@", req.HTTPMethod ?: @"GET"];
    [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [curl appendFormat:@" -H '%@: %@'", LCEscapeSingleQuotes(k), LCEscapeSingleQuotes(v)];
    }];
    NSData *body = overrideBody ?: req.HTTPBody;
    if (body.length > 0 && body.length <= 4096) {
        NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (bodyStr) {
            [curl appendFormat:@" --data '%@'", LCEscapeSingleQuotes(bodyStr)];
        }
    }
    [curl appendFormat:@" '%@'", LCEscapeSingleQuotes(req.URL.absoluteString ?: @"")];
    return curl;
}

static NSString *LCPreviewStringFromData(NSData *data, NSUInteger maxBytes) {
    if (!data || data.length == 0) return @"";
    NSData *slice = data.length > maxBytes ? [data subdataWithRange:NSMakeRange(0, maxBytes)] : data;
    NSString *utf8 = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (utf8) {
        return data.length > maxBytes
            ? [utf8 stringByAppendingFormat:@"\n… (%lu bytes total)", (unsigned long)data.length]
            : utf8;
    }
    return [NSString stringWithFormat:@"<Binary %lu bytes>", (unsigned long)data.length];
}

// MARK: - Forward Declarations

@interface LCDebugServer : NSObject
+ (instancetype)shared;
- (void)start;
- (void)appendLogStream:(NSString *)stream
                  level:(NSString *)level
              subsystem:(NSString *)subsystem
               category:(NSString *)category
                   text:(NSString *)text;
- (void)appendLogStream:(NSString *)stream text:(NSString *)text;
- (void)recordNetworkEvent:(NSDictionary *)entry;
- (void)recordUIEventKind:(NSString *)kind
                    title:(NSString *)title
                   detail:(NSString *)detail
                   target:(NSString *)target
           viewController:(NSString *)vcName
                   window:(NSString *)windowName;
- (NSDictionary *)currentStatusDictionary;
- (NSArray<NSDictionary *> *)logsSnapshot;
- (NSArray<NSDictionary *> *)networkSnapshot;
- (NSArray<NSDictionary *> *)uiEventsSnapshot;
- (void)clearLogs;
- (void)clearNetwork;
- (void)clearUIEvents;
- (void)setXRayEnabled:(BOOL)enabled;
- (void)setTapInspectEnabled:(BOOL)enabled;
- (void)setNotificationMonitorEnabled:(BOOL)enabled;
- (void)setLANEnabled:(BOOL)enabled;
- (void)simulateMemoryWarning;
- (NSDictionary *)captureViewHierarchy;
- (NSArray *)captureLoadedDylibs;
@end

// MARK: - Non-Invasive NSURLSession Instrumentation (100% JIT-less)

static char kLCDebugTaskContextKey;
static os_unfair_lock gLCDelegateHookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gLCHookedDelegateMethods = nil;

@interface LCDebugNetworkTaskContext : NSObject {
@public
    os_unfair_lock _lock;
    _Atomic BOOL _started;
    _Atomic BOOL _completed;
}
@property (nonatomic, copy) NSString *entryId;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSData *uploadBody;
@property (nonatomic, strong) NSURLResponse *response;
@property (nonatomic, strong) NSMutableData *receivedData;
@property (nonatomic, assign) NSUInteger totalReceivedBytes;
@property (nonatomic, assign) CFAbsoluteTime startTime;
@property (nonatomic, copy) NSString *source;
- (void)markStartedIfNeeded;
- (void)appendChunk:(NSData *)chunk;
- (void)setCapturedResponse:(NSURLResponse *)response;
- (void)snapshotResponse:(NSURLResponse *__autoreleasing *)outResp data:(NSData *__autoreleasing *)outData bytes:(NSUInteger *)outBytes;
@end

@implementation LCDebugNetworkTaskContext

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        atomic_init(&_started, NO);
        atomic_init(&_completed, NO);
        _entryId = NSUUID.UUID.UUIDString;
        _startTime = CFAbsoluteTimeGetCurrent();
        _source = @"urlsession";
    }
    return self;
}

- (void)markStartedIfNeeded {
    if (!atomic_exchange(&_started, YES)) {
        os_unfair_lock_lock(&_lock);
        _startTime = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_unlock(&_lock);
    }
}

- (void)appendChunk:(NSData *)chunk {
    if (chunk.length == 0) return;
    os_unfair_lock_lock(&_lock);
    _totalReceivedBytes += chunk.length;
    if (!_receivedData) {
        _receivedData = [NSMutableData dataWithCapacity:MIN(chunk.length, (NSUInteger)8192)];
    }
    if (_receivedData.length < 16384) {
        NSUInteger remaining = 16384 - _receivedData.length;
        NSUInteger toCopy = MIN(remaining, chunk.length);
        [_receivedData appendBytes:chunk.bytes length:toCopy];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)setCapturedResponse:(NSURLResponse *)response {
    if (!response) return;
    os_unfair_lock_lock(&_lock);
    _response = response;
    os_unfair_lock_unlock(&_lock);
}

- (void)snapshotResponse:(NSURLResponse *__autoreleasing *)outResp data:(NSData *__autoreleasing *)outData bytes:(NSUInteger *)outBytes {
    os_unfair_lock_lock(&_lock);
    if (outResp) *outResp = _response;
    if (outData) *outData = [_receivedData copy];
    if (outBytes) *outBytes = _totalReceivedBytes;
    os_unfair_lock_unlock(&_lock);
}

@end

static LCDebugNetworkTaskContext *LCGetOrCreateTaskContext(NSURLSessionTask *task, NSURLRequest *req, NSData *uploadBody) {
    if (!task) return nil;
    LCDebugNetworkTaskContext *ctx = objc_getAssociatedObject(task, &kLCDebugTaskContextKey);
    if (!ctx) {
        ctx = [[LCDebugNetworkTaskContext alloc] init];
        ctx.request = req ?: task.originalRequest ?: task.currentRequest;
        ctx.uploadBody = uploadBody;
        objc_setAssociatedObject(task, &kLCDebugTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (!ctx.request) {
            ctx.request = req ?: task.originalRequest ?: task.currentRequest;
        }
        if (uploadBody && !ctx.uploadBody) {
            ctx.uploadBody = uploadBody;
        }
    }
    return ctx;
}

static void LCFinalizeNetworkTaskContext(LCDebugNetworkTaskContext *ctx,
                                         NSURLSessionTask *task,
                                         NSURLResponse *response,
                                         NSData *data,
                                         NSError *error) {
    if (!ctx || atomic_exchange(&ctx->_completed, YES)) return;

    NSURLRequest *req = task.currentRequest ?: task.originalRequest ?: ctx.request;
    if (!req || LCDebugIsOwnDebugRequestURL(req.URL)) return;

    NSURLResponse *capturedResp = nil;
    NSData *capturedData = nil;
    NSUInteger capturedBytes = 0;
    [ctx snapshotResponse:&capturedResp data:&capturedData bytes:&capturedBytes];

    NSURLResponse *finalResp = response ?: capturedResp ?: task.response;
    NSData *finalData = data ?: capturedData;
    NSUInteger byteCount = data ? data.length : MAX(capturedBytes, (NSUInteger)MAX((int64_t)0, task.countOfBytesReceived));

    CFAbsoluteTime elapsedMs = MAX(0.0, (CFAbsoluteTimeGetCurrent() - ctx.startTime) * 1000.0);
    NSInteger statusCode = [finalResp isKindOfClass:NSHTTPURLResponse.class]
        ? ((NSHTTPURLResponse *)finalResp).statusCode
        : (error ? -1 : 0);

    NSString *respPreview = finalData.length > 0
        ? LCPreviewStringFromData(finalData, 8192)
        : (error ? (error.localizedDescription ?: @"Request failed") : @"");

    NSData *reqBody = ctx.uploadBody ?: req.HTTPBody;
    NSString *reqBodyPreview = @"";
    if (reqBody.length > 0) {
        reqBodyPreview = LCPreviewStringFromData(reqBody, 4096);
    } else if (req.HTTPBodyStream != nil) {
        reqBodyPreview = @"<Streamed HTTPBodyStream>";
    }

    NSDictionary *respHeaders = [finalResp isKindOfClass:NSHTTPURLResponse.class]
        ? (((NSHTTPURLResponse *)finalResp).allHeaderFields ?: @{})
        : @{};

    [LCDebugServer.shared recordNetworkEvent:@{
        @"id": ctx.entryId ?: NSUUID.UUID.UUIDString,
        @"timestamp": @(CFAbsoluteTimeGetCurrent()),
        @"source": ctx.source ?: @"urlsession",
        @"method": req.HTTPMethod ?: @"GET",
        @"url": req.URL.absoluteString ?: @"",
        @"statusCode": @(statusCode),
        @"mimeType": finalResp.MIMEType ?: @"",
        @"durationMs": @((NSInteger)llround(elapsedMs)),
        @"bytes": @(byteCount),
        @"requestHeaders": req.allHTTPHeaderFields ?: @{},
        @"responseHeaders": respHeaders,
        @"requestBodyPreview": reqBodyPreview,
        @"responseBodyPreview": respPreview,
        @"curl": LCBuildCurlCommand(req, reqBody),
        @"error": error ? (error.localizedDescription ?: @"") : @""
    }];
}

static void LCRecordWebSocketEvent(NSURLRequest *request) {
    if (!request.URL || LCDebugIsOwnDebugRequestURL(request.URL)) return;
    [LCDebugServer.shared recordNetworkEvent:@{
        @"id": NSUUID.UUID.UUIDString,
        @"timestamp": @(CFAbsoluteTimeGetCurrent()),
        @"source": @"websocket",
        @"method": @"WS",
        @"url": request.URL.absoluteString ?: @"",
        @"statusCode": @(101),
        @"mimeType": @"websocket",
        @"durationMs": @(0),
        @"bytes": @(0),
        @"requestHeaders": request.allHTTPHeaderFields ?: @{},
        @"responseHeaders": @{},
        @"requestBodyPreview": @"",
        @"responseBodyPreview": @"WebSocket task created",
        @"curl": LCBuildCurlCommand(request, nil),
        @"error": @""
    }];
}

/// Finds the exact class in `cls`'s hierarchy that defines `sel` directly (not inherited).
static Class LCOwningClassForSelector(Class cls, SEL sel) {
    Class cursor = cls;
    while (cursor) {
        Method m = class_getInstanceMethod(cursor, sel);
        if (!m) return Nil;
        Class superCls = class_getSuperclass(cursor);
        Method superM = superCls ? class_getInstanceMethod(superCls, sel) : NULL;
        if (m != superM) {
            return cursor;
        }
        cursor = superCls;
    }
    return Nil;
}

static BOOL LCMarkDelegateMethodHooked(Class ownerCls, SEL sel) {
    NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(ownerCls), sel_getName(sel)];
    os_unfair_lock_lock(&gLCDelegateHookLock);
    if (!gLCHookedDelegateMethods) {
        gLCHookedDelegateMethods = [NSMutableSet set];
    }
    BOOL already = [gLCHookedDelegateMethods containsObject:key];
    if (!already) {
        [gLCHookedDelegateMethods addObject:key];
    }
    os_unfair_lock_unlock(&gLCDelegateHookLock);
    return !already;
}

static BOOL LCClassOverridesForwarding(Class cls) {
    IMP baseForwardTarget = class_getMethodImplementation(NSObject.class, @selector(forwardingTargetForSelector:));
    IMP baseForwardInvoc = class_getMethodImplementation(NSObject.class, @selector(forwardInvocation:));
    return (class_getMethodImplementation(cls, @selector(forwardingTargetForSelector:)) != baseForwardTarget) ||
           (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != baseForwardInvoc);
}

static void LCHookSessionDelegateClassIfNeeded(id delegate) {
    if (!delegate) return;
    if ([delegate isProxy] || ![delegate isKindOfClass:NSObject.class]) return;
    // Use [delegate class] (not object_getClass) to avoid KVO dynamic NSKVONotifying_* classes
    Class cls = [delegate class];
    if (!cls || LCDebugIsInternalDebugClass(cls) || LCClassOverridesForwarding(cls)) return;

    // 1. Hook URLSession:dataTask:didReceiveData: on its exact owning class (if implemented)
    SEL recvDataSel = @selector(URLSession:dataTask:didReceiveData:);
    Class dataOwner = LCOwningClassForSelector(cls, recvDataSel);
    if (dataOwner && LCMarkDelegateMethodHooked(dataOwner, recvDataSel)) {
        Method m = class_getInstanceMethod(dataOwner, recvDataSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *chunk) {
                BOOL entered = NO;
                if (!gLCInDidReceiveDataHook) {
                    gLCInDidReceiveDataHook = YES;
                    entered = YES;
                    LCDebugNetworkTaskContext *ctx = objc_getAssociatedObject(dataTask, &kLCDebugTaskContextKey);
                    if (ctx) {
                        [ctx appendChunk:chunk];
                    }
                }
                @try {
                    ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))origIMP)(selfObj, recvDataSel, session, dataTask, chunk);
                } @finally {
                    if (entered) gLCInDidReceiveDataHook = NO;
                }
            };
            class_replaceMethod(dataOwner, recvDataSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 2. Hook URLSession:dataTask:didReceiveResponse:completionHandler: on its exact owning class (if implemented)
    SEL recvRespSel = @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    Class respOwner = LCOwningClassForSelector(cls, recvRespSel);
    if (respOwner && LCMarkDelegateMethodHooked(respOwner, recvRespSel)) {
        Method m = class_getInstanceMethod(respOwner, recvRespSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response, void (^completionHandler)(NSURLSessionResponseDisposition)) {
                LCDebugNetworkTaskContext *ctx = objc_getAssociatedObject(dataTask, &kLCDebugTaskContextKey);
                if (ctx && response) {
                    [ctx setCapturedResponse:response];
                }
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition)))origIMP)(selfObj, recvRespSel, session, dataTask, response, completionHandler);
            };
            class_replaceMethod(respOwner, recvRespSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 3. Hook URLSession:task:didCompleteWithError: on its exact owning class (or safely add on non-forwarding NSObject subclass)
    SEL completeSel = @selector(URLSession:task:didCompleteWithError:);
    Class completeOwner = LCOwningClassForSelector(cls, completeSel);
    if (completeOwner) {
        if (LCMarkDelegateMethodHooked(completeOwner, completeSel)) {
            Method completeMethod = class_getInstanceMethod(completeOwner, completeSel);
            if (completeMethod) {
                IMP origIMP = method_getImplementation(completeMethod);
                id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
                    LCDebugNetworkTaskContext *ctx = objc_getAssociatedObject(task, &kLCDebugTaskContextKey);
                    if (ctx) {
                        LCFinalizeNetworkTaskContext(ctx, task, task.response, nil, error);
                    }
                    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))origIMP)(selfObj, completeSel, session, task, error);
                };
                class_replaceMethod(completeOwner, completeSel, imp_implementationWithBlock(block), method_getTypeEncoding(completeMethod));
            }
        }
    } else if (LCMarkDelegateMethodHooked(cls, completeSel)) {
        id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
            LCDebugNetworkTaskContext *ctx = objc_getAssociatedObject(task, &kLCDebugTaskContextKey);
            if (ctx) {
                LCFinalizeNetworkTaskContext(ctx, task, task.response, nil, error);
            }
        };
        class_addMethod(cls, completeSel, imp_implementationWithBlock(block), "v@:@@@");
    }
}

@implementation NSURLSession (LCDebugNetworkSwizzle)

+ (NSURLSession *)lcDebug_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                          delegate:(id<NSURLSessionDelegate>)delegate
                                     delegateQueue:(NSOperationQueue *)queue {
    if (atomic_load(&gLCDebugAgentActive) && delegate) {
        LCHookSessionDelegateClassIfNeeded(delegate);
    }
    return [self lcDebug_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

- (NSURLSessionDataTask *)lcDebug_dataTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!atomic_load(&gLCDebugAgentActive) || gLCInURLSessionTaskCreate || LCDebugIsOwnDebugRequestURL(request.URL)) {
        return [self lcDebug_dataTaskWithRequest:request completionHandler:completionHandler];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        if (!completionHandler) {
            NSURLSessionDataTask *task = [self lcDebug_dataTaskWithRequest:request completionHandler:nil];
            LCGetOrCreateTaskContext(task, request, nil);
            return task;
        }
        LCDebugNetworkTaskContext *ctx = [[LCDebugNetworkTaskContext alloc] init];
        ctx.request = request;
        __block __weak NSURLSessionDataTask *weakTask = nil;
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCFinalizeNetworkTaskContext(ctx, weakTask, response, data, error);
            completionHandler(data, response, error);
        };
        NSURLSessionDataTask *task = [self lcDebug_dataTaskWithRequest:request completionHandler:wrapped];
        weakTask = task;
        objc_setAssociatedObject(task, &kLCDebugTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionDataTask *)lcDebug_dataTaskWithURL:(NSURL *)url
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!atomic_load(&gLCDebugAgentActive) || gLCInURLSessionTaskCreate || LCDebugIsOwnDebugRequestURL(url)) {
        return [self lcDebug_dataTaskWithURL:url completionHandler:completionHandler];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLRequest *req = url ? [NSURLRequest requestWithURL:url] : nil;
        if (!completionHandler) {
            NSURLSessionDataTask *task = [self lcDebug_dataTaskWithURL:url completionHandler:nil];
            LCGetOrCreateTaskContext(task, req, nil);
            return task;
        }
        LCDebugNetworkTaskContext *ctx = [[LCDebugNetworkTaskContext alloc] init];
        ctx.request = req;
        __block __weak NSURLSessionDataTask *weakTask = nil;
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCFinalizeNetworkTaskContext(ctx, weakTask, response, data, error);
            completionHandler(data, response, error);
        };
        NSURLSessionDataTask *task = [self lcDebug_dataTaskWithURL:url completionHandler:wrapped];
        weakTask = task;
        objc_setAssociatedObject(task, &kLCDebugTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionUploadTask *)lcDebug_uploadTaskWithRequest:(NSURLRequest *)request
                                                 fromData:(NSData *)bodyData
                                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!atomic_load(&gLCDebugAgentActive) || gLCInURLSessionTaskCreate || LCDebugIsOwnDebugRequestURL(request.URL)) {
        return [self lcDebug_uploadTaskWithRequest:request fromData:bodyData completionHandler:completionHandler];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        if (!completionHandler) {
            NSURLSessionUploadTask *task = [self lcDebug_uploadTaskWithRequest:request fromData:bodyData completionHandler:nil];
            LCGetOrCreateTaskContext(task, request, bodyData);
            return task;
        }
        LCDebugNetworkTaskContext *ctx = [[LCDebugNetworkTaskContext alloc] init];
        ctx.request = request;
        ctx.uploadBody = bodyData;
        __block __weak NSURLSessionUploadTask *weakTask = nil;
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            LCFinalizeNetworkTaskContext(ctx, weakTask, response, data, error);
            completionHandler(data, response, error);
        };
        NSURLSessionUploadTask *task = [self lcDebug_uploadTaskWithRequest:request fromData:bodyData completionHandler:wrapped];
        weakTask = task;
        objc_setAssociatedObject(task, &kLCDebugTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionDownloadTask *)lcDebug_downloadTaskWithRequest:(NSURLRequest *)request
                                            completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    if (!atomic_load(&gLCDebugAgentActive) || gLCInURLSessionTaskCreate || LCDebugIsOwnDebugRequestURL(request.URL)) {
        return [self lcDebug_downloadTaskWithRequest:request completionHandler:completionHandler];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        if (!completionHandler) {
            NSURLSessionDownloadTask *task = [self lcDebug_downloadTaskWithRequest:request completionHandler:nil];
            LCGetOrCreateTaskContext(task, request, nil);
            return task;
        }
        LCDebugNetworkTaskContext *ctx = [[LCDebugNetworkTaskContext alloc] init];
        ctx.request = request;
        __block __weak NSURLSessionDownloadTask *weakTask = nil;
        void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSString *note = location ? [NSString stringWithFormat:@"<Downloaded to %@>", location.lastPathComponent] : @"";
            NSData *noteData = [note dataUsingEncoding:NSUTF8StringEncoding];
            LCFinalizeNetworkTaskContext(ctx, weakTask, response, noteData, error);
            completionHandler(location, response, error);
        };
        NSURLSessionDownloadTask *task = [self lcDebug_downloadTaskWithRequest:request completionHandler:wrapped];
        weakTask = task;
        objc_setAssociatedObject(task, &kLCDebugTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionDataTask *)lcDebug_dataTaskWithRequest:(NSURLRequest *)request {
    if (gLCInURLSessionTaskCreate) {
        return [self lcDebug_dataTaskWithRequest:request];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLSessionDataTask *task = [self lcDebug_dataTaskWithRequest:request];
        if (atomic_load(&gLCDebugAgentActive) && !LCDebugIsOwnDebugRequestURL(request.URL)) {
            LCGetOrCreateTaskContext(task, request, nil);
        }
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionDataTask *)lcDebug_dataTaskWithURL:(NSURL *)url {
    if (gLCInURLSessionTaskCreate) {
        return [self lcDebug_dataTaskWithURL:url];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLSessionDataTask *task = [self lcDebug_dataTaskWithURL:url];
        if (atomic_load(&gLCDebugAgentActive) && !LCDebugIsOwnDebugRequestURL(url)) {
            LCGetOrCreateTaskContext(task, url ? [NSURLRequest requestWithURL:url] : nil, nil);
        }
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionUploadTask *)lcDebug_uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    if (gLCInURLSessionTaskCreate) {
        return [self lcDebug_uploadTaskWithRequest:request fromData:bodyData];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLSessionUploadTask *task = [self lcDebug_uploadTaskWithRequest:request fromData:bodyData];
        if (atomic_load(&gLCDebugAgentActive) && !LCDebugIsOwnDebugRequestURL(request.URL)) {
            LCGetOrCreateTaskContext(task, request, bodyData);
        }
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionWebSocketTask *)lcDebug_webSocketTaskWithRequest:(NSURLRequest *)request {
    if (gLCInURLSessionTaskCreate) {
        return [self lcDebug_webSocketTaskWithRequest:request];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLSessionWebSocketTask *task = [self lcDebug_webSocketTaskWithRequest:request];
        if (atomic_load(&gLCDebugAgentActive)) {
            LCRecordWebSocketEvent(request);
        }
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

- (NSURLSessionWebSocketTask *)lcDebug_webSocketTaskWithURL:(NSURL *)url {
    if (gLCInURLSessionTaskCreate) {
        return [self lcDebug_webSocketTaskWithURL:url];
    }
    gLCInURLSessionTaskCreate = YES;
    @try {
        NSURLSessionWebSocketTask *task = [self lcDebug_webSocketTaskWithURL:url];
        if (atomic_load(&gLCDebugAgentActive) && url) {
            LCRecordWebSocketEvent([NSURLRequest requestWithURL:url]);
        }
        return task;
    } @finally {
        gLCInURLSessionTaskCreate = NO;
    }
}

@end

static void LCDebugOnTaskResume(NSURLSessionTask *task) {
    if (!atomic_load(&gLCDebugAgentActive) || !task) return;
    NSURLRequest *req = task.originalRequest ?: task.currentRequest;
    if (req && !LCDebugIsOwnDebugRequestURL(req.URL)) {
        LCDebugNetworkTaskContext *ctx = LCGetOrCreateTaskContext(task, req, nil);
        [ctx markStartedIfNeeded];
    }
}

@implementation NSURLSessionTask (LCDebugResumeHook)

- (void)lcDebug_resume {
    LCDebugOnTaskResume(self);
    [self lcDebug_resume];
}

@end

static void LCHookTaskClusterResumeClass(Class cls) {
    if (!cls) return;
    SEL resumeSel = @selector(resume);
    Class owner = LCOwningClassForSelector(cls, resumeSel);
    if (!owner || owner == NSURLSessionTask.class) return;
    if (!LCMarkDelegateMethodHooked(owner, resumeSel)) return;
    Method m = class_getInstanceMethod(owner, resumeSel);
    if (!m) return;
    IMP origIMP = method_getImplementation(m);
    id block = ^(id selfObj) {
        if ([selfObj isKindOfClass:NSURLSessionTask.class]) {
            LCDebugOnTaskResume((NSURLSessionTask *)selfObj);
        }
        ((void (*)(id, SEL))origIMP)(selfObj, resumeSel);
    };
    class_replaceMethod(owner, resumeSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
}

// MARK: - WKWebView Console & Fetch/XHR Bridge

static NSString *const kLCDebugWKHandlerName = @"lcDebugBridge";

@interface LCDebugWKScriptHandler : NSObject <WKScriptMessageHandler>
@end

@implementation LCDebugWKScriptHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = (NSDictionary *)message.body;
    NSString *kind = [dict[@"kind"] isKindOfClass:NSString.class] ? dict[@"kind"] : @"";
    if ([kind isEqualToString:@"console"]) {
        NSString *level = [dict[@"level"] isKindOfClass:NSString.class] ? dict[@"level"] : @"info";
        NSString *text = [dict[@"text"] isKindOfClass:NSString.class] ? dict[@"text"] : @"";
        if (text.length > 0) {
            [LCDebugServer.shared appendLogStream:@"webview" level:level subsystem:@"WKWebView" category:@"console" text:text];
        }
    } else if ([kind isEqualToString:@"network"]) {
        NSString *method = [dict[@"method"] isKindOfClass:NSString.class] ? dict[@"method"] : @"GET";
        NSString *url = [dict[@"url"] isKindOfClass:NSString.class] ? dict[@"url"] : @"";
        NSInteger status = [dict[@"statusCode"] integerValue];
        NSInteger durationMs = [dict[@"durationMs"] integerValue];
        NSString *resp = [dict[@"responseBodyPreview"] isKindOfClass:NSString.class] ? dict[@"responseBodyPreview"] : @"";
        NSString *reqBody = [dict[@"requestBodyPreview"] isKindOfClass:NSString.class] ? dict[@"requestBodyPreview"] : @"";
        NSString *err = [dict[@"error"] isKindOfClass:NSString.class] ? dict[@"error"] : @"";
        [LCDebugServer.shared recordNetworkEvent:@{
            @"id": NSUUID.UUID.UUIDString,
            @"timestamp": @(CFAbsoluteTimeGetCurrent()),
            @"source": @"webview",
            @"method": method,
            @"url": url,
            @"statusCode": @(status),
            @"mimeType": @"webview",
            @"durationMs": @(durationMs),
            @"bytes": @(resp.length),
            @"requestHeaders": @{},
            @"responseHeaders": @{},
            @"requestBodyPreview": reqBody,
            @"responseBodyPreview": resp,
            @"curl": [NSString stringWithFormat:@"curl -X %@ '%@'", method, LCEscapeSingleQuotes(url)],
            @"error": err
        }];
    }
}

@end

static NSString *LCDebugWebViewHookScript(void) {
    return @
    "(function(){"
    "if(window.__lcDebugHooked)return;window.__lcDebugHooked=true;"
    "function post(o){try{window.webkit.messageHandlers.lcDebugBridge.postMessage(o);}catch(e){}}"
    "function strUrl(u){if(typeof u==='string')return u;if(u&&(u.url||u.href))return String(u.url||u.href);return String(u||'');}"
    "function fmt(args){return Array.prototype.slice.call(args).map(function(a){try{return typeof a==='object'?JSON.stringify(a):String(a);}catch(e){return String(a);}}).join(' ');}"
    "['log','info','warn','error','debug'].forEach(function(lv){var orig=console[lv];console[lv]=function(){post({kind:'console',level:lv==='log'?'info':lv,text:fmt(arguments)});if(orig)return orig.apply(console,arguments);};});"
    "window.addEventListener('error',function(ev){post({kind:'console',level:'error',text:'JS Error: '+(ev.message||'')+' @ '+(ev.filename||'')+':'+(ev.lineno||0)});});"
    "if(window.fetch){var origFetch=window.fetch;window.fetch=function(input,init){var t0=Date.now();var url=strUrl(input);var method=((init&&init.method)||(input&&input.method)||'GET').toUpperCase();var reqBody=(init&&typeof init.body==='string')?init.body.slice(0,2048):'';return origFetch.apply(this,arguments).then(function(res){var ct=(res.headers&&res.headers.get('content-type'))||'';var cl=parseInt((res.headers&&res.headers.get('content-length'))||'0',10)||0;var textLike=!ct||/json|text|xml|javascript|form/i.test(ct);if(textLike&&cl<=262144){try{res.clone().text().then(function(txt){post({kind:'network',method:method,url:url,statusCode:res.status,durationMs:Date.now()-t0,requestBodyPreview:reqBody,responseBodyPreview:(txt||'').slice(0,4096),error:''});}).catch(function(){});}catch(e){post({kind:'network',method:method,url:url,statusCode:res.status,durationMs:Date.now()-t0,requestBodyPreview:reqBody,responseBodyPreview:'',error:''});}}else{post({kind:'network',method:method,url:url,statusCode:res.status,durationMs:Date.now()-t0,requestBodyPreview:reqBody,responseBodyPreview:'<Non-text or large response: '+ct+'>',error:''});}return res;}).catch(function(err){post({kind:'network',method:method,url:url,statusCode:-1,durationMs:Date.now()-t0,requestBodyPreview:reqBody,responseBodyPreview:'',error:String(err)});throw err;});};}"
    "var origOpen=XMLHttpRequest.prototype.open;var origSend=XMLHttpRequest.prototype.send;"
    "XMLHttpRequest.prototype.open=function(m,u){this.__lcM=m;this.__lcU=strUrl(u);return origOpen.apply(this,arguments);};"
    "XMLHttpRequest.prototype.send=function(b){var xhr=this;var t0=Date.now();var reqBody=(typeof b==='string')?b.slice(0,2048):'';xhr.addEventListener('loadend',function(){var txt='';try{if(!xhr.responseType||xhr.responseType==='text'){txt=(typeof xhr.responseText==='string')?xhr.responseText.slice(0,4096):'';}}catch(e){}post({kind:'network',method:(xhr.__lcM||'GET').toUpperCase(),url:xhr.__lcU||'',statusCode:xhr.status||0,durationMs:Date.now()-t0,requestBodyPreview:reqBody,responseBodyPreview:txt,error:''});});return origSend.apply(this,arguments);};"
    "})();";
}

static char kLCDebugWKHooksInstalledKey;

@implementation WKWebView (LCDebugHook)

- (instancetype)lcDebug_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (atomic_load(&gLCDebugAgentActive)) {
        WKWebViewConfiguration *cfg = configuration ?: [[WKWebViewConfiguration alloc] init];
        WKUserContentController *ucc = cfg.userContentController;
        if (ucc && !objc_getAssociatedObject(ucc, &kLCDebugWKHooksInstalledKey)) {
            objc_setAssociatedObject(ucc, &kLCDebugWKHooksInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static LCDebugWKScriptHandler *sharedHandler = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                sharedHandler = [[LCDebugWKScriptHandler alloc] init];
            });
            [ucc removeScriptMessageHandlerForName:kLCDebugWKHandlerName];
            [ucc addScriptMessageHandler:sharedHandler name:kLCDebugWKHandlerName];
            WKUserScript *script = [[WKUserScript alloc] initWithSource:LCDebugWebViewHookScript()
                                                          injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                       forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
        return [self lcDebug_initWithFrame:frame configuration:cfg];
    }
    return [self lcDebug_initWithFrame:frame configuration:configuration];
}

@end

// MARK: - NSLog / NSLogv Hook & Signal/Exception Crash Capture (100% JIT-less)

static void LCDebugHook_NSLogv(NSString *format, va_list args) {
    if (!gLCInNSLogHook && format && atomic_load(&gLCDebugAgentActive)) {
        gLCInNSLogHook = YES;
        va_list copyArgs;
        va_copy(copyArgs, args);
        @autoreleasepool {
            @try {
                NSString *formatted = [[NSString alloc] initWithFormat:format arguments:copyArgs];
                if (formatted.length > 0) {
                    LCRecordRecentNSLogMessage(formatted);
                    [LCDebugServer.shared appendLogStream:@"nslog" level:@"info" subsystem:nil category:nil text:formatted];
                }
            } @catch (__unused NSException *ex) {
                // Never crash a guest app while formatting a debug log
            } @finally {
                va_end(copyArgs);
                gLCInNSLogHook = NO;
            }
        }
    }
    if (g_orig_NSLogv) {
        g_orig_NSLogv(format, args);
    }
}

static void LCDebugHook_NSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    LCDebugHook_NSLogv(format, args);
    va_end(args);
}

static void LCDebugSignalHandler(int sig, siginfo_t *info, void *context) {
    (void)info;
    (void)context;
    if (gLCCrashLogPath[0] != '\0') {
        int fd = open(gLCCrashLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            const char *sigName = "SIGNAL";
            switch (sig) {
                case SIGABRT: sigName = "SIGABRT"; break;
                case SIGSEGV: sigName = "SIGSEGV"; break;
                case SIGBUS:  sigName = "SIGBUS"; break;
                case SIGILL:  sigName = "SIGILL"; break;
                case SIGFPE:  sigName = "SIGFPE"; break;
                default: break;
            }
            const char *hdr = "=== Crash Signal Caught: ";
            write(fd, hdr, strlen(hdr));
            write(fd, sigName, strlen(sigName));
            write(fd, " ===\n", 5);
            void *frames[64];
            int count = backtrace(frames, 64);
            if (count > 0) {
                backtrace_symbols_fd(frames, count, fd);
            }
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((visibility("default")))
void LCDebugAgentRecordUncaughtException(NSException *exception) {
    if (!exception) return;
    NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"] ?: @"";
    NSString *msg = [NSString stringWithFormat:@"Uncaught NSException %@: %@\n%@",
                     exception.name ?: @"Exception",
                     exception.reason ?: @"(no reason)",
                     stack];
    if (gLCCrashLogPath[0] != '\0') {
        NSString *path = @(gLCCrashLogPath);
        [msg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if (atomic_load(&gLCDebugAgentActive)) {
        [LCDebugServer.shared appendLogStream:@"crash" level:@"fault" subsystem:@"Exception" category:exception.name text:msg];
    }
}

// MARK: - UI / Window / Tab / Navigation / Touch / Notification Hooks (100% JIT-less)

static NSString *LCDebugOwningViewControllerName(UIView *view) {
    UIResponder *r = view.nextResponder;
    while (r) {
        if ([r isKindOfClass:UIViewController.class]) {
            return NSStringFromClass(r.class) ?: @"";
        }
        r = r.nextResponder;
    }
    return @"";
}

static NSArray<NSString *> *LCDebugResponderChain(UIResponder *responder) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIResponder *cursor = responder;
    int guard = 0;
    while (cursor && guard < 24) {
        [chain addObject:NSStringFromClass(cursor.class) ?: @"?"];
        cursor = cursor.nextResponder;
        guard++;
    }
    return chain;
}

static char kLCXRaySavedBorderKey;

static UIColor *LCDebugColorForClassName(NSString *name) {
    NSUInteger h = name.hash;
    CGFloat hue = ((h & 0xFF) / 255.0);
    return [UIColor colorWithHue:hue saturation:0.85 brightness:0.95 alpha:0.9];
}

static void LCApplyXRayToSingleView(UIView *view, BOOL enabled) {
    if (!view || LCDebugIsInternalDebugClass(view.class)) return;
    if (view.window && LCDebugIsInternalDebugClass(view.window.class)) return;
    CALayer *layer = view.layer;
    NSArray *saved = objc_getAssociatedObject(view, &kLCXRaySavedBorderKey);
    if (enabled) {
        if (saved && layer.borderWidth == 1.0) {
            return; // Already styled; avoid redundant layer churn on every layoutSubviews
        }
        if (!saved) {
            id savedColor = layer.borderColor ? [UIColor colorWithCGColor:layer.borderColor] : NSNull.null;
            objc_setAssociatedObject(view, &kLCXRaySavedBorderKey, @[@(layer.borderWidth), savedColor], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        layer.borderWidth = 1.0;
        layer.borderColor = LCDebugColorForClassName(NSStringFromClass(view.class)).CGColor;
    } else if (saved.count == 2) {
        layer.borderWidth = ((NSNumber *)saved[0]).doubleValue;
        id savedColor = saved[1];
        layer.borderColor = [savedColor isKindOfClass:UIColor.class] ? ((UIColor *)savedColor).CGColor : NULL;
        objc_setAssociatedObject(view, &kLCXRaySavedBorderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LCApplyXRayToView(UIView *view, BOOL enabled) {
    if (!view || LCDebugIsInternalDebugClass(view.class)) return;
    LCApplyXRayToSingleView(view, enabled);
    for (UIView *sub in view.subviews) {
        LCApplyXRayToView(sub, enabled);
    }
}

@implementation UIView (LCDebugXRayHook)
- (void)lcDebug_layoutSubviews {
    [self lcDebug_layoutSubviews];
    if (atomic_load(&gLCDebugXRayAtomic)) {
        LCApplyXRayToSingleView(self, YES);
    } else if (objc_getAssociatedObject(self, &kLCXRaySavedBorderKey) != nil) {
        // Restore recycled/previously-detached cells cleanly once X-Ray is disabled
        LCApplyXRayToSingleView(self, NO);
    }
}
@end

@implementation UIApplication (LCDebugEventHook)
- (void)lcDebug_sendEvent:(UIEvent *)event {
    if (atomic_load(&gLCDebugAgentActive) && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                UIWindow *win = touch.window;
                UIView *target = touch.view;
                if (win && !LCDebugIsInternalDebugClass(win.class) && (!target || !LCDebugIsInternalDebugClass(target.class))) {
                    CGPoint pt = [touch locationInView:win];
                    NSString *targetName = target ? (NSStringFromClass(target.class) ?: @"UIView") : @"UIWindow";
                    NSString *accId = target.accessibilityIdentifier ?: @"";
                    NSString *vcName = target ? LCDebugOwningViewControllerName(target) : @"";
                    NSString *detail = accId.length > 0
                        ? [NSString stringWithFormat:@"(%.0f, %.0f) id=%@", pt.x, pt.y, accId]
                        : [NSString stringWithFormat:@"(%.0f, %.0f)", pt.x, pt.y];
                    [LCDebugServer.shared recordUIEventKind:@"touch"
                                                      title:[NSString stringWithFormat:@"Tap %@", targetName]
                                                     detail:detail
                                                     target:targetName
                                             viewController:vcName
                                                     window:NSStringFromClass(win.class) ?: @"UIWindow"];
                }
                break;
            }
        }
    }
    [self lcDebug_sendEvent:event];
}
@end

@implementation UIViewController (LCDebugLifecycleHook)
- (void)lcDebug_viewDidAppear:(BOOL)animated {
    [self lcDebug_viewDidAppear:animated];
    if (!atomic_load(&gLCDebugAgentActive)) return;
    NSString *clsName = NSStringFromClass(self.class) ?: @"";
    if (LCDebugIsInternalDebugClass(self.class) || [clsName hasPrefix:@"UIInput"] || [clsName hasPrefix:@"_UISystem"]) {
        return;
    }
    NSString *title = self.title ?: self.navigationItem.title ?: @"";
    NSString *detail = title.length > 0 ? [NSString stringWithFormat:@"title=\"%@\"", title] : @"appeared";
    UIWindow *win = self.viewIfLoaded.window;
    [LCDebugServer.shared recordUIEventKind:@"vc"
                                      title:[NSString stringWithFormat:@"Appear %@", clsName]
                                     detail:detail
                                     target:clsName
                             viewController:clsName
                                     window:win ? NSStringFromClass(win.class) : @""];
}

- (void)lcDebug_presentViewController:(UIViewController *)vcToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (atomic_load(&gLCDebugAgentActive) && vcToPresent && !LCDebugIsInternalDebugClass(vcToPresent.class) && !LCDebugIsInternalDebugClass(self.class)) {
        NSString *fromName = NSStringFromClass(self.class) ?: @"";
        NSString *toName = NSStringFromClass(vcToPresent.class) ?: @"";
        UIWindow *win = self.viewIfLoaded.window;
        [LCDebugServer.shared recordUIEventKind:@"modal"
                                          title:[NSString stringWithFormat:@"Present %@", toName]
                                         detail:[NSString stringWithFormat:@"from %@", fromName]
                                         target:toName
                                 viewController:fromName
                                         window:win ? NSStringFromClass(win.class) : @""];
    }
    [self lcDebug_presentViewController:vcToPresent animated:flag completion:completion];
}
@end

@implementation UITabBarController (LCDebugTabHook)
- (void)lcDebug_setSelectedIndex:(NSUInteger)selectedIndex {
    if (gLCInTabSelectHook) {
        [self lcDebug_setSelectedIndex:selectedIndex];
        return;
    }
    gLCInTabSelectHook = YES;
    @try {
        NSUInteger prev = self.selectedIndex;
        [self lcDebug_setSelectedIndex:selectedIndex];
        if (atomic_load(&gLCDebugAgentActive) && prev != selectedIndex && !LCDebugIsInternalDebugClass(self.class)) {
            UIViewController *selVC = (selectedIndex < self.viewControllers.count) ? self.viewControllers[selectedIndex] : nil;
            NSString *vcName = selVC ? NSStringFromClass(selVC.class) : @"";
            UIWindow *win = self.viewIfLoaded.window;
            [LCDebugServer.shared recordUIEventKind:@"tab"
                                              title:[NSString stringWithFormat:@"Tab %lu → %lu", (unsigned long)prev, (unsigned long)selectedIndex]
                                             detail:vcName
                                             target:NSStringFromClass(self.class) ?: @"UITabBarController"
                                     viewController:vcName
                                             window:win ? NSStringFromClass(win.class) : @""];
        }
    } @finally {
        gLCInTabSelectHook = NO;
    }
}

- (void)lcDebug_setSelectedViewController:(UIViewController *)selectedViewController {
    if (gLCInTabSelectHook) {
        [self lcDebug_setSelectedViewController:selectedViewController];
        return;
    }
    gLCInTabSelectHook = YES;
    @try {
        UIViewController *prevVC = self.selectedViewController;
        [self lcDebug_setSelectedViewController:selectedViewController];
        if (atomic_load(&gLCDebugAgentActive) && prevVC != selectedViewController && selectedViewController && !LCDebugIsInternalDebugClass(self.class)) {
            NSString *toName = NSStringFromClass(selectedViewController.class) ?: @"";
            NSString *fromName = prevVC ? NSStringFromClass(prevVC.class) : @"none";
            UIWindow *win = self.viewIfLoaded.window;
            [LCDebugServer.shared recordUIEventKind:@"tab"
                                              title:[NSString stringWithFormat:@"Tab → %@", toName]
                                             detail:[NSString stringWithFormat:@"from %@", fromName]
                                             target:NSStringFromClass(self.class) ?: @"UITabBarController"
                                     viewController:toName
                                             window:win ? NSStringFromClass(win.class) : @""];
        }
    } @finally {
        gLCInTabSelectHook = NO;
    }
}
@end

@implementation UINavigationController (LCDebugNavHook)
- (void)lcDebug_pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (atomic_load(&gLCDebugAgentActive) && viewController && !LCDebugIsInternalDebugClass(viewController.class) && !LCDebugIsInternalDebugClass(self.class)) {
        NSString *vcName = NSStringFromClass(viewController.class) ?: @"";
        UIWindow *win = self.viewIfLoaded.window;
        [LCDebugServer.shared recordUIEventKind:@"nav"
                                          title:[NSString stringWithFormat:@"Push %@", vcName]
                                         detail:[NSString stringWithFormat:@"stack depth %lu", (unsigned long)(self.viewControllers.count + 1)]
                                         target:NSStringFromClass(self.class) ?: @"UINavigationController"
                                 viewController:vcName
                                         window:win ? NSStringFromClass(win.class) : @""];
    }
    [self lcDebug_pushViewController:viewController animated:animated];
}

- (UIViewController *)lcDebug_popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = [self lcDebug_popViewControllerAnimated:animated];
    if (atomic_load(&gLCDebugAgentActive) && popped && !LCDebugIsInternalDebugClass(popped.class) && !LCDebugIsInternalDebugClass(self.class)) {
        NSString *vcName = NSStringFromClass(popped.class) ?: @"";
        UIWindow *win = self.viewIfLoaded.window;
        [LCDebugServer.shared recordUIEventKind:@"nav"
                                          title:[NSString stringWithFormat:@"Pop %@", vcName]
                                         detail:[NSString stringWithFormat:@"stack depth %lu", (unsigned long)self.viewControllers.count]
                                         target:NSStringFromClass(self.class) ?: @"UINavigationController"
                                 viewController:vcName
                                         window:win ? NSStringFromClass(win.class) : @""];
    }
    return popped;
}
@end

@implementation UIWindow (LCDebugWindowHook)
- (void)lcDebug_makeKeyAndVisible {
    [self lcDebug_makeKeyAndVisible];
    if (atomic_load(&gLCDebugAgentActive) && !LCDebugIsInternalDebugClass(self.class)) {
        NSString *winName = NSStringFromClass(self.class) ?: @"UIWindow";
        NSString *rootVC = self.rootViewController ? NSStringFromClass(self.rootViewController.class) : @"";
        [LCDebugServer.shared recordUIEventKind:@"window"
                                          title:[NSString stringWithFormat:@"Key Window %@", winName]
                                         detail:[NSString stringWithFormat:@"level=%.0f root=%@", self.windowLevel, rootVC]
                                         target:winName
                                 viewController:rootVC
                                         window:winName];
    }
}
@end

@implementation NSNotificationCenter (LCDebugNotifHook)
- (void)lcDebug_postNotificationName:(NSNotificationName)aName object:(id)anObject userInfo:(NSDictionary *)aUserInfo {
    [self lcDebug_postNotificationName:aName object:anObject userInfo:aUserInfo];
    if (atomic_load(&gLCDebugNotifMonitorAtomic) && !gLCInNotifHook && aName.length > 0) {
        if (![aName hasPrefix:@"_UI"] && ![aName hasPrefix:@"NSWillBecomeMultiThreaded"]) {
            gLCInNotifHook = YES;
            @try {
                NSString *objCls = anObject ? NSStringFromClass([anObject class]) : @"nil";
                [LCDebugServer.shared recordUIEventKind:@"notification"
                                                  title:aName
                                                 detail:[NSString stringWithFormat:@"object=%@ keys=%lu", objCls, (unsigned long)aUserInfo.count]
                                                 target:objCls
                                         viewController:@""
                                                 window:@""];
            } @finally {
                gLCInNotifHook = NO;
            }
        }
    }
}
@end

// MARK: - Multi-Window Tap-to-Inspect Overlay

@interface LCDebugInspectOverlayView : UIView
@property (nonatomic, strong) UIView *highlightBox;
@property (nonatomic, copy) void (^onInspectView)(NSDictionary *info);
- (void)handleTap:(UITapGestureRecognizer *)tap;
@end

@implementation LCDebugInspectOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.02];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _highlightBox = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightBox.layer.borderColor = UIColor.systemCyanColor.CGColor;
        _highlightBox.layer.borderWidth = 2.0;
        _highlightBox.backgroundColor = [UIColor.systemCyanColor colorWithAlphaComponent:0.18];
        _highlightBox.hidden = YES;
        _highlightBox.userInteractionEnabled = NO;
        [self addSubview:_highlightBox];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    UIWindow *overlayWin = self.window;
    if (!overlayWin) return;
    CGPoint ptInOverlay = [tap locationInView:overlayWin];
    self.hidden = YES;

    UIView *hit = nil;
    UIWindow *hitWindow = nil;
    for (UIWindow *win in LCVisibleGuestWindows()) {
        CGPoint ptInWin = [overlayWin convertPoint:ptInOverlay toWindow:win];
        UIView *candidate = [win hitTest:ptInWin withEvent:nil];
        if (candidate && !LCDebugIsInternalDebugClass(candidate.class)) {
            hit = candidate;
            hitWindow = win;
            break;
        }
    }
    self.hidden = NO;
    if (!hit || !hitWindow) return;

    CGRect rectInWindow = [hit convertRect:hit.bounds toView:hitWindow];
    CGRect rectInSelf = [overlayWin convertRect:rectInWindow fromWindow:hitWindow];
    self.highlightBox.frame = rectInSelf;
    self.highlightBox.hidden = NO;

    NSString *clsName = NSStringFromClass(hit.class) ?: @"";
    NSString *vcName = LCDebugOwningViewControllerName(hit);
    NSArray<NSString *> *chain = LCDebugResponderChain(hit);
    BOOL isSwiftUI = [clsName containsString:@"Hosting"] || [clsName containsString:@"SwiftUI"];

    NSDictionary *info = @{
        @"class": clsName,
        @"viewController": vcName ?: @"",
        @"windowClass": NSStringFromClass(hitWindow.class) ?: @"UIWindow",
        @"frame": NSStringFromCGRect(hit.frame) ?: @"",
        @"bounds": NSStringFromCGRect(hit.bounds) ?: @"",
        @"accessibilityIdentifier": hit.accessibilityIdentifier ?: @"",
        @"accessibilityLabel": hit.accessibilityLabel ?: @"",
        @"alpha": @(hit.alpha),
        @"hidden": @(hit.isHidden),
        @"tag": @(hit.tag),
        @"backgroundColor": hit.backgroundColor ? [hit.backgroundColor description] : @"",
        @"subviewCount": @(hit.subviews.count),
        @"constraintsCount": @(hit.constraints.count),
        @"isSwiftUI": @(isSwiftUI),
        @"responderChain": chain
    };
    if (self.onInspectView) {
        self.onInspectView(info);
    }
}

@end

// MARK: - In-App Floating Liquid Glass Debug Overlay (Classic & Multitask)

@interface LCDebugInAppDrawerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UISegmentedControl *logFilterControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *metricsLabel;
@property (nonatomic, strong) UIStackView *headerStack;
@property (nonatomic, strong) UIButton *xrayBtn;
@property (nonatomic, strong) UIButton *notifBtn;
@property (nonatomic, strong) UIButton *lanBtn;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *displayRows;
@property (nonatomic, strong) NSArray<NSDictionary *> *cachedRuntimeRows;
- (void)reloadDataNow;
- (void)handleTabOrFilterChanged;
- (void)handleCopy;
- (void)handleClear;
- (void)handleClose;
- (void)toggleXRay;
- (void)toggleNotifs;
- (void)toggleLAN;
- (void)triggerMemWarn;
@end

@implementation LCDebugInAppDrawerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.96];
    self.title = @"LiveContainer Debug";

    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(handleCopy)];
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(handleClear)];
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(handleClose)];
    self.navigationItem.leftBarButtonItems = @[copyBtn, clearBtn];
    self.navigationItem.rightBarButtonItem = closeBtn;

    self.metricsLabel = [[UILabel alloc] init];
    self.metricsLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    self.metricsLabel.textColor = UIColor.systemCyanColor;
    self.metricsLabel.textAlignment = NSTextAlignmentCenter;

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"Console", @"Network", @"UI/Events", @"Runtime"]];
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(handleTabOrFilterChanged) forControlEvents:UIControlEventValueChanged];

    self.logFilterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Logs", @"OSLog", @"Web", @"Err"]];
    self.logFilterControl.selectedSegmentIndex = 0;
    [self.logFilterControl addTarget:self action:@selector(handleTabOrFilterChanged) forControlEvents:UIControlEventValueChanged];

    self.xrayBtn = [self makeActionButton:@"X-Ray" action:@selector(toggleXRay)];
    self.notifBtn = [self makeActionButton:@"Notifs" action:@selector(toggleNotifs)];
    self.lanBtn = [self makeActionButton:@"LAN" action:@selector(toggleLAN)];
    UIButton *memBtn = [self makeActionButton:@"MemWarn" action:@selector(triggerMemWarn)];

    UIStackView *actionBar = [[UIStackView alloc] initWithArrangedSubviews:@[self.xrayBtn, self.notifBtn, self.lanBtn, memBtn]];
    actionBar.axis = UILayoutConstraintAxisHorizontal;
    actionBar.distribution = UIStackViewDistributionFillEqually;
    actionBar.spacing = 6;
    [actionBar.heightAnchor constraintEqualToConstant:30].active = YES;

    // Vertical stack collapses logFilterControl cleanly when hidden (no blank gap on other tabs)
    self.headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.metricsLabel, self.tabControl, self.logFilterControl, actionBar]];
    self.headerStack.axis = UILayoutConstraintAxisVertical;
    self.headerStack.spacing = 6;
    self.headerStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.estimatedRowHeight = 44;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    [self.view addSubview:self.headerStack];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.headerStack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [self.headerStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.headerStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],

        [self.tableView.topAnchor constraintEqualToAnchor:self.headerStack.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self reloadDataNow];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }
        [strongSelf reloadDataNow];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [self.refreshTimer invalidate];
        self.refreshTimer = nil;
    }
}

- (void)dealloc {
    [self.refreshTimer invalidate];
}

- (UIButton *)makeActionButton:(NSString *)title action:(SEL)sel {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.layer.cornerRadius = 10;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)handleTabOrFilterChanged {
    if (self.tabControl.selectedSegmentIndex == 3) {
        self.cachedRuntimeRows = nil; // Refresh runtime snapshot on explicit switch to Runtime tab
    }
    [self reloadDataNow];
}

- (NSArray<NSDictionary *> *)buildRuntimeRowsFromStatus:(NSDictionary *)st {
    BOOL jit = [st[@"isJIT"] boolValue];
    BOOL lan = [st[@"lanEnabled"] boolValue];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{ @"k": @"Bundle ID", @"v": st[@"bundleId"] ?: @"" }];
    [rows addObject:@{ @"k": @"Mode", @"v": jit ? @"JIT Attached (CS_DEBUGGED)" : @"JIT-Less (100% Native Runtime Hooks)" }];
    [rows addObject:@{ @"k": @"Local Port", @"v": [NSString stringWithFormat:@"127.0.0.1:%@", st[@"localPort"]] }];
    if (lan && [st[@"lanIP"] length] > 0) {
        NSString *url = [NSString stringWithFormat:@"http://%@:%@?token=%@", st[@"lanIP"], st[@"lanPort"], st[@"authToken"] ?: @""];
        [rows addObject:@{ @"k": @"Mac LAN Console (Tap to Copy)", @"v": url, @"copy": url }];
    } else {
        [rows addObject:@{ @"k": @"Mac LAN Console", @"v": @"Off (tap LAN button above to enable)" }];
    }
    NSArray *dylibs = [LCDebugServer.shared captureLoadedDylibs];
    NSUInteger appImages = 0;
    for (NSDictionary *d in dylibs) {
        if (![d[@"isSystem"] boolValue]) appImages++;
    }
    [rows addObject:@{ @"k": @"Loaded Images", @"v": [NSString stringWithFormat:@"%lu total (%lu app/tweaks)", (unsigned long)dylibs.count, (unsigned long)appImages] }];
    [rows addObject:@{ @"k": @"Active Windows", @"v": [NSString stringWithFormat:@"%lu visible guest windows", (unsigned long)LCVisibleGuestWindows().count] }];
    for (NSDictionary *d in dylibs) {
        if (![d[@"isSystem"] boolValue]) {
            [rows addObject:@{ @"k": d[@"name"] ?: @"image", @"v": [NSString stringWithFormat:@"%@ · %@", d[@"base"] ?: @"", d[@"path"] ?: @""] }];
        }
    }
    return rows;
}

- (void)reloadDataNow {
    NSDictionary *st = [LCDebugServer.shared currentStatusDictionary];
    BOOL jit = [st[@"isJIT"] boolValue];
    self.metricsLabel.text = [NSString stringWithFormat:@"PID %@ · %.0f%% CPU · %.0f MB · %@ FPS · %@",
                              st[@"pid"], [st[@"cpuPercent"] doubleValue], [st[@"memoryMB"] doubleValue],
                              st[@"fps"], jit ? @"JIT ON" : @"JIT-Less"];
    BOOL xr = [st[@"xrayEnabled"] boolValue];
    BOOL nm = [st[@"notificationMonitorEnabled"] boolValue];
    BOOL lan = [st[@"lanEnabled"] boolValue];
    self.xrayBtn.backgroundColor = xr ? [UIColor.systemOrangeColor colorWithAlphaComponent:0.75] : [UIColor colorWithWhite:1 alpha:0.10];
    self.notifBtn.backgroundColor = nm ? [UIColor.systemBlueColor colorWithAlphaComponent:0.75] : [UIColor colorWithWhite:1 alpha:0.10];
    self.lanBtn.backgroundColor = lan ? [UIColor.systemGreenColor colorWithAlphaComponent:0.75] : [UIColor colorWithWhite:1 alpha:0.10];

    NSInteger tab = self.tabControl.selectedSegmentIndex;
    self.logFilterControl.hidden = (tab != 0);

    NSArray<NSDictionary *> *nextRows = nil;
    if (tab == 0) {
        NSArray<NSDictionary *> *allLogs = [LCDebugServer.shared logsSnapshot];
        NSInteger filter = self.logFilterControl.selectedSegmentIndex;
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSInteger i = (NSInteger)allLogs.count - 1; i >= 0; i--) {
            NSDictionary *entry = allLogs[(NSUInteger)i];
            NSString *stream = entry[@"stream"] ?: @"";
            NSString *level = entry[@"level"] ?: @"";
            if (filter == 1 && !([stream isEqualToString:@"stdout"] || [stream isEqualToString:@"stderr"] || [stream isEqualToString:@"nslog"])) continue;
            if (filter == 2 && ![stream isEqualToString:@"oslog"]) continue;
            if (filter == 3 && ![stream isEqualToString:@"webview"]) continue;
            if (filter == 4 && !([stream isEqualToString:@"stderr"] || [stream isEqualToString:@"crash"] || [level isEqualToString:@"error"] || [level isEqualToString:@"fault"])) continue;
            [filtered addObject:entry];
            if (filtered.count >= 400) break;
        }
        nextRows = filtered;
    } else if (tab == 1) {
        nextRows = [LCDebugServer.shared networkSnapshot];
    } else if (tab == 2) {
        nextRows = [LCDebugServer.shared uiEventsSnapshot];
    } else {
        if (!self.cachedRuntimeRows) {
            self.cachedRuntimeRows = [self buildRuntimeRowsFromStatus:st];
        }
        nextRows = self.cachedRuntimeRows;
    }

    // Avoid interrupting active user scrolling unless row content actually changed
    if (!self.tableView.isDragging && !self.tableView.isDecelerating) {
        self.displayRows = nextRows;
        [self.tableView reloadData];
    }
}

- (void)toggleXRay {
    NSDictionary *st = [LCDebugServer.shared currentStatusDictionary];
    [LCDebugServer.shared setXRayEnabled:![st[@"xrayEnabled"] boolValue]];
    [self reloadDataNow];
}

- (void)toggleNotifs {
    NSDictionary *st = [LCDebugServer.shared currentStatusDictionary];
    [LCDebugServer.shared setNotificationMonitorEnabled:![st[@"notificationMonitorEnabled"] boolValue]];
    [self reloadDataNow];
}

- (void)toggleLAN {
    NSDictionary *st = [LCDebugServer.shared currentStatusDictionary];
    [LCDebugServer.shared setLANEnabled:![st[@"lanEnabled"] boolValue]];
    self.cachedRuntimeRows = nil;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakSelf.cachedRuntimeRows = nil;
        [weakSelf reloadDataNow];
    });
}

- (void)triggerMemWarn {
    [LCDebugServer.shared simulateMemoryWarning];
    [self reloadDataNow];
}

- (void)handleCopy {
    NSInteger tab = self.tabControl.selectedSegmentIndex;
    NSMutableString *out = [NSMutableString string];
    if (tab == 0) {
        for (NSDictionary *e in [LCDebugServer.shared logsSnapshot]) {
            [out appendFormat:@"[%@] %@\n", e[@"stream"] ?: @"log", e[@"text"] ?: @""];
        }
    } else if (tab == 1) {
        for (NSDictionary *n in [LCDebugServer.shared networkSnapshot]) {
            [out appendFormat:@"%@ [%@] %@ (%@ms)\n", n[@"method"], n[@"statusCode"], n[@"url"], n[@"durationMs"]];
        }
    } else if (tab == 2) {
        for (NSDictionary *ev in [LCDebugServer.shared uiEventsSnapshot]) {
            [out appendFormat:@"[%@] %@ — %@\n", ev[@"kind"], ev[@"title"], ev[@"detail"]];
        }
    } else {
        out = [LCJSONStringFromObject([LCDebugServer.shared currentStatusDictionary]) mutableCopy];
    }
    UIPasteboard.generalPasteboard.string = out;
}

- (void)handleClear {
    NSInteger tab = self.tabControl.selectedSegmentIndex;
    if (tab == 0) [LCDebugServer.shared clearLogs];
    else if (tab == 1) [LCDebugServer.shared clearNetwork];
    else if (tab == 2) [LCDebugServer.shared clearUIEvents];
    else self.cachedRuntimeRows = nil;
    [self reloadDataNow];
}

- (void)handleClose {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.displayRows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"LCDebugCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = UIColor.clearColor;
    }

    NSDictionary *row = self.displayRows[(NSUInteger)indexPath.row];
    NSInteger tab = self.tabControl.selectedSegmentIndex;

    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.textProperties.numberOfLines = 3;
    cfg.textProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    cfg.secondaryTextProperties.numberOfLines = 2;
    cfg.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    cfg.secondaryTextProperties.color = [UIColor colorWithWhite:0.72 alpha:1.0];

    if (tab == 0) {
        NSString *stream = row[@"stream"] ?: @"log";
        NSString *level = row[@"level"] ?: @"info";
        NSString *sub = row[@"subsystem"] ?: @"";
        cfg.text = [NSString stringWithFormat:@"[%@%@] %@", stream.uppercaseString, sub.length > 0 ? [@":" stringByAppendingString:sub] : @"", row[@"text"] ?: @""];
        if ([stream isEqualToString:@"crash"] || [stream isEqualToString:@"stderr"] || [level isEqualToString:@"error"] || [level isEqualToString:@"fault"]) {
            cfg.textProperties.color = UIColor.systemRedColor;
        } else if ([level isEqualToString:@"warn"] || [stream isEqualToString:@"nslog"]) {
            cfg.textProperties.color = UIColor.systemYellowColor;
        } else if ([stream isEqualToString:@"oslog"]) {
            cfg.textProperties.color = UIColor.systemMintColor;
        } else {
            cfg.textProperties.color = UIColor.whiteColor;
        }
        cfg.secondaryText = nil;
    } else if (tab == 1) {
        NSInteger code = [row[@"statusCode"] integerValue];
        cfg.text = [NSString stringWithFormat:@"%@ [%ld] %@ms · %@", row[@"method"] ?: @"GET", (long)code, row[@"durationMs"] ?: @0, row[@"url"] ?: @""];
        cfg.textProperties.color = (code >= 200 && code < 300) ? UIColor.systemGreenColor : (code == 101 ? UIColor.systemCyanColor : UIColor.systemRedColor);
        cfg.secondaryText = [NSString stringWithFormat:@"%@ · %@ B · %@", row[@"source"] ?: @"urlsession", row[@"bytes"] ?: @0, row[@"mimeType"] ?: @""];
    } else if (tab == 2) {
        cfg.text = [NSString stringWithFormat:@"[%@] %@", [row[@"kind"] uppercaseString] ?: @"UI", row[@"title"] ?: @""];
        cfg.textProperties.color = UIColor.systemCyanColor;
        cfg.secondaryText = [NSString stringWithFormat:@"%@ · VC: %@", row[@"detail"] ?: @"", row[@"viewController"] ?: @"-"];
    } else {
        cfg.text = row[@"k"] ?: @"";
        cfg.textProperties.color = UIColor.whiteColor;
        cfg.secondaryText = row[@"v"] ?: @"";
    }

    cell.contentConfiguration = cfg;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.displayRows[(NSUInteger)indexPath.row];
    NSInteger tab = self.tabControl.selectedSegmentIndex;
    if (tab == 3 && [row[@"copy"] length] > 0) {
        UIPasteboard.generalPasteboard.string = row[@"copy"];
        return;
    }
    NSString *detailText = nil;
    if (tab == 1) {
        detailText = [NSString stringWithFormat:@"cURL:\n%@\n\nRequest Headers:\n%@\n\nResponse Headers:\n%@\n\nRequest Body:\n%@\n\nResponse:\n%@",
                      row[@"curl"] ?: @"",
                      LCJSONStringFromObject(row[@"requestHeaders"] ?: @{}),
                      LCJSONStringFromObject(row[@"responseHeaders"] ?: @{}),
                      row[@"requestBodyPreview"] ?: @"",
                      row[@"responseBodyPreview"] ?: @""];
    } else {
        detailText = LCJSONStringFromObject(row);
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Entry Details" message:detailText preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = detailText;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

@interface LCDebugOverlayRootViewController : UIViewController
@property (nonatomic, weak) UIView *pillContainer;
- (void)clampPillToSafeArea;
@end

@implementation LCDebugOverlayRootViewController

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self clampPillToSafeArea];
}

- (void)clampPillToSafeArea {
    UIView *pill = self.pillContainer;
    if (!pill) return;
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGFloat halfW = pill.bounds.size.width * 0.5 + 8;
    CGFloat halfH = pill.bounds.size.height * 0.5 + 8;
    CGFloat minX = MAX(halfW, insets.left + halfW);
    CGFloat maxX = MAX(minX, bounds.size.width - MAX(halfW, insets.right + halfW));
    CGFloat minY = MAX(halfH, insets.top + halfH);
    CGFloat maxY = MAX(minY, bounds.size.height - MAX(halfH, insets.bottom + halfH));
    CGPoint c = pill.center;
    c.x = MAX(minX, MIN(maxX, c.x));
    c.y = MAX(minY, MIN(maxY, c.y));
    pill.center = c;
}

@end

@interface LCDebugOverlayWindow : UIWindow
@property (nonatomic, strong) UIView *pillContainer;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation LCDebugOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.rootViewController.presentedViewController != nil) {
        return [super hitTest:point withEvent:event];
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}

@end

// MARK: - Mac Web Console HTML

static NSString *LCDebugWebConsoleHTML(void) {
    return @
    "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'/>"
    "<meta name='viewport' content='width=device-width,initial-scale=1'/>"
    "<title>LiveContainer Debug Studio</title>"
    "<style>"
    ":root{--bg:#0b0f17;--card:rgba(255,255,255,.06);--b:rgba(255,255,255,.12);--acc:#38bdf8;--txt:#f8fafc;--sub:#94a3b8}"
    "*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;background:radial-gradient(circle at 20% 0%,#13223a,#0b0f17 65%);color:var(--txt);min-height:100vh;display:flex;flex-direction:column}"
    "header{padding:12px 18px;border-bottom:1px solid var(--b);backdrop-filter:blur(18px);display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;background:rgba(15,23,42,.72);position:sticky;top:0;z-index:10}"
    ".pills{display:flex;flex-wrap:wrap;gap:8px;align-items:center}.pill{padding:5px 10px;border-radius:999px;background:var(--card);border:1px solid var(--b);font-size:12px;font-weight:600}"
    ".btn{cursor:pointer;padding:6px 12px;border-radius:999px;border:1px solid var(--b);background:rgba(56,189,248,.16);color:var(--txt);font-size:12px;font-weight:600}.btn.on{background:#0284c7;border-color:#38bdf8}.btn:hover{filter:brightness(1.15)}"
    ".tabs{display:flex;gap:6px;padding:10px 18px;border-bottom:1px solid var(--b);flex-wrap:wrap}.tab{cursor:pointer;padding:6px 12px;border-radius:10px;background:transparent;color:var(--sub);border:none;font-weight:600}.tab.active{background:var(--card);color:var(--txt);border:1px solid var(--b)}"
    "main{flex:1;padding:16px 18px;overflow:auto}.panel{display:none}.panel.active{display:block}"
    ".logbox{background:#05080f;border:1px solid var(--b);border-radius:12px;padding:12px;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;max-height:68vh;overflow:auto;white-space:pre-wrap;word-break:break-word}"
    ".row{padding:10px;border:1px solid var(--b);border-radius:12px;background:var(--card);margin-bottom:8px;font-size:12px}"
    ".search{width:100%;max-width:420px;padding:8px 12px;border-radius:10px;border:1px solid var(--b);background:rgba(0,0,0,.35);color:var(--txt);margin-bottom:10px}"
    "code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:#7dd3fc}"
    "</style></head><body>"
    "<header>"
    "<div class='pills'><strong id='title'>LiveContainer Debug</strong><span class='pill' id='p-pid'>PID -</span><span class='pill' id='p-cpu'>CPU -</span><span class='pill' id='p-ram'>RAM -</span><span class='pill' id='p-fps'>FPS -</span><span class='pill' id='p-jit'>JIT-Less</span></div>"
    "<div class='pills'><button class='btn' id='b-xray' onclick=\"act('toggle_xray')\">UI X-Ray</button><button class='btn' id='b-tap' onclick=\"act('toggle_tap_inspect')\">Tap Inspect</button><button class='btn' id='b-notif' onclick=\"act('toggle_notifications')\">Notifs</button><button class='btn' onclick=\"act('memory_warning')\">Mem Warning</button><button class='btn' onclick=\"act('clear_logs')\">Clear Logs</button></div>"
    "</header>"
    "<div class='tabs'>"
    "<button class='tab active' onclick=\"showTab('console',this)\">Console</button>"
    "<button class='tab' onclick=\"showTab('network',this)\">Network</button>"
    "<button class='tab' onclick=\"showTab('events',this)\">UI & Events</button>"
    "<button class='tab' onclick=\"showTab('hierarchy',this);loadHierarchy()\">Hierarchy</button>"
    "<button class='tab' onclick=\"showTab('dylibs',this);loadDylibs();searchClasses()\">Dylibs & ObjC</button>"
    "<button class='tab' onclick=\"showTab('sandbox',this);loadSandbox()\">Sandbox & Keys</button>"
    "<button class='tab' onclick=\"showTab('frida',this);loadFrida()\">Frida / LLDB</button>"
    "</div>"
    "<main>"
    "<div id='tapbanner' class='row' style='display:none'></div>"
    "<div id='console' class='panel active'><input class='search' id='logFilter' placeholder='Filter stdout / stderr / NSLog / OSLog / WebView...' oninput='renderLogs()'/><div class='logbox' id='logbox'></div></div>"
    "<div id='network' class='panel'><div id='netlist'></div></div>"
    "<div id='events' class='panel'><div id='evlist'></div></div>"
    "<div id='hierarchy' class='panel'><div class='logbox' id='hierbox'>Loading...</div></div>"
    "<div id='dylibs' class='panel'><input class='search' id='clsQ' placeholder='Search Objective-C class...' oninput='searchClasses()'/><div id='dylibbox'></div><div id='clsbox'></div></div>"
    "<div id='sandbox' class='panel'><div class='logbox' id='sbox'>Loading...</div></div>"
    "<div id='frida' class='panel'><div class='logbox' id='fbox'>Loading...</div></div>"
    "</main>"
    "<script>"
    "let logs=[],nets=[],evs=[];"
    "function showTab(id,el){document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.getElementById(id).classList.add('active');el.classList.add('active');}"
    "function esc(v){return String(v==null?'':v).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;').replace(/'/g,'&#39;');}"
    "function renderSelectedView(v){if(!v)return;let b=document.getElementById('tapbanner');b.style.display='block';b.innerHTML='<strong>Inspected View:</strong> <code>'+esc(v.class)+'</code> | VC: <code>'+esc(v.viewController||'-')+'</code> | '+esc(v.frame);}"
    "function applyStatus(s){document.getElementById('title').textContent=s.bundleId||'LiveContainer';document.getElementById('p-pid').textContent='PID '+s.pid;document.getElementById('p-cpu').textContent='CPU '+(s.cpuPercent||0).toFixed(1)+'%';document.getElementById('p-ram').textContent='RAM '+(s.memoryMB||0).toFixed(1)+' MB';document.getElementById('p-fps').textContent=(s.fps||0)+' FPS';document.getElementById('p-jit').textContent=s.isJIT?'JIT ON':'JIT-Less';document.getElementById('b-xray').classList.toggle('on',!!s.xrayEnabled);document.getElementById('b-tap').classList.toggle('on',!!s.tapInspectEnabled);document.getElementById('b-notif').classList.toggle('on',!!s.notificationMonitorEnabled);if(s.selectedView)renderSelectedView(s.selectedView);}"
    "function renderLogs(){let q=document.getElementById('logFilter').value.toLowerCase();let el=document.getElementById('logbox');el.textContent=logs.filter(l=>!q||(l.text||'').toLowerCase().includes(q)||(l.stream||'').toLowerCase().includes(q)||(l.subsystem||'').toLowerCase().includes(q)).map(l=>'['+l.stream+(l.subsystem?':'+l.subsystem:'')+'] '+l.text).join('\\n');el.scrollTop=el.scrollHeight;}"
    "function renderNets(){let el=document.getElementById('netlist');el.innerHTML=nets.map(n=>'<div class=\"row\"><div><strong>'+esc(n.method)+'</strong> ['+esc(n.statusCode)+'] '+esc(n.durationMs)+'ms · '+esc(n.bytes)+'B · <code>'+esc(n.url)+'</code></div><details style=\"margin-top:6px\"><summary>Headers, Body & cURL</summary><pre>'+esc((n.curl||'')+'\\n\\nRequest Headers: '+JSON.stringify(n.requestHeaders||{},null,2)+'\\n\\nResponse Headers: '+JSON.stringify(n.responseHeaders||{},null,2)+'\\n\\nRequest Body:\\n'+(n.requestBodyPreview||'')+'\\n\\nResponse Preview:\\n'+(n.responseBodyPreview||''))+'</pre></details></div>').join('');}"
    "function renderEvs(){let el=document.getElementById('evlist');el.innerHTML=evs.map(e=>'<div class=\"row\"><strong>['+esc((e.kind||'ui').toUpperCase())+']</strong> '+esc(e.title)+' <span style=\"color:var(--sub)\">'+esc(e.detail||'')+' · VC: '+esc(e.viewController||'-')+'</span></div>').join('');}"
    "async function act(name){await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:name})});if(name==='clear_logs'){logs=[];renderLogs();}if(name==='clear_events'){evs=[];renderEvs();}}"
    "async function loadHierarchy(){let r=await fetch('/api/hierarchy');document.getElementById('hierbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function loadDylibs(){let r=await fetch('/api/dylibs');let d=await r.json();document.getElementById('dylibbox').innerHTML='<h4>Loaded Images ('+d.length+')</h4><div class=\"logbox\" style=\"max-height:220px\">'+d.map(x=>esc(x.base)+'  '+esc(x.path)).join('\\n')+'</div>';}"
    "async function searchClasses(){let q=document.getElementById('clsQ').value;let r=await fetch('/api/classes?q='+encodeURIComponent(q));let d=await r.json();document.getElementById('clsbox').innerHTML='<h4>ObjC Classes ('+d.length+')</h4><div class=\"logbox\" style=\"max-height:220px\">'+d.map(esc).join('\\n')+'</div>';}"
    "async function loadSandbox(){let r=await fetch('/api/sandbox');document.getElementById('sbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function loadFrida(){let r=await fetch('/api/frida');document.getElementById('fbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function boot(){"
    "applyStatus(await(await fetch('/api/status')).json());"
    "logs=await(await fetch('/api/logs')).json();renderLogs();"
    "nets=await(await fetch('/api/network')).json();renderNets();"
    "evs=await(await fetch('/api/events')).json();renderEvs();"
    "const es=new EventSource('/api/stream');"
    "es.addEventListener('telemetry',e=>applyStatus(JSON.parse(e.data)));"
    "es.addEventListener('log',e=>{logs.push(JSON.parse(e.data));if(logs.length>2000)logs.shift();renderLogs();});"
    "es.addEventListener('network',e=>{nets.unshift(JSON.parse(e.data));if(nets.length>500)nets.pop();renderNets();});"
    "es.addEventListener('uievent',e=>{evs.unshift(JSON.parse(e.data));if(evs.length>500)evs.pop();renderEvs();});"
    "es.addEventListener('tap',e=>renderSelectedView(JSON.parse(e.data)));"
    "}"
    "boot();"
    "</script></body></html>";
}

// MARK: - Core Server & Telemetry

@interface LCDebugServer () {
    os_unfair_lock _dataLock;
}
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) dispatch_queue_t osLogQueue;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *logs;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *networkEntries;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *uiEvents;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sseClientFDs;
@property (nonatomic, strong) NSMutableString *stdoutLineBuffer;
@property (nonatomic, strong) NSMutableString *stderrLineBuffer;

@property (nonatomic, assign) int localListenFD;
@property (atomic, assign) uint16_t localPort;
@property (nonatomic, strong) dispatch_source_t localAcceptSource;

@property (nonatomic, assign) int lanListenFD;
@property (atomic, assign) uint16_t lanPort;
@property (nonatomic, strong) dispatch_source_t lanAcceptSource;
@property (nonatomic, assign) DNSServiceRef bonjourRef;
@property (nonatomic, strong) dispatch_source_t bonjourSource;
@property (nonatomic, copy) NSString *lastPublishedLANIP;

@property (nonatomic, assign) int savedStdoutFD;
@property (nonatomic, assign) int savedStderrFD;
@property (nonatomic, strong) dispatch_source_t stdoutSource;
@property (nonatomic, strong) dispatch_source_t stderrSource;
@property (nonatomic, strong) dispatch_source_t osLogTimer;
@property (nonatomic, strong) OSLogStore *osLogStore;
@property (nonatomic, strong) NSDate *lastOSLogDate;
@property (nonatomic, strong) NSMutableSet<NSString *> *seenAtLastOSLogDate;
@property (atomic, assign) BOOL osLogPaused;

@property (nonatomic, strong) dispatch_source_t telemetryTimer;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSUInteger frameCounter;
@property (nonatomic, assign) CFTimeInterval lastFPSTimestamp;
@property (atomic, assign) NSInteger currentFPS;
@property (atomic, assign) double lastCPUPercent;
@property (atomic, assign) double lastMemoryMB;
@property (atomic, assign) NSUInteger lastThreadCount;
@property (atomic, assign) BOOL lastJITState;
@property (atomic, assign) NSUInteger errorLogCount;

@property (atomic, assign) BOOL xrayEnabled;
@property (atomic, assign) BOOL tapInspectEnabled;
@property (atomic, assign) BOOL notificationMonitorEnabled;
@property (atomic, assign) BOOL lanEnabled;
@property (nonatomic, copy) NSString *authToken;
@property (nonatomic, strong) NSDictionary *selectedViewInfo;
@property (nonatomic, strong) LCDebugInspectOverlayView *inspectOverlay;
@property (nonatomic, strong) LCDebugOverlayWindow *overlayWindow;
@property (nonatomic, assign) BOOL shouldShowInAppOverlay;

// Forward declarations to avoid -Wundeclared-selector warnings
- (void)onDisplayLinkTick:(CADisplayLink *)link;
- (void)handleSceneOrWindowActivated:(NSNotification *)note;
- (void)handleAppDidEnterBackground:(NSNotification *)note;
- (void)handleAppWillEnterForeground:(NSNotification *)note;
- (void)handleOverlayPillPan:(UIPanGestureRecognizer *)pan;
- (void)handleOverlayPillTap;
@end

static NSString *LCDebugGenerateRandomToken(void) {
    uint8_t bytes[16] = {0};
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        arc4random_buf(bytes, sizeof(bytes));
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(bytes) * 2];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return [hex copy];
}

static BOOL LCDebugConstantTimeEquals(NSString *a, NSString *b) {
    if (!a || !b) return NO;
    const char *ca = a.UTF8String;
    const char *cb = b.UTF8String;
    if (!ca || !cb) return NO;
    size_t la = strlen(ca);
    size_t lb = strlen(cb);
    if (la != lb || la == 0) return NO;
    uint8_t diff = 0;
    for (size_t i = 0; i < la; i++) {
        diff |= (uint8_t)ca[i] ^ (uint8_t)cb[i];
    }
    return diff == 0;
}

static void LCSendAllBlocking(int fd, const uint8_t *bytes, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t n = send(fd, bytes + sent, length - sent, 0);
        if (n <= 0) break;
        sent += (size_t)n;
    }
}

@implementation LCDebugServer

+ (instancetype)shared {
    static LCDebugServer *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCDebugServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dataLock = OS_UNFAIR_LOCK_INIT;
        _serverQueue = dispatch_queue_create("com.kdt.livecontainer.debugserver", DISPATCH_QUEUE_SERIAL);
        _osLogQueue = dispatch_queue_create("com.kdt.livecontainer.debug.oslog", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray array];
        _networkEntries = [NSMutableArray array];
        _uiEvents = [NSMutableArray array];
        _sseClientFDs = [NSMutableArray array];
        _stdoutLineBuffer = [NSMutableString string];
        _stderrLineBuffer = [NSMutableString string];
        _localListenFD = -1;
        _lanListenFD = -1;
        _savedStdoutFD = -1;
        _savedStderrFD = -1;
        _bonjourRef = NULL;
        _authToken = LCDebugGenerateRandomToken();
        _lastOSLogDate = [NSDate dateWithTimeIntervalSinceNow:-2.0];
        _seenAtLastOSLogDate = [NSMutableSet set];
    }
    return self;
}

- (void)start {
    signal(SIGPIPE, SIG_IGN);
    atomic_store(&gLCDebugAgentActive, YES);

    [self pruneDeadSessionFiles];
    [self installCrashHooks];
    [self installLogTee];
    [self installNSLogHook];
    [self startOSLogPolling];
    [self installNetworkHooks];
    [self installWebViewHooks];
    [self installUIAndEventHooks];
    [self startLocalServer];
    [self startTelemetry];

    [self appendLogStream:@"debug"
                    level:@"info"
                subsystem:@"LiveContainer"
                 category:@"agent"
                     text:[NSString stringWithFormat:@"Debug Agent started (PID %d, 100%% JIT-Less hooks active)", getpid()]];

    if ([NSUserDefaults respondsToSelector:@selector(lcSharedDefaults)]) {
        if ([[NSUserDefaults lcSharedDefaults] boolForKey:@"LCDebugLANEnabled"]) {
            [self setLANEnabled:YES];
        }
    }

    const char *studioHosted = getenv("LC_DEBUG_STUDIO_HOSTED");
    self.shouldShowInAppOverlay = !(studioHosted && studioHosted[0] == '1');
    if (self.shouldShowInAppOverlay) {
        [self observeScenesForOverlay];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachOverlayWindowIfNeeded];
        });
    }
}

// MARK: - Crash, Log Tee, NSLog & OSLogStore (100% JIT-less)

- (void)installCrashHooks {
    const char *homeEnv = getenv("HOME");
    NSString *home = homeEnv ? @(homeEnv) : NSHomeDirectory();
    NSString *crashPath = [[home stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"LCDebugLastCrash.log"];
    if (crashPath.UTF8String) {
        strlcpy(gLCCrashLogPath, crashPath.UTF8String, sizeof(gLCCrashLogPath));
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:crashPath]) {
        NSString *prevCrash = [NSString stringWithContentsOfFile:crashPath encoding:NSUTF8StringEncoding error:nil];
        if (prevCrash.length > 0) {
            [self appendLogStream:@"crash" level:@"fault" subsystem:@"PreviousCrash" category:@"crash" text:prevCrash];
        }
        [NSFileManager.defaultManager removeItemAtPath:crashPath error:nil];
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = LCDebugSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    int signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &sa, NULL);
    }
}

- (dispatch_source_t)installPipeTeeForFD:(int)targetFD
                               isStderr:(BOOL)isStderr
                           savedFDOut:(int *)savedFDOut {
    int pfd[2];
    if (pipe(pfd) != 0) return nil;

    int saved = dup(targetFD);
    if (savedFDOut) *savedFDOut = saved;
    dup2(pfd[1], targetFD);
    close(pfd[1]);
    // Force immediate flushing over pipe instead of 4KB libc block buffering
    if (isStderr) {
        setvbuf(stderr, NULL, _IONBF, 0);
    } else {
        setvbuf(stdout, NULL, _IOLBF, 0);
    }
    fcntl(pfd[0], F_SETFL, O_NONBLOCK);
    int readFD = pfd[0];

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)readFD, 0, self.serverQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        char buf[4096];
        for (;;) {
            ssize_t n = read(readFD, buf, sizeof(buf) - 1);
            if (n > 0) {
                if (saved >= 0) write(saved, buf, (size_t)n);
                buf[n] = '\0';
                NSString *chunk = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSISOLatin1StringEncoding];
                if (chunk.length > 0) [weakSelf consumePipeChunk:chunk isStderr:isStderr];
            } else if (n == 0) {
                // EOF: cancel source so dispatch does not busy-spin at 100% CPU
                dispatch_source_cancel(source);
                break;
            } else {
                break;
            }
        }
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(readFD);
    });
    dispatch_resume(source);
    return source;
}

- (void)installLogTee {
    int savedOut = -1;
    self.stdoutSource = [self installPipeTeeForFD:STDOUT_FILENO isStderr:NO savedFDOut:&savedOut];
    self.savedStdoutFD = savedOut;

    int savedErr = -1;
    self.stderrSource = [self installPipeTeeForFD:STDERR_FILENO isStderr:YES savedFDOut:&savedErr];
    self.savedStderrFD = savedErr;
}

- (void)consumePipeChunk:(NSString *)chunk isStderr:(BOOL)isStderr {
    NSMutableString *buffer = isStderr ? self.stderrLineBuffer : self.stdoutLineBuffer;
    [buffer appendString:chunk];
    NSString *stream = isStderr ? @"stderr" : @"stdout";
    NSString *level = isStderr ? @"error" : @"info";

    for (;;) {
        NSRange nl = [buffer rangeOfString:@"\n"];
        if (nl.location == NSNotFound) break;
        NSString *line = [buffer substringToIndex:nl.location];
        if ([line hasSuffix:@"\r"]) {
            line = [line substringToIndex:line.length - 1];
        }
        [buffer deleteCharactersInRange:NSMakeRange(0, NSMaxRange(nl))];
        if (line.length > 0) {
            if (isStderr && LCMatchesRecentNSLogMessage(line)) {
                continue; // Suppress duplicate stderr echo of already-captured NSLog
            }
            [self appendLogEntryOnServerQueueStream:stream level:level subsystem:nil category:nil text:line];
        }
    }
    if (buffer.length > 2048) {
        NSString *line = [buffer copy];
        [buffer setString:@""];
        [self appendLogEntryOnServerQueueStream:stream level:level subsystem:nil category:nil text:line];
    }
}

- (void)installNSLogHook {
    kern_return_t (*rebindGlobal)(void *, void *) = (kern_return_t (*)(void *, void *))dlsym(RTLD_DEFAULT, "LCRebindGlobalSymbol");
    void *origNSLogPtr = dlsym(RTLD_DEFAULT, "NSLog");
    void *origNSLogvPtr = dlsym(RTLD_DEFAULT, "NSLogv");
    if (!rebindGlobal || !origNSLogPtr || !origNSLogvPtr) {
        return;
    }
    g_orig_NSLogv = (void (*)(NSString *, va_list))origNSLogvPtr;
    rebindGlobal(origNSLogPtr, (void *)LCDebugHook_NSLog);
    rebindGlobal(origNSLogvPtr, (void *)LCDebugHook_NSLogv);
}

- (void)startOSLogPolling {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(handleAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(handleAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];

    dispatch_async(self.osLogQueue, ^{
        NSError *err = nil;
        OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&err];
        if (!store || err) {
            return;
        }
        self.osLogStore = store;
        self.osLogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.osLogQueue);
        dispatch_source_set_timer(self.osLogTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                                  (uint64_t)(0.6 * NSEC_PER_SEC),
                                  (uint64_t)(0.15 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.osLogTimer, ^{
            if (!weakSelf.osLogPaused) {
                [weakSelf pollOSLogStore];
            }
        });
        dispatch_resume(self.osLogTimer);
    });
}

- (void)handleAppDidEnterBackground:(NSNotification *)note {
    self.osLogPaused = YES;
}

- (void)handleAppWillEnterForeground:(NSNotification *)note {
    self.osLogPaused = NO;
}

- (void)pollOSLogStore {
    if (!self.osLogStore) return;
    @autoreleasepool {
        NSDate *cursor = self.lastOSLogDate ?: [NSDate dateWithTimeIntervalSinceNow:-2.0];
        OSLogPosition *pos = [self.osLogStore positionWithDate:cursor];
        NSError *err = nil;
        OSLogEnumerator *enumerator = [self.osLogStore entriesEnumeratorWithOptions:0 position:pos predicate:nil error:&err];
        if (!enumerator || err) return;

        NSDate *newest = cursor;
        NSUInteger emitted = 0;
        id obj = nil;
        while ((obj = [enumerator nextObject]) != nil) {
            if (![obj isKindOfClass:OSLogEntryLog.class]) continue;
            OSLogEntryLog *entry = (OSLogEntryLog *)obj;
            if (!entry.date) continue;

            NSComparisonResult cmp = [entry.date compare:cursor];
            if (cmp == NSOrderedAscending) continue;

            NSString *msg = entry.composedMessage;
            if (msg.length == 0) continue;

            NSString *fingerprint = [NSString stringWithFormat:@"%llu:%llu:%@",
                                     (unsigned long long)entry.threadIdentifier,
                                     (unsigned long long)entry.activityIdentifier,
                                     msg];
            if (cmp == NSOrderedSame && [self.seenAtLastOSLogDate containsObject:fingerprint]) {
                continue;
            }

            if ([entry.date compare:newest] == NSOrderedDescending) {
                newest = entry.date;
                [self.seenAtLastOSLogDate removeAllObjects];
            }
            if ([entry.date isEqualToDate:newest]) {
                [self.seenAtLastOSLogDate addObject:fingerprint];
            }

            NSString *subsystem = entry.subsystem ?: @"";
            if ([subsystem hasPrefix:@"com.kdt.livecontainer.debug"]) continue;
            if (subsystem.length == 0 && LCMatchesRecentNSLogMessage(msg)) continue;

            NSString *level = @"info";
            switch (entry.level) {
                case OSLogEntryLogLevelDebug:  level = @"debug"; break;
                case OSLogEntryLogLevelInfo:   level = @"info"; break;
                case OSLogEntryLogLevelNotice: level = @"notice"; break;
                case OSLogEntryLogLevelError:  level = @"error"; break;
                case OSLogEntryLogLevelFault:  level = @"fault"; break;
                default: level = @"info"; break;
            }
            [self appendLogStream:@"oslog" level:level subsystem:subsystem category:(entry.category ?: @"") text:msg];
            emitted++;
            if (emitted >= 150) break;
        }
        self.lastOSLogDate = newest;
    }
}

// MARK: - Network, WebView & UI Hooks Installation

- (void)installNetworkHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        swizzleClassMethod(NSURLSession.class,
                           @selector(sessionWithConfiguration:delegate:delegateQueue:),
                           @selector(lcDebug_sessionWithConfiguration:delegate:delegateQueue:));

        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(dataTaskWithRequest:completionHandler:),
                                         @selector(lcDebug_dataTaskWithRequest:completionHandler:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(dataTaskWithURL:completionHandler:),
                                         @selector(lcDebug_dataTaskWithURL:completionHandler:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(uploadTaskWithRequest:fromData:completionHandler:),
                                         @selector(lcDebug_uploadTaskWithRequest:fromData:completionHandler:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(downloadTaskWithRequest:completionHandler:),
                                         @selector(lcDebug_downloadTaskWithRequest:completionHandler:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(dataTaskWithRequest:),
                                         @selector(lcDebug_dataTaskWithRequest:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(dataTaskWithURL:),
                                         @selector(lcDebug_dataTaskWithURL:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(uploadTaskWithRequest:fromData:),
                                         @selector(lcDebug_uploadTaskWithRequest:fromData:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(webSocketTaskWithRequest:),
                                         @selector(lcDebug_webSocketTaskWithRequest:));
        LCDebugSafeSwizzleInstanceMethod(NSURLSession.class,
                                         @selector(webSocketTaskWithURL:),
                                         @selector(lcDebug_webSocketTaskWithURL:));

        // Safe swizzle for base NSURLSessionTask + concrete local/background cluster subclasses
        LCDebugSafeSwizzleInstanceMethod(NSURLSessionTask.class,
                                         @selector(resume),
                                         @selector(lcDebug_resume));
        LCHookTaskClusterResumeClass(NSClassFromString(@"__NSCFLocalSessionTask"));
        LCHookTaskClusterResumeClass(NSClassFromString(@"__NSCFBackgroundSessionTask"));
    });
}

- (void)installWebViewHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCDebugSafeSwizzleInstanceMethod(WKWebView.class,
                                         @selector(initWithFrame:configuration:),
                                         @selector(lcDebug_initWithFrame:configuration:));
    });
}

- (void)installUIAndEventHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCDebugSafeSwizzleInstanceMethod(UIView.class,
                                         @selector(layoutSubviews),
                                         @selector(lcDebug_layoutSubviews));
        LCDebugSafeSwizzleInstanceMethod(UIApplication.class,
                                         @selector(sendEvent:),
                                         @selector(lcDebug_sendEvent:));
        LCDebugSafeSwizzleInstanceMethod(UIViewController.class,
                                         @selector(viewDidAppear:),
                                         @selector(lcDebug_viewDidAppear:));
        LCDebugSafeSwizzleInstanceMethod(UIViewController.class,
                                         @selector(presentViewController:animated:completion:),
                                         @selector(lcDebug_presentViewController:animated:completion:));
        LCDebugSafeSwizzleInstanceMethod(UITabBarController.class,
                                         @selector(setSelectedIndex:),
                                         @selector(lcDebug_setSelectedIndex:));
        LCDebugSafeSwizzleInstanceMethod(UITabBarController.class,
                                         @selector(setSelectedViewController:),
                                         @selector(lcDebug_setSelectedViewController:));
        LCDebugSafeSwizzleInstanceMethod(UINavigationController.class,
                                         @selector(pushViewController:animated:),
                                         @selector(lcDebug_pushViewController:animated:));
        LCDebugSafeSwizzleInstanceMethod(UINavigationController.class,
                                         @selector(popViewControllerAnimated:),
                                         @selector(lcDebug_popViewControllerAnimated:));
        LCDebugSafeSwizzleInstanceMethod(UIWindow.class,
                                         @selector(makeKeyAndVisible),
                                         @selector(lcDebug_makeKeyAndVisible));
        LCDebugSafeSwizzleInstanceMethod(NSNotificationCenter.class,
                                         @selector(postNotificationName:object:userInfo:),
                                         @selector(lcDebug_postNotificationName:object:userInfo:));
    });
}

// MARK: - Thread-Safe Event Ingestion & Snapshots

- (void)appendLogStream:(NSString *)stream text:(NSString *)text {
    [self appendLogStream:stream level:([stream isEqualToString:@"stderr"] ? @"error" : @"info") subsystem:nil category:nil text:text];
}

- (void)appendLogStream:(NSString *)stream
                  level:(NSString *)level
              subsystem:(NSString *)subsystem
               category:(NSString *)category
                   text:(NSString *)text {
    if (text.length == 0) return;
    dispatch_async(self.serverQueue, ^{
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            [self appendLogEntryOnServerQueueStream:stream level:level subsystem:subsystem category:category text:line];
        }
    });
}

- (void)appendLogEntryOnServerQueueStream:(NSString *)stream
                                    level:(NSString *)level
                                subsystem:(NSString *)subsystem
                                 category:(NSString *)category
                                     text:(NSString *)text {
    NSString *safeStream = stream ?: @"stdout";
    NSString *safeLevel = level ?: @"info";
    if ([safeStream isEqualToString:@"stderr"] || [safeStream isEqualToString:@"crash"] ||
        [safeLevel isEqualToString:@"error"] || [safeLevel isEqualToString:@"fault"]) {
        self.errorLogCount = self.errorLogCount + 1;
    }
    NSDictionary *entry = @{
        @"id": NSUUID.UUID.UUIDString,
        @"timestamp": @(CFAbsoluteTimeGetCurrent()),
        @"stream": safeStream,
        @"level": safeLevel,
        @"subsystem": subsystem ?: @"",
        @"category": category ?: @"",
        @"text": text ?: @""
    };
    os_unfair_lock_lock(&_dataLock);
    [self.logs addObject:entry];
    if (self.logs.count > 2000) {
        [self.logs removeObjectsInRange:NSMakeRange(0, self.logs.count - 2000)];
    }
    os_unfair_lock_unlock(&_dataLock);
    [self broadcastSSEEvent:"log" payload:entry];
}

- (void)recordNetworkEvent:(NSDictionary *)entry {
    if (!entry) return;
    dispatch_async(self.serverQueue, ^{
        os_unfair_lock_lock(&self->_dataLock);
        [self.networkEntries insertObject:entry atIndex:0];
        if (self.networkEntries.count > 500) {
            [self.networkEntries removeLastObject];
        }
        os_unfair_lock_unlock(&self->_dataLock);
        [self broadcastSSEEvent:"network" payload:entry];
    });
}

- (void)recordUIEventKind:(NSString *)kind
                    title:(NSString *)title
                   detail:(NSString *)detail
                   target:(NSString *)target
           viewController:(NSString *)vcName
                   window:(NSString *)windowName {
    NSDictionary *entry = @{
        @"id": NSUUID.UUID.UUIDString,
        @"timestamp": @(CFAbsoluteTimeGetCurrent()),
        @"kind": kind ?: @"ui",
        @"title": title ?: @"",
        @"detail": detail ?: @"",
        @"target": target ?: @"",
        @"viewController": vcName ?: @"",
        @"window": windowName ?: @""
    };
    dispatch_async(self.serverQueue, ^{
        os_unfair_lock_lock(&self->_dataLock);
        [self.uiEvents insertObject:entry atIndex:0];
        if (self.uiEvents.count > 500) {
            [self.uiEvents removeLastObject];
        }
        os_unfair_lock_unlock(&self->_dataLock);
        [self broadcastSSEEvent:"uievent" payload:entry];
    });
}

- (NSArray<NSDictionary *> *)logsSnapshot {
    os_unfair_lock_lock(&_dataLock);
    NSArray *copy = [self.logs copy];
    os_unfair_lock_unlock(&_dataLock);
    return copy;
}

- (NSArray<NSDictionary *> *)networkSnapshot {
    os_unfair_lock_lock(&_dataLock);
    NSArray *copy = [self.networkEntries copy];
    os_unfair_lock_unlock(&_dataLock);
    return copy;
}

- (NSArray<NSDictionary *> *)uiEventsSnapshot {
    os_unfair_lock_lock(&_dataLock);
    NSArray *copy = [self.uiEvents copy];
    os_unfair_lock_unlock(&_dataLock);
    return copy;
}

- (void)clearLogs {
    os_unfair_lock_lock(&_dataLock);
    [self.logs removeAllObjects];
    os_unfair_lock_unlock(&_dataLock);
    self.errorLogCount = 0;
}

- (void)clearNetwork {
    os_unfair_lock_lock(&_dataLock);
    [self.networkEntries removeAllObjects];
    os_unfair_lock_unlock(&_dataLock);
}

- (void)clearUIEvents {
    os_unfair_lock_lock(&_dataLock);
    [self.uiEvents removeAllObjects];
    os_unfair_lock_unlock(&_dataLock);
}

// MARK: - Telemetry & FPS

- (void)startTelemetry {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLinkTick:)];
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });

    self.telemetryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.serverQueue);
    dispatch_source_set_timer(self.telemetryTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.telemetryTimer, ^{
        [weakSelf sampleProcessMetrics];
    });
    dispatch_resume(self.telemetryTimer);
}

- (void)onDisplayLinkTick:(CADisplayLink *)link {
    if (self.lastFPSTimestamp == 0) {
        self.lastFPSTimestamp = link.timestamp;
        return;
    }
    self.frameCounter += 1;
    CFTimeInterval delta = link.timestamp - self.lastFPSTimestamp;
    if (delta >= 1.0) {
        self.currentFPS = (NSInteger)llround((double)self.frameCounter / delta);
        self.frameCounter = 0;
        self.lastFPSTimestamp = link.timestamp;
        if (self.overlayWindow.statusLabel) {
            NSUInteger errs = self.errorLogCount;
            if (errs > 0) {
                self.overlayWindow.statusLabel.text = [NSString stringWithFormat:@"DBG %ld FPS · %.0fM · %lu!", (long)self.currentFPS, self.lastMemoryMB, (unsigned long)errs];
            } else {
                self.overlayWindow.statusLabel.text = [NSString stringWithFormat:@"DBG %ld FPS · %.0fM", (long)self.currentFPS, self.lastMemoryMB];
            }
        }
    }
}

- (void)sampleProcessMetrics {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    double memMB = 0.0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        memMB = (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
    } else {
        mach_task_basic_info_data_t basicInfo;
        mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basicInfo, &basicCount) == KERN_SUCCESS) {
            memMB = (double)basicInfo.resident_size / (1024.0 * 1024.0);
        }
    }

    thread_array_t threadList = NULL;
    mach_msg_type_number_t threadCount = 0;
    double cpuTotal = 0.0;
    if (task_threads(mach_task_self(), &threadList, &threadCount) == KERN_SUCCESS && threadList) {
        for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
            thread_info_data_t thInfo;
            mach_msg_type_number_t thInfoCount = THREAD_INFO_MAX;
            if (thread_info(threadList[i], THREAD_BASIC_INFO, (thread_info_t)thInfo, &thInfoCount) == KERN_SUCCESS) {
                thread_basic_info_t basic = (thread_basic_info_t)thInfo;
                if (!(basic->flags & TH_FLAGS_IDLE)) {
                    cpuTotal += ((double)basic->cpu_usage / (double)TH_USAGE_SCALE) * 100.0;
                }
            }
            mach_port_deallocate(mach_task_self(), threadList[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threadList, threadCount * sizeof(thread_t));
    }

    uint32_t csFlags = 0;
    BOOL jit = (csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags)) == 0) && ((csFlags & CS_DEBUGGED) != 0);

    self.lastCPUPercent = cpuTotal;
    self.lastMemoryMB = memMB;
    self.lastThreadCount = threadCount;
    self.lastJITState = jit;

    // Only re-write session file if LAN IP actually changed (avoid 1Hz disk & cfprefsd churn)
    if (self.lanEnabled) {
        NSString *currentIP = LCBestLANIPv4Address() ?: @"";
        if (![currentIP isEqualToString:(self.lastPublishedLANIP ?: @"")]) {
            [self publishSharedSessionInfoWithLANIP:currentIP];
        }
    }
    [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionary]];
}

- (NSDictionary *)currentStatusDictionary {
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"Unknown";
    BOOL lan = self.lanEnabled;
    NSString *lanIP = lan ? (self.lastPublishedLANIP.length > 0 ? self.lastPublishedLANIP : (LCBestLANIPv4Address() ?: @"")) : @"";

    os_unfair_lock_lock(&_dataLock);
    NSDictionary *selView = self.selectedViewInfo;
    os_unfair_lock_unlock(&_dataLock);

    return @{
        @"pid": @(getpid()),
        @"bundleId": bundleId,
        @"localPort": @(self.localPort),
        @"lanPort": @(self.lanPort),
        @"lanEnabled": @(lan),
        @"lanIP": lanIP,
        @"authToken": self.authToken ?: @"",
        @"cpuPercent": @(self.lastCPUPercent),
        @"memoryMB": @(self.lastMemoryMB),
        @"fps": @(self.currentFPS),
        @"threadCount": @(self.lastThreadCount),
        @"isJIT": @(self.lastJITState),
        @"xrayEnabled": @(self.xrayEnabled),
        @"tapInspectEnabled": @(self.tapInspectEnabled),
        @"notificationMonitorEnabled": @(self.notificationMonitorEnabled),
        @"selectedView": selView ?: NSNull.null,
        @"profileTelemetry": LCProfileGetTelemetrySnapshot() ?: @{}
    };
}

- (void)pruneDeadSessionFiles {
    if (![NSUserDefaults respondsToSelector:@selector(lcAppGroupPath)]) return;
    NSString *groupPath = [NSUserDefaults lcAppGroupPath];
    if (groupPath.length == 0) return;
    NSString *dir = [groupPath stringByAppendingPathComponent:@"Library/Caches/LCDebugSessions"];
    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in files) {
        if (![name hasPrefix:@"pid-"] || ![name hasSuffix:@".json"]) continue;
        NSString *numPart = [[name substringFromIndex:4] stringByDeletingPathExtension];
        pid_t filePID = (pid_t)numPart.intValue;
        if (filePID > 0 && filePID != getpid() && kill(filePID, 0) != 0 && errno == ESRCH) {
            [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    }
}

- (void)publishSharedSessionInfoWithLANIP:(NSString *)resolvedLANIP {
    uint16_t port = self.localPort;
    if (port == 0) return;
    NSString *lanIP = self.lanEnabled ? (resolvedLANIP ?: LCBestLANIPv4Address() ?: @"") : @"";
    self.lastPublishedLANIP = lanIP;
    NSDictionary *session = @{
        @"pid": @(getpid()),
        @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"Unknown",
        @"localPort": @(port),
        @"lanPort": @(self.lanPort),
        @"lanEnabled": @(self.lanEnabled),
        @"lanIP": lanIP,
        @"authToken": self.authToken ?: @"",
        @"updatedAt": @(CFAbsoluteTimeGetCurrent())
    };

    if ([NSUserDefaults respondsToSelector:@selector(lcAppGroupPath)]) {
        NSString *groupPath = [NSUserDefaults lcAppGroupPath];
        if (groupPath.length > 0) {
            NSString *dir = [groupPath stringByAppendingPathComponent:@"Library/Caches/LCDebugSessions"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"pid-%d.json", getpid()]];
            NSData *json = LCJSONDataFromObject(session);
            [json writeToFile:filePath atomically:YES];
        }
    }

    if ([NSUserDefaults respondsToSelector:@selector(lcSharedDefaults)]) {
        [[NSUserDefaults lcSharedDefaults] setObject:session forKey:@"LCDebugActiveSession"];
    }
}

// MARK: - HTTP + Non-Blocking SSE Socket Server

- (int)bindListeningSocketWithAddress:(in_addr_t)addr outPort:(uint16_t *)outPort {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET;
    sin.sin_addr.s_addr = htonl(addr);
    sin.sin_port = htons(0);

    if (bind(fd, (const struct sockaddr *)&sin, sizeof(sin)) != 0 || listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }

    socklen_t slen = sizeof(sin);
    if (getsockname(fd, (struct sockaddr *)&sin, &slen) == 0 && outPort) {
        *outPort = ntohs(sin.sin_port);
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    return fd;
}

- (void)startLocalServer {
    dispatch_async(self.serverQueue, ^{
        uint16_t port = 0;
        int fd = [self bindListeningSocketWithAddress:INADDR_LOOPBACK outPort:&port];
        if (fd < 0) return;
        self.localListenFD = fd;
        self.localPort = port;
        atomic_store(&gLCDebugLocalPort, port);
        self.localAcceptSource = [self makeAcceptSourceForSocket:fd];
        [self publishSharedSessionInfoWithLANIP:nil];
    });
}

- (void)setLANEnabled:(BOOL)enabled {
    dispatch_async(self.serverQueue, ^{
        if (self.lanEnabled == enabled) return;
        self.lanEnabled = enabled;
        if (enabled) {
            uint16_t port = 0;
            int fd = [self bindListeningSocketWithAddress:INADDR_ANY outPort:&port];
            if (fd >= 0) {
                self.lanListenFD = fd;
                self.lanPort = port;
                atomic_store(&gLCDebugLANPort, port);
                self.lanAcceptSource = [self makeAcceptSourceForSocket:fd];
                [self startBonjourServiceWithPort:port];
            } else {
                self.lanEnabled = NO;
            }
        } else {
            [self stopBonjourService];
            if (self.lanAcceptSource) {
                dispatch_source_cancel(self.lanAcceptSource);
                self.lanAcceptSource = nil;
            }
            self.lanListenFD = -1;
            self.lanPort = 0;
            atomic_store(&gLCDebugLANPort, 0);
        }
        [self publishSharedSessionInfoWithLANIP:nil];
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionary]];
    });
}

- (void)startBonjourServiceWithPort:(uint16_t)port {
    [self stopBonjourService];
    NSString *name = [NSString stringWithFormat:@"LiveContainer Debug (%@)", NSBundle.mainBundle.bundleIdentifier ?: @"App"];
    DNSServiceRef ref = NULL;
    DNSServiceErrorType err = DNSServiceRegister(&ref, 0, 0, name.UTF8String, "_http._tcp", "local.", NULL, htons(port), 0, NULL, NULL, NULL);
    if (err == kDNSServiceErr_NoError && ref) {
        self.bonjourRef = ref;
        int sockFD = DNSServiceRefSockFD(ref);
        if (sockFD >= 0) {
            self.bonjourSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)sockFD, 0, self.serverQueue);
            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(self.bonjourSource, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.bonjourRef) return;
                if (DNSServiceProcessResult(strongSelf.bonjourRef) != kDNSServiceErr_NoError) {
                    // Prevent 100% CPU spin if mDNSResponder disconnects on suspend
                    [strongSelf stopBonjourService];
                }
            });
            dispatch_source_set_cancel_handler(self.bonjourSource, ^{
                if (ref) DNSServiceRefDeallocate(ref);
            });
            dispatch_resume(self.bonjourSource);
        }
    }
}

- (void)stopBonjourService {
    if (self.bonjourSource) {
        dispatch_source_cancel(self.bonjourSource);
        self.bonjourSource = nil;
        self.bonjourRef = NULL;
    } else if (self.bonjourRef) {
        DNSServiceRefDeallocate(self.bonjourRef);
        self.bonjourRef = NULL;
    }
}

- (dispatch_source_t)makeAcceptSourceForSocket:(int)listenFD {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)listenFD, 0, self.serverQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        for (;;) {
            struct sockaddr_in clientAddr;
            socklen_t len = sizeof(clientAddr);
            int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &len);
            if (clientFD < 0) break;
            int yes = 1;
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            BOOL isLoopback = (clientAddr.sin_family == AF_INET && ntohl(clientAddr.sin_addr.s_addr) == INADDR_LOOPBACK);
            [weakSelf handleClientSocket:clientFD isLoopback:isLoopback];
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(listenFD);
    });
    dispatch_resume(src);
    return src;
}

- (void)handleClientSocket:(int)clientFD isLoopback:(BOOL)isLoopback {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct timeval rcvTV = { .tv_sec = 2, .tv_usec = 0 };
        struct timeval sndTV = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTV, sizeof(rcvTV));
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &sndTV, sizeof(sndTV));

        NSMutableData *raw = [NSMutableData data];
        char buf[4096];
        NSRange headerEnd = NSMakeRange(NSNotFound, 0);
        NSData *crlf = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        for (int tries = 0; tries < 16; tries++) {
            ssize_t n = recv(clientFD, buf, sizeof(buf), 0);
            if (n <= 0) break;
            [raw appendBytes:buf length:(NSUInteger)n];
            headerEnd = [raw rangeOfData:crlf options:0 range:NSMakeRange(0, raw.length)];
            if (headerEnd.location != NSNotFound || raw.length > 65536) break;
        }
        if (raw.length == 0 || headerEnd.location == NSNotFound) {
            close(clientFD);
            return;
        }

        NSString *headerStr = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *lines = [headerStr componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *reqParts = [lines.firstObject componentsSeparatedByString:@" "];
        if (reqParts.count < 2) {
            close(clientFD);
            return;
        }
        NSString *method = reqParts[0];
        NSString *fullPath = reqParts[1];

        NSInteger contentLength = 0;
        NSString *bearerToken = nil;
        NSString *cookieToken = nil;
        for (NSString *line in lines) {
            NSString *lower = line.lowercaseString;
            if ([lower hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].integerValue;
            } else if ([lower hasPrefix:@"authorization:"]) {
                NSString *val = [[line substringFromIndex:14] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if ([val.lowercaseString hasPrefix:@"bearer "]) {
                    bearerToken = [[val substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                }
            } else if ([lower hasPrefix:@"cookie:"]) {
                NSString *cookieVal = [line substringFromIndex:7];
                for (NSString *part in [cookieVal componentsSeparatedByString:@";"]) {
                    NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if ([trimmed hasPrefix:@"lc_dbg_token="]) {
                        cookieToken = [trimmed substringFromIndex:13];
                    }
                }
            }
        }
        if (contentLength > (1024 * 1024)) {
            close(clientFD);
            return;
        }
        NSUInteger bodyStart = NSMaxRange(headerEnd);
        while (contentLength > 0 && (NSInteger)(raw.length - bodyStart) < contentLength) {
            ssize_t n = recv(clientFD, buf, sizeof(buf), 0);
            if (n <= 0) break;
            [raw appendBytes:buf length:(NSUInteger)n];
        }
        NSData *bodyData = (raw.length > bodyStart) ? [raw subdataWithRange:NSMakeRange(bodyStart, raw.length - bodyStart)] : [NSData data];

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            close(clientFD);
            return;
        }

        NSString *queryToken = nil;
        NSURLComponents *comp = [NSURLComponents componentsWithString:fullPath];
        for (NSURLQueryItem *q in comp.queryItems) {
            if ([q.name isEqualToString:@"token"]) {
                queryToken = q.value;
                break;
            }
        }

        NSString *setCookieToken = nil;
        if (!isLoopback) {
            BOOL ok = LCDebugConstantTimeEquals(queryToken, strongSelf.authToken) ||
                      LCDebugConstantTimeEquals(bearerToken, strongSelf.authToken) ||
                      LCDebugConstantTimeEquals(cookieToken, strongSelf.authToken);
            if (!ok) {
                [strongSelf writeResponseFD:clientFD status:401 contentType:"application/json" setCookieToken:nil data:LCJSONDataFromObject(@{ @"error": @"Unauthorized: provide ?token= shown in Debug HUD" })];
                return;
            }
            if (queryToken.length > 0 && cookieToken.length == 0) {
                setCookieToken = strongSelf.authToken;
            }
        }

        [strongSelf routeMethod:method target:fullPath body:bodyData clientFD:clientFD setCookieToken:setCookieToken];
    });
}

- (void)writeResponseFD:(int)fd status:(int)status contentType:(const char *)ctype data:(NSData *)body {
    [self writeResponseFD:fd status:status contentType:ctype setCookieToken:nil data:body];
}

- (void)writeResponseFD:(int)fd status:(int)status contentType:(const char *)ctype setCookieToken:(NSString *)cookieToken data:(NSData *)body {
    NSString *statusText = status == 200 ? @"OK" : (status == 401 ? @"Unauthorized" : (status == 404 ? @"Not Found" : @"Bad Request"));
    NSString *cookieHeader = cookieToken.length > 0
        ? [NSString stringWithFormat:@"Set-Cookie: lc_dbg_token=%@; Path=/; HttpOnly; SameSite=Strict\r\n", cookieToken]
        : @"";
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %lu\r\n"
        "%@"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n",
        status, statusText, ctype, (unsigned long)body.length, cookieHeader];
    NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    if (hdrData.length > 0) {
        LCSendAllBlocking(fd, hdrData.bytes, hdrData.length);
    }
    if (body.length > 0) {
        LCSendAllBlocking(fd, body.bytes, body.length);
    }
    close(fd);
}

- (void)broadcastSSEEvent:(const char *)eventType payload:(id)payload {
    // Runs on self.serverQueue — non-blocking writes; partial writes close cleanly so framing never corrupts!
    if (self.sseClientFDs.count == 0) return;
    NSString *json = LCJSONStringFromObject(payload);
    NSString *frame = [NSString stringWithFormat:@"event: %s\ndata: %@\n\n", eventType, json];
    NSData *data = [frame dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableIndexSet *deadIndices = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < self.sseClientFDs.count; i++) {
        int fd = self.sseClientFDs[i].intValue;
        ssize_t n = send(fd, data.bytes, data.length, MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue; // Buffer momentarily full — drop whole frame cleanly
            }
            [deadIndices addIndex:i];
            close(fd);
        } else if (n == 0 || (size_t)n < data.length) {
            // Partial frame write would corrupt JSON framing -> disconnect client so it reconnects cleanly
            [deadIndices addIndex:i];
            close(fd);
        }
    }
    if (deadIndices.count > 0) {
        [self.sseClientFDs removeObjectsAtIndexes:deadIndices];
    }
}

- (void)routeMethod:(NSString *)method target:(NSString *)target body:(NSData *)body clientFD:(int)clientFD setCookieToken:(NSString *)cookieToken {
    NSURLComponents *comp = [NSURLComponents componentsWithString:target];
    NSString *path = comp.path ?: target;

    if ([method isEqualToString:@"OPTIONS"]) {
        [self writeResponseFD:clientFD status:200 contentType:"text/plain" setCookieToken:cookieToken data:[NSData data]];
        return;
    }

    if ([path isEqualToString:@"/api/stream"]) {
        const char *sseHeader =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/event-stream\r\n"
            "Cache-Control: no-cache\r\n"
            "Connection: keep-alive\r\n\r\n";
        size_t hdrLen = strlen(sseHeader);
        if (send(clientFD, sseHeader, hdrLen, 0) != (ssize_t)hdrLen) {
            close(clientFD);
            return;
        }
        fcntl(clientFD, F_SETFL, O_NONBLOCK);
        dispatch_async(self.serverQueue, ^{
            NSDictionary *status = [self currentStatusDictionary];
            NSString *initFrame = [NSString stringWithFormat:@"event: telemetry\ndata: %@\n\n", LCJSONStringFromObject(status)];
            NSData *initData = [initFrame dataUsingEncoding:NSUTF8StringEncoding];
            ssize_t sent = send(clientFD, initData.bytes, initData.length, MSG_DONTWAIT);
            if (sent == (ssize_t)initData.length || (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
                [self.sseClientFDs addObject:@(clientFD)];
            } else {
                close(clientFD);
            }
        });
        return;
    }

    if ([path isEqualToString:@"/"]) {
        NSData *html = [LCDebugWebConsoleHTML() dataUsingEncoding:NSUTF8StringEncoding];
        [self writeResponseFD:clientFD status:200 contentType:"text/html; charset=utf-8" setCookieToken:cookieToken data:html];
        return;
    }

    if ([path isEqualToString:@"/api/status"]) {
        NSDictionary *status = [self currentStatusDictionary];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(status)];
        return;
    }

    if ([path isEqualToString:@"/api/logs"]) {
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject([self logsSnapshot])];
        return;
    }

    if ([path isEqualToString:@"/api/network"]) {
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject([self networkSnapshot])];
        return;
    }

    if ([path isEqualToString:@"/api/events"]) {
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject([self uiEventsSnapshot])];
        return;
    }

    if ([path isEqualToString:@"/api/hierarchy"]) {
        NSDictionary *tree = [self captureViewHierarchy];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(tree ?: @{})];
        return;
    }

    if ([path isEqualToString:@"/api/dylibs"]) {
        NSArray *images = [self captureLoadedDylibs];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(images ?: @[])];
        return;
    }

    if ([path isEqualToString:@"/api/classes"]) {
        NSString *query = nil;
        NSString *clsName = nil;
        for (NSURLQueryItem *qi in comp.queryItems) {
            if ([qi.name isEqualToString:@"q"]) query = qi.value;
            if ([qi.name isEqualToString:@"class"]) clsName = qi.value;
        }
        if (clsName.length > 0) {
            NSDictionary *detail = [self inspectObjCClass:clsName];
            [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(detail)];
        } else {
            NSArray *classes = [self searchObjCClasses:query];
            [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(classes)];
        }
        return;
    }

    if ([path isEqualToString:@"/api/sandbox"]) {
        NSDictionary *sandbox = [self captureSandboxAndKeychainSummary];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(sandbox)];
        return;
    }

    if ([path isEqualToString:@"/api/frida"]) {
        NSDictionary *frida = [self captureFridaAndLLDBInfo];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(frida)];
        return;
    }

    if ([path isEqualToString:@"/api/action"] && [method isEqualToString:@"POST"]) {
        NSDictionary *json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
        NSString *action = [json isKindOfClass:NSDictionary.class] ? json[@"action"] : nil;
        if ([action isEqualToString:@"set_lan"]) {
            [self setLANEnabled:[json[@"enabled"] boolValue]];
        } else if ([action isEqualToString:@"toggle_xray"]) {
            [self setXRayEnabled:!self.xrayEnabled];
        } else if ([action isEqualToString:@"toggle_tap_inspect"]) {
            [self setTapInspectEnabled:!self.tapInspectEnabled];
        } else if ([action isEqualToString:@"toggle_notifications"]) {
            [self setNotificationMonitorEnabled:!self.notificationMonitorEnabled];
        } else if ([action isEqualToString:@"memory_warning"]) {
            [self simulateMemoryWarning];
        } else if ([action isEqualToString:@"clear_logs"]) {
            [self clearLogs];
        } else if ([action isEqualToString:@"clear_network"]) {
            [self clearNetwork];
        } else if ([action isEqualToString:@"clear_events"]) {
            [self clearUIEvents];
        }
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(@{ @"ok": @YES })];
        return;
    }

    [self writeResponseFD:clientFD status:404 contentType:"application/json" data:LCJSONDataFromObject(@{ @"error": @"Not Found" })];
}

// MARK: - Runtime & UI Introspection

- (void)simulateMemoryWarning {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:UIApplication.sharedApplication];
        SEL memSel = sel_registerName("_performMemoryWarning");
        if ([UIApplication.sharedApplication respondsToSelector:memSel]) {
            ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, memSel);
        }
    });
    [self appendLogStream:@"debug" level:@"notice" subsystem:@"LiveContainer" category:@"memory" text:@"Simulated UIApplication memory warning"];
}

- (void)setXRayEnabled:(BOOL)enabled {
    self.xrayEnabled = enabled;
    atomic_store(&gLCDebugXRayAtomic, enabled);
    dispatch_async(self.serverQueue, ^{
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionary]];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *win in LCVisibleGuestWindows()) {
            LCApplyXRayToView(win, enabled);
        }
    });
}

- (void)setNotificationMonitorEnabled:(BOOL)enabled {
    self.notificationMonitorEnabled = enabled;
    atomic_store(&gLCDebugNotifMonitorAtomic, enabled);
    dispatch_async(self.serverQueue, ^{
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionary]];
    });
}

- (void)setTapInspectEnabled:(BOOL)enabled {
    self.tapInspectEnabled = enabled;
    dispatch_async(self.serverQueue, ^{
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionary]];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.inspectOverlay) {
            [self.inspectOverlay removeFromSuperview];
            self.inspectOverlay = nil;
        }
        if (enabled) {
            UIWindow *win = LCActiveGuestWindow();
            if (win) {
                LCDebugInspectOverlayView *overlay = [[LCDebugInspectOverlayView alloc] initWithFrame:win.bounds];
                __weak typeof(self) weakSelf = self;
                overlay.onInspectView = ^(NSDictionary *info) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    os_unfair_lock_lock(&strongSelf->_dataLock);
                    strongSelf.selectedViewInfo = info;
                    os_unfair_lock_unlock(&strongSelf->_dataLock);
                    dispatch_async(strongSelf.serverQueue, ^{
                        [strongSelf broadcastSSEEvent:"tap" payload:info];
                    });
                };
                [win addSubview:overlay];
                self.inspectOverlay = overlay;
            }
        }
    });
}

static NSDictionary *LCSerializeViewNode(UIView *view, NSInteger depth, NSInteger *budget) {
    if (!view || depth > 18 || *budget <= 0 || LCDebugIsInternalDebugClass(view.class)) {
        return nil;
    }
    (*budget)--;
    NSString *vcName = nil;
    if ([view.nextResponder isKindOfClass:UIViewController.class]) {
        vcName = NSStringFromClass(view.nextResponder.class);
    }
    NSMutableArray *children = [NSMutableArray array];
    for (UIView *sub in view.subviews) {
        if (*budget <= 0) break;
        NSDictionary *node = LCSerializeViewNode(sub, depth + 1, budget);
        if (node) [children addObject:node];
    }
    NSMutableDictionary *dict = [@{
        @"class": NSStringFromClass(view.class) ?: @"",
        @"frame": NSStringFromCGRect(view.frame) ?: @"",
        @"hidden": @(view.isHidden),
        @"alpha": @(view.alpha),
        @"children": children
    } mutableCopy];
    if (vcName) dict[@"viewController"] = vcName;
    if (view.accessibilityIdentifier.length > 0) dict[@"accessibilityId"] = view.accessibilityIdentifier;
    return dict;
}

- (NSDictionary *)captureViewHierarchy {
    __block NSDictionary *result = @{};
    void (^captureBlock)(void) = ^{
        NSArray<UIWindow *> *guestWindows = LCVisibleGuestWindows();
        NSMutableArray *serializedWindows = [NSMutableArray arrayWithCapacity:guestWindows.count];
        NSInteger totalBudget = 1200;
        for (UIWindow *win in guestWindows) {
            if (totalBudget <= 0) break;
            NSDictionary *tree = LCSerializeViewNode(win, 0, &totalBudget);
            [serializedWindows addObject:@{
                @"windowClass": NSStringFromClass(win.class) ?: @"UIWindow",
                @"windowLevel": @(win.windowLevel),
                @"isKeyWindow": @(win.isKeyWindow),
                @"frame": NSStringFromCGRect(win.frame) ?: @"",
                @"rootViewController": win.rootViewController ? (NSStringFromClass(win.rootViewController.class) ?: @"") : @"",
                @"tree": tree ?: @{}
            }];
        }
        NSDictionary *primary = serializedWindows.firstObject ?: @{};
        result = @{
            @"windowCount": @(serializedWindows.count),
            @"windowClass": primary[@"windowClass"] ?: @"UIWindow",
            @"rootViewController": primary[@"rootViewController"] ?: @"",
            @"tree": primary[@"tree"] ?: @{},
            @"windows": serializedWindows
        };
    };
    if (NSThread.isMainThread) {
        captureBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
    }
    return result;
}

- (NSArray *)captureLoadedDylibs {
    uint32_t count = LCDebugImageCount();
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        const char *name = LCDebugImageName(i);
        const struct mach_header *hdr = LCDebugImageHeader(i);
        if (!name || !hdr) continue;
        NSString *path = @(name);
        BOOL isSystem = [path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/lib/"];
        [arr addObject:@{
            @"index": @(i),
            @"base": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)hdr],
            @"path": path,
            @"name": path.lastPathComponent ?: path,
            @"isSystem": @(isSystem)
        }];
    }
    return arr;
}

- (NSArray *)searchObjCClasses:(NSString *)query {
    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    if (!classes) return @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSString *lower = query.lowercaseString;
    for (unsigned int i = 0; i < total; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        NSString *name = @(cname);
        if (lower.length == 0 || [name.lowercaseString containsString:lower]) {
            [matches addObject:name];
            if (matches.count >= 250) break;
        }
    }
    free(classes);
    return matches;
}

- (NSDictionary *)inspectObjCClass:(NSString *)className {
    Class cls = objc_lookUpClass(className.UTF8String);
    if (!cls) return @{ @"error": @"Class not found" };

    NSMutableArray *methodsArr = [NSMutableArray array];
    unsigned int mCount = 0;
    Method *methods = class_copyMethodList(cls, &mCount);
    for (unsigned int i = 0; i < mCount && i < 200; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel) [methodsArr addObject:@(sel_getName(sel))];
    }
    if (methods) free(methods);

    NSMutableArray *propsArr = [NSMutableArray array];
    unsigned int pCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pCount);
    for (unsigned int i = 0; i < pCount && i < 150; i++) {
        const char *pname = property_getName(props[i]);
        if (pname) [propsArr addObject:@(pname)];
    }
    if (props) free(props);

    NSMutableArray *ivarsArr = [NSMutableArray array];
    unsigned int iCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &iCount);
    for (unsigned int i = 0; i < iCount && i < 150; i++) {
        const char *iname = ivar_getName(ivars[i]);
        if (iname) [ivarsArr addObject:@(iname)];
    }
    if (ivars) free(ivars);

    Class superCls = class_getSuperclass(cls);
    const char *img = class_getImageName(cls);
    return @{
        @"class": className,
        @"superclass": superCls ? @(class_getName(superCls)) : @"nil",
        @"image": img ? @(img) : @"",
        @"methods": methodsArr,
        @"properties": propsArr,
        @"ivars": ivarsArr
    };
}

- (NSDictionary *)captureSandboxAndKeychainSummary {
    const char *homeEnv = getenv("HOME");
    NSString *home = homeEnv ? @(homeEnv) : NSHomeDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray *topFiles = [NSMutableArray array];
    for (NSString *sub in @[@"Documents", @"Library/Preferences", @"Library/Caches", @"tmp"]) {
        NSString *dir = [home stringByAppendingPathComponent:sub];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if (topFiles.count >= 160) break;
            NSString *full = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            [topFiles addObject:@{
                @"path": [sub stringByAppendingPathComponent:name],
                @"size": attrs[NSFileSize] ?: @(0),
                @"type": [attrs[NSFileType] isEqualToString:NSFileTypeDirectory] ? @"dir" : @"file"
            }];
        }
    }

    NSDictionary *defaultsDict = LCSanitizeJSONValue([NSUserDefaults.standardUserDefaults dictionaryRepresentation] ?: @{});

    NSMutableArray *keychainItems = [NSMutableArray array];
    for (id secClass in @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword]) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecReturnAttributes: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        CFTypeRef resultRef = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &resultRef) == errSecSuccess && resultRef) {
            NSArray *items = CFBridgingRelease(resultRef);
            if ([items isKindOfClass:NSArray.class]) {
                for (NSDictionary *item in items) {
                    if (keychainItems.count >= 80) break;
                    [keychainItems addObject:@{
                        @"account": item[(__bridge id)kSecAttrAccount] ?: @"",
                        @"service": item[(__bridge id)kSecAttrService] ?: item[(__bridge id)kSecAttrServer] ?: @"",
                        @"accessGroup": item[(__bridge id)kSecAttrAccessGroup] ?: @""
                    }];
                }
            }
        }
    }

    return @{
        @"home": home ?: @"",
        @"files": topFiles,
        @"userDefaults": defaultsDict,
        @"keychainItems": keychainItems
    };
}

- (NSDictionary *)captureFridaAndLLDBInfo {
    BOOL hasFrida = NO;
    BOOL hasFLEX = (objc_lookUpClass("FLEXManager") != Nil);
    uint32_t count = LCDebugImageCount();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = LCDebugImageName(i);
        if (name && (strstr(name, "FridaGadget") || strstr(name, "frida"))) {
            hasFrida = YES;
            break;
        }
    }
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"com.example.app";
    return @{
        @"pid": @(getpid()),
        @"bundleId": bundleId,
        @"executablePath": NSBundle.mainBundle.executablePath ?: @"",
        @"bundlePath": NSBundle.mainBundle.bundlePath ?: @"",
        @"isJIT": @(self.lastJITState),
        @"fridaGadgetLoaded": @(hasFrida),
        @"flexLoaded": @(hasFLEX),
        @"fridaAttachCmd": [NSString stringWithFormat:@"frida -U -p %d", getpid()],
        @"fridaGadgetTip": @"Console, OSLog, Network, UI/Events, Hierarchy, ObjC, and Sandbox work 100% JIT-less. Attach JIT only if you need LLDB breakpoints, emulators, or inline Frida Interceptor hooks.",
        @"lldbCmd": [NSString stringWithFormat:@"process attach --pid %d", getpid()]
    };
}

// MARK: - In-App Liquid Glass Floating Debug Overlay

- (void)observeScenesForOverlay {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(handleSceneOrWindowActivated:) name:UISceneDidActivateNotification object:nil];
    [nc addObserver:self selector:@selector(handleSceneOrWindowActivated:) name:UIWindowDidBecomeKeyNotification object:nil];
}

- (void)handleSceneOrWindowActivated:(NSNotification *)note {
    if (!self.shouldShowInAppOverlay) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachOverlayWindowIfNeeded];
    });
}

- (void)attachOverlayWindowIfNeeded {
    if (!self.shouldShowInAppOverlay) return;
    UIWindowScene *scene = LCActiveForegroundWindowScene();
    if (!scene) return;

    if (self.overlayWindow) {
        if (self.overlayWindow.windowScene != scene) {
            self.overlayWindow.windowScene = scene;
            self.overlayWindow.frame = scene.coordinateSpace.bounds;
        }
        self.overlayWindow.hidden = NO;
        return;
    }

    LCDebugOverlayWindow *win = [[LCDebugOverlayWindow alloc] initWithWindowScene:scene];
    win.frame = scene.coordinateSpace.bounds;
    win.windowLevel = UIWindowLevelAlert + 50;
    win.backgroundColor = UIColor.clearColor;

    LCDebugOverlayRootViewController *rootVC = [[LCDebugOverlayRootViewController alloc] init];
    rootVC.view.backgroundColor = UIColor.clearColor;

    UIView *pillContainer = [[UIView alloc] initWithFrame:CGRectMake(16, 62, 168, 34)];
    pillContainer.layer.cornerRadius = 17;
    pillContainer.layer.cornerCurve = kCACornerCurveContinuous;
    pillContainer.clipsToBounds = YES;
    pillContainer.layer.borderColor = [UIColor.systemCyanColor colorWithAlphaComponent:0.55].CGColor;
    pillContainer.layer.borderWidth = 1.0;

    UIVisualEffect *effect = nil;
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        effect = [[glassClass alloc] init];
    }
    if (!effect) {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    blurView.frame = pillContainer.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [pillContainer addSubview:blurView];

    UILabel *lbl = [[UILabel alloc] initWithFrame:pillContainer.bounds];
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = UIColor.whiteColor;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.text = @"DBG Ready";
    [blurView.contentView addSubview:lbl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleOverlayPillPan:)];
    [pillContainer addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleOverlayPillTap)];
    [pillContainer addGestureRecognizer:tap];

    [rootVC.view addSubview:pillContainer];
    rootVC.pillContainer = pillContainer;
    win.rootViewController = rootVC;
    win.pillContainer = pillContainer;
    win.statusLabel = lbl;
    win.hidden = NO;
    self.overlayWindow = win;
    [rootVC clampPillToSafeArea];
}

- (void)handleOverlayPillPan:(UIPanGestureRecognizer *)pan {
    UIView *pill = self.overlayWindow.pillContainer;
    LCDebugOverlayRootViewController *rootVC = [self.overlayWindow.rootViewController isKindOfClass:LCDebugOverlayRootViewController.class]
        ? (LCDebugOverlayRootViewController *)self.overlayWindow.rootViewController
        : nil;
    UIView *host = rootVC.view;
    if (!pill || !host) return;
    CGPoint t = [pan translationInView:host];
    pill.center = CGPointMake(pill.center.x + t.x, pill.center.y + t.y);
    [rootVC clampPillToSafeArea];
    [pan setTranslation:CGPointZero inView:host];
}

- (void)handleOverlayPillTap {
    if (!self.overlayWindow || self.overlayWindow.rootViewController.presentedViewController != nil) return;
    LCDebugInAppDrawerViewController *drawer = [[LCDebugInAppDrawerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:drawer];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (nav.sheetPresentationController) {
        nav.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self.overlayWindow.rootViewController presentViewController:nav animated:YES completion:nil];
}

@end

// MARK: - Public Entry Point

__attribute__((visibility("default")))
void LCDebugAgentInitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL shouldEnable = NO;
        const char *envDebug = getenv("LC_DEBUG_MODE");
        if (envDebug && envDebug[0] == '1') {
            shouldEnable = YES;
        }
        if (!shouldEnable && [NSUserDefaults respondsToSelector:@selector(guestAppInfo)]) {
            NSDictionary *appInfo = [NSUserDefaults guestAppInfo];
            shouldEnable = [appInfo[@"LCDebugModeEnabled"] boolValue];
        }
        if (!shouldEnable && [NSUserDefaults respondsToSelector:@selector(lcSharedDefaults)]) {
            NSUserDefaults *shared = [NSUserDefaults lcSharedDefaults];
            NSString *pendingBundleId = [shared stringForKey:@"LCDebugPendingBundleID"];
            NSString *pendingRelPath = [shared stringForKey:@"LCDebugPendingRelativePath"];
            NSString *currentBundleId = NSBundle.mainBundle.bundleIdentifier;
            NSString *guestId = [NSUserDefaults respondsToSelector:@selector(lcGuestAppId)] ? [NSUserDefaults lcGuestAppId] : nil;
            NSString *relPath = NSBundle.mainBundle.bundlePath.lastPathComponent;
            BOOL matched = NO;
            if (pendingRelPath.length > 0 && relPath.length > 0 && [pendingRelPath isEqualToString:relPath]) {
                matched = YES;
            } else if (pendingBundleId.length > 0 &&
                       ((currentBundleId.length > 0 && [pendingBundleId isEqualToString:currentBundleId]) ||
                        (guestId.length > 0 && [pendingBundleId isEqualToString:guestId]))) {
                matched = YES;
            }
            if (matched) {
                shouldEnable = YES;
                [shared removeObjectForKey:@"LCDebugPendingBundleID"];
                [shared removeObjectForKey:@"LCDebugPendingRelativePath"];
            }
        }
        if (!shouldEnable) {
            return;
        }

        uint32_t (**pCount)(void) = (uint32_t (**)(void))dlsym(RTLD_DEFAULT, "orig_dyld_image_count");
        const char *(**pName)(uint32_t) = (const char *(**)(uint32_t))dlsym(RTLD_DEFAULT, "orig_dyld_get_image_name");
        const struct mach_header *(**pHdr)(uint32_t) = (const struct mach_header *(**)(uint32_t))dlsym(RTLD_DEFAULT, "orig_dyld_get_image_header");
        if (pCount && *pCount) g_orig_dyld_image_count = *pCount;
        if (pName && *pName) g_orig_dyld_get_image_name = *pName;
        if (pHdr && *pHdr) g_orig_dyld_get_image_header = *pHdr;

        [LCDebugServer.shared start];
    });
}

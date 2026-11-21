//
//  LCDebugURLSessionHooks.m
//  TweakLoader
//
//  Non-invasive JIT-less NSURLSession, task delegate, WebSocket frame, and
//  NSURLConnection runtime hooks.
//

@import Foundation;

#import "LCDebugURLSessionHooks.h"
#import "LCDebugNetworkEngine.h"
#include <os/lock.h>
#include <string.h>

static os_unfair_lock gLCTaskContextLock = OS_UNFAIR_LOCK_INIT;
static char kLCNetTaskContextKey;

static _Thread_local BOOL gLCInTaskCreate = NO;
static _Thread_local BOOL gLCInDidReceiveResponse = NO;
static _Thread_local BOOL gLCInDidReceiveData = NO;
static _Thread_local BOOL gLCInDidComplete = NO;
static _Thread_local BOOL gLCInDidRedirect = NO;
static _Thread_local BOOL gLCInWebSocketOp = NO;
static _Thread_local uint64_t gLCThreadTaskCreateSeq = 0;

static NSURLRequest * _Nullable LCNetSafeTaskRequest(NSURLSessionTask * _Nullable task) {
    if (!task || LCDebugIsAVAggregateAssetTask(task)) return nil;
    return task.currentRequest ?: task.originalRequest;
}

static LCDebugNetTaskContext * _Nullable LCNetGetTaskContext(NSURLSessionTask * _Nullable task) {
    if (!task || LCDebugIsAVAggregateAssetTask(task)) return nil;
    os_unfair_lock_lock(&gLCTaskContextLock);
    LCDebugNetTaskContext *ctx = objc_getAssociatedObject(task, &kLCNetTaskContextKey);
    os_unfair_lock_unlock(&gLCTaskContextLock);
    return ctx;
}

LCDebugNetTaskContext * _Nullable LCDebugGetOrCreateTaskContext(NSURLSessionTask * _Nullable task,
                                                                NSURLRequest * _Nullable req,
                                                                NSData * _Nullable uploadBody,
                                                                NSString * _Nullable mechanism,
                                                                NSString * _Nullable source) {
    if (!task || LCDebugIsAVAggregateAssetTask(task)) return nil;
    os_unfair_lock_lock(&gLCTaskContextLock);
    LCDebugNetTaskContext *ctx = objc_getAssociatedObject(task, &kLCNetTaskContextKey);
    if (!ctx) {
        ctx = [[LCDebugNetTaskContext alloc] init];
        ctx.request = req ?: task.currentRequest ?: task.originalRequest;
        ctx.requestBody = uploadBody;
        if (mechanism.length > 0) ctx.mechanism = mechanism;
        if (source.length > 0) ctx.source = source;
        objc_setAssociatedObject(task, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
    } else {
        [ctx lock];
        if (req && (!ctx.request || req.allHTTPHeaderFields.count >= ctx.request.allHTTPHeaderFields.count)) {
            ctx.request = req;
        }
        if (uploadBody && !ctx.requestBody) {
            ctx.requestBody = uploadBody;
        }
        if (mechanism.length > 0 && ![ctx.mechanism isEqualToString:@"LCDebugNetworkReplay"]) {
            if ([ctx.mechanism isEqualToString:@"NSURLSessionTask"] || [mechanism isEqualToString:@"LCDebugNetworkReplay"]) {
                ctx.mechanism = mechanism;
            }
        }
        if (source.length > 0) {
            ctx.source = source;
        }
        [ctx unlock];
    }
    os_unfair_lock_unlock(&gLCTaskContextLock);
    return ctx;
}

static NSDictionary<NSString *, id> * _Nullable LCNetSerializeMetrics(NSURLSessionTaskMetrics * _Nullable metrics) {
    if (!metrics) return nil;
    NSURLSessionTaskTransactionMetrics *m = metrics.transactionMetrics.lastObject;
    if (!m) {
        return @{
            @"totalMs": @((NSInteger)llround(metrics.taskInterval.duration * 1000.0)),
            @"redirects": @(metrics.redirectCount)
        };
    }

    NSInteger dnsMs = 0;
    if (m.domainLookupStartDate && m.domainLookupEndDate) {
        dnsMs = MAX(0, (NSInteger)llround([m.domainLookupEndDate timeIntervalSinceDate:m.domainLookupStartDate] * 1000.0));
    }
    NSInteger connectMs = 0;
    if (m.connectStartDate && m.connectEndDate) {
        connectMs = MAX(0, (NSInteger)llround([m.connectEndDate timeIntervalSinceDate:m.connectStartDate] * 1000.0));
    }
    NSInteger tlsMs = 0;
    if (m.secureConnectionStartDate && m.secureConnectionEndDate) {
        tlsMs = MAX(0, (NSInteger)llround([m.secureConnectionEndDate timeIntervalSinceDate:m.secureConnectionStartDate] * 1000.0));
    }
    NSInteger reqMs = 0;
    if (m.requestStartDate && m.requestEndDate) {
        reqMs = MAX(0, (NSInteger)llround([m.requestEndDate timeIntervalSinceDate:m.requestStartDate] * 1000.0));
    }
    NSInteger respMs = 0;
    if (m.responseStartDate && m.responseEndDate) {
        respMs = MAX(0, (NSInteger)llround([m.responseEndDate timeIntervalSinceDate:m.responseStartDate] * 1000.0));
    }
    NSInteger waitMs = 0;
    if (m.requestEndDate && m.responseStartDate) {
        waitMs = MAX(0, (NSInteger)llround([m.responseStartDate timeIntervalSinceDate:m.requestEndDate] * 1000.0));
    }

    NSString *remoteAddr = m.remoteAddress ?: @"";
    if (remoteAddr.length > 0 && m.remotePort) {
        remoteAddr = [NSString stringWithFormat:@"%@:%@", remoteAddr, m.remotePort];
    }

    return @{
        @"dnsMs": @(dnsMs),
        @"connectMs": @(connectMs),
        @"tlsMs": @(tlsMs),
        @"requestMs": @(reqMs),
        @"waitMs": @(waitMs),
        @"responseMs": @(respMs),
        @"totalMs": @((NSInteger)llround(metrics.taskInterval.duration * 1000.0)),
        @"redirects": @(metrics.redirectCount),
        @"protocolName": m.networkProtocolName ?: @"",
        @"reusedConnection": @(m.isReusedConnection),
        @"remoteAddress": remoteAddr,
        @"isCellular": @(m.isCellular),
        @"isProxy": @(m.isProxyConnection),
        @"wireRequestBytes": @(MAX((int64_t)0, m.countOfRequestHeaderBytesSent + m.countOfRequestBodyBytesSent)),
        @"wireResponseBytes": @(MAX((int64_t)0, m.countOfResponseHeaderBytesReceived + m.countOfResponseBodyBytesReceived))
    };
}

// MARK: - Session & Task Delegate Class Interception

static void LCNetHookDelegateClass(Class _Nullable cls) {
    if (!LCDebugIsSafeObjCClass(cls) || LCDebugClassOverridesForwarding(cls)) {
        return;
    }

    // 1. willPerformHTTPRedirection
    SEL redirSel = @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:);
    Class redirOwner = LCDebugOwningClassForSelector(cls, redirSel);
    if (redirOwner && LCDebugMarkSelectorHooked(redirOwner, redirSel)) {
        Method m = class_getInstanceMethod(redirOwner, redirSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSHTTPURLResponse *response, NSURLRequest *newRequest, void (^completionHandler)(NSURLRequest * _Nullable)) {
                BOOL entered = NO;
                if (!gLCInDidRedirect && !LCDebugNetworkIsPausedAtomic()) {
                    gLCInDidRedirect = YES;
                    entered = YES;
                    LCDebugNetTaskContext *ctx = LCNetGetTaskContext(task);
                    if (ctx) {
                        [ctx lock];
                        ctx.endTime = CFAbsoluteTimeGetCurrent();
                        NSString *prevID = ctx.txId;
                        NSString *prevSource = ctx.source;
                        NSString *prevMech = ctx.mechanism;
                        [ctx unlock];

                        [LCDebugNetworkEngine.shared recordCompletionForContext:ctx
                                                                        response:response
                                                                    overrideData:nil
                                                                   receivedBytes:0
                                                                           error:nil
                                                                         metrics:nil];
                        LCDebugNetTaskContext *nextCtx = [[LCDebugNetTaskContext alloc] init];
                        nextCtx.redirectFromId = prevID;
                        nextCtx.request = newRequest;
                        nextCtx.source = prevSource;
                        nextCtx.mechanism = prevMech;
                        nextCtx.startTime = CFAbsoluteTimeGetCurrent();
                        [nextCtx markStarted];
                        os_unfair_lock_lock(&gLCTaskContextLock);
                        objc_setAssociatedObject(task, &kLCNetTaskContextKey, nextCtx, OBJC_ASSOCIATION_RETAIN);
                        os_unfair_lock_unlock(&gLCTaskContextLock);
                        [LCDebugNetworkEngine.shared recordStartForContext:nextCtx request:newRequest];
                    }
                }
                @try {
                    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSHTTPURLResponse *, NSURLRequest *, void (^)(NSURLRequest * _Nullable)))origIMP)(selfObj, redirSel, session, task, response, newRequest, completionHandler);
                } @finally {
                    if (entered) gLCInDidRedirect = NO;
                }
            };
            class_replaceMethod(redirOwner, redirSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 2. dataTask:didReceiveResponse:completionHandler:
    SEL respSel = @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    Class respOwner = LCDebugOwningClassForSelector(cls, respSel);
    if (respOwner) {
        if (LCDebugMarkSelectorHooked(respOwner, respSel)) {
            Method m = class_getInstanceMethod(respOwner, respSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response, void (^completionHandler)(NSURLSessionResponseDisposition)) {
                    BOOL entered = NO;
                    if (!gLCInDidReceiveResponse && !LCDebugNetworkIsPausedAtomic()) {
                        gLCInDidReceiveResponse = YES;
                        entered = YES;
                        LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dataTask);
                        if (ctx && response) {
                            [ctx lock];
                            ctx.response = response;
                            if (ctx.responseTime == 0) {
                                ctx.responseTime = CFAbsoluteTimeGetCurrent();
                            }
                            [ctx unlock];
                            [LCDebugNetworkEngine.shared recordResponseForContext:ctx response:response];
                        }
                    }
                    @try {
                        ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition)))origIMP)(selfObj, respSel, session, dataTask, response, completionHandler);
                    } @finally {
                        if (entered) gLCInDidReceiveResponse = NO;
                    }
                };
                class_replaceMethod(respOwner, respSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }
    } else if (LCDebugMarkSelectorHooked(cls, respSel)) {
        id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response, void (^completionHandler)(NSURLSessionResponseDisposition)) {
            BOOL entered = NO;
            if (!gLCInDidReceiveResponse && !LCDebugNetworkIsPausedAtomic()) {
                gLCInDidReceiveResponse = YES;
                entered = YES;
                LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dataTask);
                if (ctx && response) {
                    [ctx lock];
                    ctx.response = response;
                    if (ctx.responseTime == 0) {
                        ctx.responseTime = CFAbsoluteTimeGetCurrent();
                    }
                    [ctx unlock];
                    [LCDebugNetworkEngine.shared recordResponseForContext:ctx response:response];
                }
            }
            @try {
                if (completionHandler) {
                    completionHandler(NSURLSessionResponseAllow);
                }
            } @finally {
                if (entered) gLCInDidReceiveResponse = NO;
            }
        };
        class_addMethod(cls, respSel, imp_implementationWithBlock(block), "v@:@@@@?");
    }

    // 3. dataTask:didReceiveData:
    SEL dataSel = @selector(URLSession:dataTask:didReceiveData:);
    Class dataOwner = LCDebugOwningClassForSelector(cls, dataSel);
    if (dataOwner && LCDebugMarkSelectorHooked(dataOwner, dataSel)) {
        Method m = class_getInstanceMethod(dataOwner, dataSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *chunk) {
                BOOL entered = NO;
                if (!gLCInDidReceiveData && !LCDebugNetworkIsPausedAtomic()) {
                    gLCInDidReceiveData = YES;
                    entered = YES;
                    LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dataTask);
                    if (ctx && chunk.length > 0) {
                        NSUInteger maxBytes = LCDebugNetworkEngine.shared.maxSingleBodyBytes;
                        [ctx appendResponseChunk:chunk maxCaptureBytes:maxBytes];
                        [LCDebugNetworkEngine.shared recordProgressForContext:ctx];
                    }
                }
                @try {
                    ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))origIMP)(selfObj, dataSel, session, dataTask, chunk);
                } @finally {
                    if (entered) gLCInDidReceiveData = NO;
                }
            };
            class_replaceMethod(dataOwner, dataSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 4. dataTask:didBecomeDownloadTask:
    SEL becomeDLSel = @selector(URLSession:dataTask:didBecomeDownloadTask:);
    Class becomeDLOwner = LCDebugOwningClassForSelector(cls, becomeDLSel);
    if (becomeDLOwner && LCDebugMarkSelectorHooked(becomeDLOwner, becomeDLSel)) {
        Method m = class_getInstanceMethod(becomeDLOwner, becomeDLSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask) {
                LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dataTask);
                if (ctx && downloadTask) {
                    [ctx lock];
                    ctx.mechanism = @"NSURLSessionDownloadTask";
                    [ctx unlock];
                    os_unfair_lock_lock(&gLCTaskContextLock);
                    objc_setAssociatedObject(downloadTask, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                    os_unfair_lock_unlock(&gLCTaskContextLock);
                }
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLSessionDownloadTask *))origIMP)(selfObj, becomeDLSel, session, dataTask, downloadTask);
            };
            class_replaceMethod(becomeDLOwner, becomeDLSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 5. downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:
    SEL dlWriteSel = @selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:);
    Class dlWriteOwner = LCDebugOwningClassForSelector(cls, dlWriteSel);
    if (dlWriteOwner && LCDebugMarkSelectorHooked(dlWriteOwner, dlWriteSel)) {
        Method m = class_getInstanceMethod(dlWriteOwner, dlWriteSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDownloadTask *dlTask, int64_t bytesWritten, int64_t totalWritten, int64_t totalExpected) {
                if (!LCDebugNetworkIsPausedAtomic()) {
                    LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dlTask);
                    if (ctx) {
                        [ctx lock];
                        ctx.totalReceivedBytes = (NSUInteger)MAX((int64_t)0, totalWritten);
                        if (!ctx.response && dlTask.response) {
                            ctx.response = dlTask.response;
                            if (ctx.responseTime == 0) ctx.responseTime = CFAbsoluteTimeGetCurrent();
                        }
                        [ctx unlock];
                        [LCDebugNetworkEngine.shared recordProgressForContext:ctx];
                    }
                }
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDownloadTask *, int64_t, int64_t, int64_t))origIMP)(selfObj, dlWriteSel, session, dlTask, bytesWritten, totalWritten, totalExpected);
            };
            class_replaceMethod(dlWriteOwner, dlWriteSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 6. downloadTask:didFinishDownloadingToURL:
    SEL dlFinishSel = @selector(URLSession:downloadTask:didFinishDownloadingToURL:);
    Class dlFinishOwner = LCDebugOwningClassForSelector(cls, dlFinishSel);
    if (dlFinishOwner && LCDebugMarkSelectorHooked(dlFinishOwner, dlFinishSel)) {
        Method m = class_getInstanceMethod(dlFinishOwner, dlFinishSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            id block = ^(id selfObj, NSURLSession *session, NSURLSessionDownloadTask *dlTask, NSURL *location) {
                if (!LCDebugNetworkIsPausedAtomic() && location.isFileURL) {
                    LCDebugNetTaskContext *ctx = LCNetGetTaskContext(dlTask);
                    if (ctx) {
                        NSNumber *fileSize = nil;
                        [location getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
                        NSUInteger fBytes = fileSize ? fileSize.unsignedIntegerValue : 0;
                        [ctx lock];
                        ctx.totalReceivedBytes = MAX(ctx.totalReceivedBytes, fBytes);
                        if (!ctx.response && dlTask.response) {
                            ctx.response = dlTask.response;
                            if (ctx.responseTime == 0) ctx.responseTime = CFAbsoluteTimeGetCurrent();
                        }
                        NSString *mime = [ctx.response.MIMEType copy] ?: @"";
                        [ctx unlock];
                        NSUInteger maxBytes = LCDebugNetworkEngine.shared.maxSingleBodyBytes;
                        if (fBytes > 0 && fBytes <= maxBytes && (!LCDebugIsMediaMime(mime) || [mime.lowercaseString hasPrefix:@"image/"])) {
                            NSData *fileData = [NSData dataWithContentsOfURL:location options:NSDataReadingMappedIfSafe error:nil];
                            if (fileData.length > 0 && fileData.length <= maxBytes) {
                                [ctx lock];
                                ctx.receivedData = [fileData mutableCopy];
                                [ctx unlock];
                            }
                        }
                    }
                }
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDownloadTask *, NSURL *))origIMP)(selfObj, dlFinishSel, session, dlTask, location);
            };
            class_replaceMethod(dlFinishOwner, dlFinishSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
        }
    }

    // 7. task:didFinishCollectingMetrics:
    SEL metricsSel = @selector(URLSession:task:didFinishCollectingMetrics:);
    Class metricsOwner = LCDebugOwningClassForSelector(cls, metricsSel);
    if (metricsOwner) {
        if (LCDebugMarkSelectorHooked(metricsOwner, metricsSel)) {
            Method m = class_getInstanceMethod(metricsOwner, metricsSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSURLSessionTaskMetrics *metrics) {
                    if (!LCDebugNetworkIsPausedAtomic()) {
                        LCDebugNetTaskContext *ctx = LCNetGetTaskContext(task);
                        if (ctx && metrics) {
                            NSDictionary *serialized = LCNetSerializeMetrics(metrics);
                            [ctx lock];
                            ctx.metricsDict = serialized;
                            [ctx unlock];
                        }
                    }
                    ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSURLSessionTaskMetrics *))origIMP)(selfObj, metricsSel, session, task, metrics);
                };
                class_replaceMethod(metricsOwner, metricsSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }
    } else if (LCDebugMarkSelectorHooked(cls, metricsSel)) {
        id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSURLSessionTaskMetrics *metrics) {
            if (!LCDebugNetworkIsPausedAtomic()) {
                LCDebugNetTaskContext *ctx = LCNetGetTaskContext(task);
                if (ctx && metrics) {
                    NSDictionary *serialized = LCNetSerializeMetrics(metrics);
                    [ctx lock];
                    ctx.metricsDict = serialized;
                    [ctx unlock];
                }
            }
        };
        class_addMethod(cls, metricsSel, imp_implementationWithBlock(block), "v@:@@@");
    }

    // 8. task:didCompleteWithError:
    SEL completeSel = @selector(URLSession:task:didCompleteWithError:);
    Class completeOwner = LCDebugOwningClassForSelector(cls, completeSel);
    if (completeOwner) {
        if (LCDebugMarkSelectorHooked(completeOwner, completeSel)) {
            Method m = class_getInstanceMethod(completeOwner, completeSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
                    BOOL entered = NO;
                    if (!gLCInDidComplete && !LCDebugNetworkIsPausedAtomic()) {
                        gLCInDidComplete = YES;
                        entered = YES;
                        LCDebugNetTaskContext *ctx = LCNetGetTaskContext(task);
                        if (ctx) {
                            [ctx lock];
                            ctx.endTime = CFAbsoluteTimeGetCurrent();
                            NSDictionary *mDict = ctx.metricsDict;
                            [ctx unlock];
                            NSURLResponse *resp = (!LCDebugIsAVAggregateAssetTask(task) ? task.response : nil);
                            NSUInteger recv = (!LCDebugIsAVAggregateAssetTask(task) ? (NSUInteger)MAX((int64_t)0, task.countOfBytesReceived) : 0);
                            [LCDebugNetworkEngine.shared recordCompletionForContext:ctx
                                                                            response:resp
                                                                        overrideData:nil
                                                                       receivedBytes:recv
                                                                               error:error
                                                                             metrics:mDict];
                        }
                    }
                    @try {
                        ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))origIMP)(selfObj, completeSel, session, task, error);
                    } @finally {
                        if (entered) gLCInDidComplete = NO;
                    }
                };
                class_replaceMethod(completeOwner, completeSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }
    } else if (LCDebugMarkSelectorHooked(cls, completeSel)) {
        id block = ^(id selfObj, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
            if (!LCDebugNetworkIsPausedAtomic()) {
                LCDebugNetTaskContext *ctx = LCNetGetTaskContext(task);
                if (ctx) {
                    [ctx lock];
                    ctx.endTime = CFAbsoluteTimeGetCurrent();
                    NSDictionary *mDict = ctx.metricsDict;
                    [ctx unlock];
                    NSURLResponse *resp = (!LCDebugIsAVAggregateAssetTask(task) ? task.response : nil);
                    NSUInteger recv = (!LCDebugIsAVAggregateAssetTask(task) ? (NSUInteger)MAX((int64_t)0, task.countOfBytesReceived) : 0);
                    [LCDebugNetworkEngine.shared recordCompletionForContext:ctx
                                                                    response:resp
                                                                overrideData:nil
                                                               receivedBytes:recv
                                                                       error:error
                                                                     metrics:mDict];
                }
            }
        };
        class_addMethod(cls, completeSel, imp_implementationWithBlock(block), "v@:@@@");
    }
}

static void LCHookSessionDelegateIfNeeded(id _Nullable delegate) {
    if (!delegate) return;
    if ([delegate isProxy] || ![delegate isKindOfClass:NSObject.class]) return;
    LCNetHookDelegateClass([delegate class]);
}

static void LCBootstrapScanLoadedURLSessionDelegates(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    const char *urlSessionPrefix = "URLSession:";
    size_t prefixLen = strlen(urlSessionPrefix);
    Class *candidates = (Class *)calloc(classCount, sizeof(Class));
    unsigned int candidateCount = 0;

    if (candidates) {
        for (unsigned int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            if (!LCDebugIsSafeObjCClass(cls)) continue;
            unsigned int mCount = 0;
            Method *methods = class_copyMethodList(cls, &mCount);
            if (!methods) continue;
            BOOL matches = NO;
            for (unsigned int j = 0; j < mCount; j++) {
                const char *selName = sel_getName(method_getName(methods[j]));
                if (selName && strncmp(selName, urlSessionPrefix, prefixLen) == 0) {
                    if (strcmp(selName, "URLSession:didReceiveChallenge:completionHandler:") != 0 &&
                        strcmp(selName, "URLSession:task:didReceiveChallenge:completionHandler:") != 0) {
                        matches = YES;
                        break;
                    }
                }
            }
            free(methods);
            if (matches) {
                candidates[candidateCount++] = cls;
            }
        }
    }
    free(classes);

    for (unsigned int i = 0; i < candidateCount; i++) {
        LCNetHookDelegateClass(candidates[i]);
    }
    free(candidates);
}

// MARK: - NSURLSession Factory Hooks

@implementation NSURLSession (LCDebugNetworkEngineSwizzle)

+ (NSURLSession *)lcNet_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                         delegate:(id<NSURLSessionDelegate>)delegate
                                    delegateQueue:(NSOperationQueue *)queue {
    if (delegate) {
        LCHookSessionDelegateIfNeeded(delegate);
    }
    return [self lcNet_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

@end

static NSArray<Class> *LCNetSessionFactoryClasses(void) {
    NSMutableArray<Class> *classes = [NSMutableArray arrayWithObject:NSURLSession.class];
    Class localCls = NSClassFromString(@"__NSURLSessionLocal");
    if (localCls && ![classes containsObject:localCls]) [classes addObject:localCls];
    Class cfCls = NSClassFromString(@"__NSCFURLSession");
    if (cfCls && ![classes containsObject:cfCls]) [classes addObject:cfCls];
    Class bgCls = NSClassFromString(@"__NSURLBackgroundSession");
    if (bgCls && ![classes containsObject:bgCls]) [classes addObject:bgCls];
    return classes;
}

static NSArray<Class> *LCNetTaskClusterClasses(void) {
    NSArray<NSString *> *names = @[
        @"NSURLSessionTask",
        @"__NSCFLocalSessionTask",
        @"__NSCFBackgroundSessionTask",
        @"__NSCFLocalDataTask",
        @"__NSCFLocalUploadTask",
        @"__NSCFLocalDownloadTask",
        @"__NSCFURLSessionTask"
    ];
    NSMutableArray<Class> *out = [NSMutableArray array];
    for (NSString *n in names) {
        Class cls = NSClassFromString(n);
        if (cls && ![out containsObject:cls]) {
            [out addObject:cls];
        }
    }
    return out;
}

static void LCNetPrepareAndFinishHandlerTask(NSURLRequest * _Nullable request,
                                             NSData * _Nullable uploadBody,
                                             NSUInteger fileBytes,
                                             NSString *mechanism,
                                             NSURLSessionTask * _Nullable task,
                                             NSURLResponse * _Nullable response,
                                             NSData * _Nullable data,
                                             NSError * _Nullable error,
                                             LCDebugNetTaskContext *ctx) {
    LCDebugNetTaskContext *activeCtx = (task ? LCNetGetTaskContext(task) : nil) ?: ctx;
    NSURLRequest *liveReq = (task && !LCDebugIsAVAggregateAssetTask(task)) ? task.currentRequest : nil;
    [activeCtx lock];
    activeCtx.endTime = CFAbsoluteTimeGetCurrent();
    if (liveReq) {
        activeCtx.request = liveReq;
    } else if (request && !activeCtx.request) {
        activeCtx.request = request;
    }
    if (uploadBody && !activeCtx.requestBody) activeCtx.requestBody = uploadBody;
    if (fileBytes > 0 && activeCtx.requestFileBytes == 0) activeCtx.requestFileBytes = fileBytes;
    if (mechanism.length > 0 && ![activeCtx.mechanism isEqualToString:@"LCDebugNetworkReplay"]) {
        activeCtx.mechanism = mechanism;
    }
    NSDictionary *mDict = activeCtx.metricsDict;
    [activeCtx unlock];

    NSUInteger recv = data ? data.length : (task && !LCDebugIsAVAggregateAssetTask(task) ? (NSUInteger)MAX((int64_t)0, task.countOfBytesReceived) : 0);
    [LCDebugNetworkEngine.shared recordCompletionForContext:activeCtx
                                                    response:response
                                                overrideData:data
                                               receivedBytes:recv
                                                       error:error
                                                     metrics:mDict];
}

static void LCNetInstallSessionFactoryHooks(void) {
    LCDebugSafeSwizzleClassMethod(NSURLSession.class,
                                  @selector(sessionWithConfiguration:delegate:delegateQueue:),
                                  @selector(lcNet_sessionWithConfiguration:delegate:delegateQueue:));

    for (Class candidate in LCNetSessionFactoryClasses()) {
        // 1. dataTaskWithRequest:completionHandler:
        {
            SEL sel = @selector(dataTaskWithRequest:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDataTask *(NSURLSession *selfObj, NSURLRequest *req, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(req.URL)) {
                            return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            if (!completion) {
                                NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, nil);
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.dataTask", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.mechanism = @"NSURLSession.dataTask(completion)";
                            __block __weak NSURLSessionDataTask *weakTask = nil;
                            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                                LCNetPrepareAndFinishHandlerTask(req, nil, 0, @"NSURLSession.dataTask(completion)", weakTask, resp, data, err, ctx);
                                completion(data, resp, err);
                            };
                            NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 2. dataTaskWithURL:completionHandler:
        {
            SEL sel = @selector(dataTaskWithURL:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDataTask *(NSURLSession *selfObj, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(url)) {
                            return ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLRequest *req = url ? [NSURLRequest requestWithURL:url] : nil;
                            if (!completion) {
                                NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, nil);
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.dataTask", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.mechanism = @"NSURLSession.dataTask(completion)";
                            __block __weak NSURLSessionDataTask *weakTask = nil;
                            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                                LCNetPrepareAndFinishHandlerTask(req, nil, 0, @"NSURLSession.dataTask(completion)", weakTask, resp, data, err, ctx);
                                completion(data, resp, err);
                            };
                            NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 3. uploadTaskWithRequest:fromData:completionHandler:
        {
            SEL sel = @selector(uploadTaskWithRequest:fromData:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionUploadTask *(NSURLSession *selfObj, NSURLRequest *req, NSData *bodyData, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(req.URL)) {
                            return ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, bodyData, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            if (!completion) {
                                NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, bodyData, nil);
                                LCDebugGetOrCreateTaskContext(t, req, bodyData, @"NSURLSession.uploadTask(fromData)", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.requestBody = bodyData;
                            ctx.mechanism = @"NSURLSession.uploadTask(fromData, completion)";
                            __block __weak NSURLSessionUploadTask *weakTask = nil;
                            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                                LCNetPrepareAndFinishHandlerTask(req, bodyData, 0, @"NSURLSession.uploadTask(fromData, completion)", weakTask, resp, data, err, ctx);
                                completion(data, resp, err);
                            };
                            NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, bodyData, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 4. uploadTaskWithRequest:fromFile:completionHandler:
        {
            SEL sel = @selector(uploadTaskWithRequest:fromFile:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionUploadTask *(NSURLSession *selfObj, NSURLRequest *req, NSURL *fileURL, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(req.URL)) {
                            return ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, fileURL, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSNumber *fSize = nil;
                            if (fileURL.isFileURL) [fileURL getResourceValue:&fSize forKey:NSURLFileSizeKey error:nil];
                            NSUInteger fileBytes = fSize ? fSize.unsignedIntegerValue : 0;
                            NSData *noteData = [[NSString stringWithFormat:@"<Uploaded file: %@ (%lu bytes)>", fileURL.lastPathComponent ?: @"file", (unsigned long)fileBytes] dataUsingEncoding:NSUTF8StringEncoding];
                            if (!completion) {
                                NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, fileURL, nil);
                                LCDebugNetTaskContext *ctx = LCDebugGetOrCreateTaskContext(t, req, noteData, @"NSURLSession.uploadTask(fromFile)", @"urlsession");
                                if (ctx) {
                                    [ctx lock];
                                    ctx.requestFileBytes = fileBytes;
                                    [ctx unlock];
                                }
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.requestBody = noteData;
                            ctx.requestFileBytes = fileBytes;
                            ctx.mechanism = @"NSURLSession.uploadTask(fromFile, completion)";
                            __block __weak NSURLSessionUploadTask *weakTask = nil;
                            void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
                                LCNetPrepareAndFinishHandlerTask(req, noteData, fileBytes, @"NSURLSession.uploadTask(fromFile, completion)", weakTask, resp, data, err, ctx);
                                completion(data, resp, err);
                            };
                            NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, fileURL, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 5. downloadTaskWithRequest:completionHandler:, downloadTaskWithURL:completionHandler:, downloadTaskWithResumeData:completionHandler:
        {
            SEL sel = @selector(downloadTaskWithRequest:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSURLRequest *req, void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(req.URL)) {
                            return ((NSURLSessionDownloadTask *(*)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            if (!completion) {
                                NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, nil);
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.downloadTask", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.mechanism = @"NSURLSession.downloadTask(completion)";
                            __block __weak NSURLSessionDownloadTask *weakTask = nil;
                            void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *loc, NSURLResponse *resp, NSError *err) {
                                LCDebugNetTaskContext *activeCtx = (weakTask ? LCNetGetTaskContext(weakTask) : nil) ?: ctx;
                                NSData *noteData = nil;
                                NSUInteger fBytes = 0;
                                if (loc.isFileURL) {
                                    NSNumber *fSize = nil;
                                    [loc getResourceValue:&fSize forKey:NSURLFileSizeKey error:nil];
                                    fBytes = fSize ? fSize.unsignedIntegerValue : 0;
                                    NSString *mime = resp.MIMEType ?: @"";
                                    NSUInteger maxCap = LCDebugNetworkEngine.shared.maxSingleBodyBytes;
                                    if (fBytes > 0 && fBytes <= maxCap && (!LCDebugIsMediaMime(mime) || [mime.lowercaseString hasPrefix:@"image/"])) {
                                        noteData = [NSData dataWithContentsOfURL:loc options:NSDataReadingMappedIfSafe error:nil];
                                    }
                                    if (!noteData) {
                                        noteData = [[NSString stringWithFormat:@"<Downloaded file: %@ (%lu bytes)>", loc.lastPathComponent ?: @"file", (unsigned long)fBytes] dataUsingEncoding:NSUTF8StringEncoding];
                                    }
                                }
                                [activeCtx lock];
                                activeCtx.endTime = CFAbsoluteTimeGetCurrent();
                                NSDictionary *mDict = activeCtx.metricsDict;
                                [activeCtx unlock];
                                NSUInteger recv = MAX(fBytes, (weakTask ? (NSUInteger)MAX((int64_t)0, weakTask.countOfBytesReceived) : 0));
                                [LCDebugNetworkEngine.shared recordCompletionForContext:activeCtx
                                                                                response:resp
                                                                            overrideData:noteData
                                                                           receivedBytes:recv
                                                                                   error:err
                                                                                 metrics:mDict];
                                completion(loc, resp, err);
                            };
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, req, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(downloadTaskWithURL:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSURL *url, void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic() || LCDebugIsOwnDebugRequestURL(url)) {
                            return ((NSURLSessionDownloadTask *(*)(id, SEL, NSURL *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLRequest *req = url ? [NSURLRequest requestWithURL:url] : nil;
                            if (!completion) {
                                NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURL *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, nil);
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.downloadTask", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.request = req;
                            ctx.mechanism = @"NSURLSession.downloadTask(completion)";
                            __block __weak NSURLSessionDownloadTask *weakTask = nil;
                            void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *loc, NSURLResponse *resp, NSError *err) {
                                LCDebugNetTaskContext *activeCtx = (weakTask ? LCNetGetTaskContext(weakTask) : nil) ?: ctx;
                                NSData *noteData = nil;
                                NSUInteger fBytes = 0;
                                if (loc.isFileURL) {
                                    NSNumber *fSize = nil;
                                    [loc getResourceValue:&fSize forKey:NSURLFileSizeKey error:nil];
                                    fBytes = fSize ? fSize.unsignedIntegerValue : 0;
                                    NSString *mime = resp.MIMEType ?: @"";
                                    NSUInteger maxCap = LCDebugNetworkEngine.shared.maxSingleBodyBytes;
                                    if (fBytes > 0 && fBytes <= maxCap && (!LCDebugIsMediaMime(mime) || [mime.lowercaseString hasPrefix:@"image/"])) {
                                        noteData = [NSData dataWithContentsOfURL:loc options:NSDataReadingMappedIfSafe error:nil];
                                    }
                                    if (!noteData) {
                                        noteData = [[NSString stringWithFormat:@"<Downloaded file: %@ (%lu bytes)>", loc.lastPathComponent ?: @"file", (unsigned long)fBytes] dataUsingEncoding:NSUTF8StringEncoding];
                                    }
                                }
                                [activeCtx lock];
                                activeCtx.endTime = CFAbsoluteTimeGetCurrent();
                                NSDictionary *mDict = activeCtx.metricsDict;
                                [activeCtx unlock];
                                NSUInteger recv = MAX(fBytes, (weakTask ? (NSUInteger)MAX((int64_t)0, weakTask.countOfBytesReceived) : 0));
                                [LCDebugNetworkEngine.shared recordCompletionForContext:activeCtx
                                                                                response:resp
                                                                            overrideData:noteData
                                                                           receivedBytes:recv
                                                                                   error:err
                                                                                 metrics:mDict];
                                completion(loc, resp, err);
                            };
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURL *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, url, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(downloadTaskWithResumeData:completionHandler:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSData *resumeData, void (^completion)(NSURL *, NSURLResponse *, NSError *)) {
                        if (gLCInTaskCreate || LCDebugNetworkIsPausedAtomic()) {
                            return ((NSURLSessionDownloadTask *(*)(id, SEL, NSData *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, resumeData, completion);
                        }
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            if (!completion) {
                                NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSData *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, resumeData, nil);
                                LCDebugGetOrCreateTaskContext(t, nil, nil, @"NSURLSession.downloadTask(resumeData)", @"urlsession");
                                return t;
                            }
                            LCDebugNetTaskContext *ctx = [[LCDebugNetTaskContext alloc] init];
                            ctx.mechanism = @"NSURLSession.downloadTask(resumeData, completion)";
                            __block __weak NSURLSessionDownloadTask *weakTask = nil;
                            void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *loc, NSURLResponse *resp, NSError *err) {
                                LCDebugNetTaskContext *activeCtx = (weakTask ? LCNetGetTaskContext(weakTask) : nil) ?: ctx;
                                NSData *noteData = nil;
                                NSUInteger fBytes = 0;
                                if (loc.isFileURL) {
                                    NSNumber *fSize = nil;
                                    [loc getResourceValue:&fSize forKey:NSURLFileSizeKey error:nil];
                                    fBytes = fSize ? fSize.unsignedIntegerValue : 0;
                                    noteData = [[NSString stringWithFormat:@"<Resumed download: %@ (%lu bytes)>", loc.lastPathComponent ?: @"file", (unsigned long)fBytes] dataUsingEncoding:NSUTF8StringEncoding];
                                }
                                NSURLRequest *liveReq = (weakTask && !LCDebugIsAVAggregateAssetTask(weakTask)) ? (weakTask.currentRequest ?: weakTask.originalRequest) : nil;
                                [activeCtx lock];
                                if (liveReq) activeCtx.request = liveReq;
                                activeCtx.endTime = CFAbsoluteTimeGetCurrent();
                                NSDictionary *mDict = activeCtx.metricsDict;
                                [activeCtx unlock];
                                NSUInteger recv = MAX(fBytes, (weakTask ? (NSUInteger)MAX((int64_t)0, weakTask.countOfBytesReceived) : 0));
                                [LCDebugNetworkEngine.shared recordCompletionForContext:activeCtx
                                                                                response:resp
                                                                            overrideData:noteData
                                                                           receivedBytes:recv
                                                                                   error:err
                                                                                 metrics:mDict];
                                completion(loc, resp, err);
                            };
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSData *, void (^)(NSURL *, NSURLResponse *, NSError *)))orig)(selfObj, sel, resumeData, wrapped);
                            weakTask = t;
                            if (t) {
                                os_unfair_lock_lock(&gLCTaskContextLock);
                                objc_setAssociatedObject(t, &kLCNetTaskContextKey, ctx, OBJC_ASSOCIATION_RETAIN);
                                os_unfair_lock_unlock(&gLCTaskContextLock);
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = NO;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 6. Non-completion task factories
        {
            SEL sel = @selector(dataTaskWithRequest:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDataTask *(NSURLSession *selfObj, NSURLRequest *req) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))orig)(selfObj, sel, req);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.dataTask(delegate)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(dataTaskWithURL:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDataTask *(NSURLSession *selfObj, NSURL *url) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionDataTask *t = ((NSURLSessionDataTask *(*)(id, SEL, NSURL *))orig)(selfObj, sel, url);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && url && !LCDebugIsOwnDebugRequestURL(url)) {
                                LCDebugGetOrCreateTaskContext(t, [NSURLRequest requestWithURL:url], nil, @"NSURLSession.dataTask(delegate)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(uploadTaskWithRequest:fromData:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionUploadTask *(NSURLSession *selfObj, NSURLRequest *req, NSData *bodyData) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSData *))orig)(selfObj, sel, req, bodyData);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                LCDebugGetOrCreateTaskContext(t, req, bodyData, @"NSURLSession.uploadTask(fromData)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(uploadTaskWithRequest:fromFile:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionUploadTask *(NSURLSession *selfObj, NSURLRequest *req, NSURL *fileURL) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *, NSURL *))orig)(selfObj, sel, req, fileURL);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                NSNumber *fSize = nil;
                                if (fileURL.isFileURL) [fileURL getResourceValue:&fSize forKey:NSURLFileSizeKey error:nil];
                                NSUInteger fileBytes = fSize ? fSize.unsignedIntegerValue : 0;
                                NSData *noteData = [[NSString stringWithFormat:@"<Uploaded file: %@ (%lu bytes)>", fileURL.lastPathComponent ?: @"file", (unsigned long)fileBytes] dataUsingEncoding:NSUTF8StringEncoding];
                                LCDebugNetTaskContext *ctx = LCDebugGetOrCreateTaskContext(t, req, noteData, @"NSURLSession.uploadTask(fromFile)", @"urlsession");
                                if (ctx) {
                                    [ctx lock];
                                    ctx.requestFileBytes = fileBytes;
                                    [ctx unlock];
                                }
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(uploadTaskWithStreamedRequest:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionUploadTask *(NSURLSession *selfObj, NSURLRequest *req) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionUploadTask *t = ((NSURLSessionUploadTask *(*)(id, SEL, NSURLRequest *))orig)(selfObj, sel, req);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.uploadTask(streamed)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(downloadTaskWithRequest:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSURLRequest *req) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURLRequest *))orig)(selfObj, sel, req);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.downloadTask(delegate)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(downloadTaskWithURL:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSURL *url) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSURL *))orig)(selfObj, sel, url);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && url && !LCDebugIsOwnDebugRequestURL(url)) {
                                LCDebugGetOrCreateTaskContext(t, [NSURLRequest requestWithURL:url], nil, @"NSURLSession.downloadTask(delegate)", @"urlsession");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(downloadTaskWithResumeData:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionDownloadTask *(NSURLSession *selfObj, NSData *resumeData) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionDownloadTask *t = ((NSURLSessionDownloadTask *(*)(id, SEL, NSData *))orig)(selfObj, sel, resumeData);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && t && !LCDebugIsAVAggregateAssetTask(t)) {
                                NSURLRequest *req = t.originalRequest ?: t.currentRequest;
                                if (!LCDebugIsOwnDebugRequestURL(req.URL)) {
                                    LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSession.downloadTask(resumeData)", @"urlsession");
                                }
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        // 7. WebSocket factories
        {
            SEL sel = @selector(webSocketTaskWithRequest:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionWebSocketTask *(NSURLSession *selfObj, NSURLRequest *req) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionWebSocketTask *t = ((NSURLSessionWebSocketTask *(*)(id, SEL, NSURLRequest *))orig)(selfObj, sel, req);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && !LCDebugIsOwnDebugRequestURL(req.URL)) {
                                LCDebugGetOrCreateTaskContext(t, req, nil, @"NSURLSessionWebSocketTask", @"websocket");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(webSocketTaskWithURL:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionWebSocketTask *(NSURLSession *selfObj, NSURL *url) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionWebSocketTask *t = ((NSURLSessionWebSocketTask *(*)(id, SEL, NSURL *))orig)(selfObj, sel, url);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && url && !LCDebugIsOwnDebugRequestURL(url)) {
                                LCDebugGetOrCreateTaskContext(t, [NSURLRequest requestWithURL:url], nil, @"NSURLSessionWebSocketTask", @"websocket");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }

        {
            SEL sel = @selector(webSocketTaskWithURL:protocols:);
            Class owner = LCDebugOwningClassForSelector(candidate, sel);
            if (owner && LCDebugMarkSelectorHooked(owner, sel)) {
                Method m = class_getInstanceMethod(owner, sel);
                if (m) {
                    IMP orig = method_getImplementation(m);
                    id block = ^NSURLSessionWebSocketTask *(NSURLSession *selfObj, NSURL *url, NSArray<NSString *> *protocols) {
                        BOOL wasIn = gLCInTaskCreate;
                        gLCInTaskCreate = YES;
                        gLCThreadTaskCreateSeq++;
                        @try {
                            NSURLSessionWebSocketTask *t = ((NSURLSessionWebSocketTask *(*)(id, SEL, NSURL *, NSArray<NSString *> *))orig)(selfObj, sel, url, protocols);
                            if (!wasIn && !LCDebugNetworkIsPausedAtomic() && url && !LCDebugIsOwnDebugRequestURL(url)) {
                                LCDebugGetOrCreateTaskContext(t, [NSURLRequest requestWithURL:url], nil, @"NSURLSessionWebSocketTask", @"websocket");
                            }
                            return t;
                        } @finally {
                            gLCInTaskCreate = wasIn;
                        }
                    };
                    class_replaceMethod(owner, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }
    }
}

// MARK: - Task Cluster Resume, SetDelegate & WebSocket Frame Hooks

static void LCNetInstallTaskClusterAndWebSocketHooks(void) {
    SEL resumeSel = @selector(resume);
    SEL setDelSel = NSSelectorFromString(@"setDelegate:");

    for (Class cls in LCNetTaskClusterClasses()) {
        Class resumeOwner = LCDebugOwningClassForSelector(cls, resumeSel);
        if (resumeOwner && LCDebugMarkSelectorHooked(resumeOwner, resumeSel)) {
            Method m = class_getInstanceMethod(resumeOwner, resumeSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(id selfObj) {
                    if (!LCDebugNetworkIsPausedAtomic() && [selfObj isKindOfClass:NSURLSessionTask.class] && !LCDebugIsAVAggregateAssetTask(selfObj)) {
                        NSURLSessionTask *task = (NSURLSessionTask *)selfObj;
                        NSURLRequest *curReq = LCNetSafeTaskRequest(task);
                        if (curReq && !LCDebugIsOwnDebugRequestURL(curReq.URL)) {
                            // Touch HTTPBody synchronously on caller thread to stabilize CFNetwork parser before async handoff
                            (void)curReq.HTTPBody;
                            BOOL isWS = [task isKindOfClass:NSURLSessionWebSocketTask.class];
                            NSString *src = isWS ? @"websocket" : @"urlsession";
                            NSString *mech = isWS ? @"NSURLSessionWebSocketTask" : NSStringFromClass(task.class);
                            LCDebugNetTaskContext *ctx = LCDebugGetOrCreateTaskContext(task, curReq, nil, mech, src);
                            if (ctx && [ctx tryMarkStartedOnce]) {
                                [ctx lock];
                                ctx.startTime = CFAbsoluteTimeGetCurrent();
                                ctx.request = curReq;
                                [ctx unlock];
                                [LCDebugNetworkEngine.shared recordStartForContext:ctx request:curReq];
                            }
                        }
                    }
                    ((void (*)(id, SEL))origIMP)(selfObj, resumeSel);
                };
                class_replaceMethod(resumeOwner, resumeSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }

        if (setDelSel) {
            Class setDelOwner = LCDebugOwningClassForSelector(cls, setDelSel);
            if (setDelOwner && LCDebugMarkSelectorHooked(setDelOwner, setDelSel)) {
                Method m = class_getInstanceMethod(setDelOwner, setDelSel);
                if (m) {
                    IMP origIMP = method_getImplementation(m);
                    id block = ^(id selfObj, id delegate) {
                        if (delegate) {
                            LCHookSessionDelegateIfNeeded(delegate);
                        }
                        ((void (*)(id, SEL, id))origIMP)(selfObj, setDelSel, delegate);
                    };
                    class_replaceMethod(setDelOwner, setDelSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
                }
            }
        }
    }

    Class targetWSCls = NSClassFromString(@"__NSURLSessionWebSocketTask") ?: NSURLSessionWebSocketTask.class;
    if (targetWSCls) {
        SEL sendSel = @selector(sendMessage:completionHandler:);
        Class sendOwner = LCDebugOwningClassForSelector(targetWSCls, sendSel);
        if (sendOwner && LCDebugMarkSelectorHooked(sendOwner, sendSel)) {
            Method m = class_getInstanceMethod(sendOwner, sendSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(NSURLSessionWebSocketTask *selfObj, NSURLSessionWebSocketMessage *message, void (^completion)(NSError * _Nullable)) {
                    BOOL entered = NO;
                    if (!gLCInWebSocketOp && !LCDebugNetworkIsPausedAtomic()) {
                        gLCInWebSocketOp = YES;
                        entered = YES;
                        [LCDebugNetworkEngine.shared recordWebSocketTask:selfObj direction:@"SEND" message:message closeNote:nil error:nil];
                    }
                    void (^wrapped)(NSError * _Nullable) = ^(NSError * _Nullable err) {
                        if (err && !LCDebugNetworkIsPausedAtomic()) {
                            [LCDebugNetworkEngine.shared recordWebSocketTask:selfObj direction:@"SEND_ERR" message:nil closeNote:nil error:err];
                        }
                        if (completion) completion(err);
                    };
                    @try {
                        ((void (*)(id, SEL, NSURLSessionWebSocketMessage *, void (^)(NSError * _Nullable)))origIMP)(selfObj, sendSel, message, wrapped);
                    } @finally {
                        if (entered) gLCInWebSocketOp = NO;
                    }
                };
                class_replaceMethod(sendOwner, sendSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }

        SEL recvSel = @selector(receiveMessageWithCompletionHandler:);
        Class recvOwner = LCDebugOwningClassForSelector(targetWSCls, recvSel);
        if (recvOwner && LCDebugMarkSelectorHooked(recvOwner, recvSel)) {
            Method m = class_getInstanceMethod(recvOwner, recvSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(NSURLSessionWebSocketTask *selfObj, void (^completion)(NSURLSessionWebSocketMessage * _Nullable, NSError * _Nullable)) {
                    void (^wrapped)(NSURLSessionWebSocketMessage * _Nullable, NSError * _Nullable) = ^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable err) {
                        if (!LCDebugNetworkIsPausedAtomic() && (message || err)) {
                            [LCDebugNetworkEngine.shared recordWebSocketTask:selfObj direction:err ? @"RECV_ERR" : @"RECV" message:message closeNote:nil error:err];
                        }
                        if (completion) completion(message, err);
                    };
                    ((void (*)(id, SEL, void (^)(NSURLSessionWebSocketMessage * _Nullable, NSError * _Nullable)))origIMP)(selfObj, recvSel, wrapped);
                };
                class_replaceMethod(recvOwner, recvSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }

        SEL cancelSel = @selector(cancelWithCloseCode:reason:);
        Class cancelOwner = LCDebugOwningClassForSelector(targetWSCls, cancelSel);
        if (cancelOwner && LCDebugMarkSelectorHooked(cancelOwner, cancelSel)) {
            Method m = class_getInstanceMethod(cancelOwner, cancelSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                id block = ^(NSURLSessionWebSocketTask *selfObj, NSURLSessionWebSocketCloseCode code, NSData * _Nullable reason) {
                    if (!LCDebugNetworkIsPausedAtomic()) {
                        NSString *reasonStr = reason.length > 0 ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"";
                        NSString *note = [NSString stringWithFormat:@"Closed (%ld)%@%@", (long)code, reasonStr.length > 0 ? @": " : @"", reasonStr ?: @""];
                        [LCDebugNetworkEngine.shared recordWebSocketTask:selfObj direction:@"CLOSE" message:nil closeNote:note error:nil];
                    }
                    ((void (*)(id, SEL, NSURLSessionWebSocketCloseCode, NSData *))origIMP)(selfObj, cancelSel, code, reason);
                };
                class_replaceMethod(cancelOwner, cancelSel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
            }
        }
    }
}

// MARK: - Legacy NSURLConnection Hooks

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
@implementation NSURLConnection (LCDebugNetworkEngineSwizzle)

+ (NSData *)lcNet_sendSynchronousRequest:(NSURLRequest *)request
                       returningResponse:(NSURLResponse * __autoreleasing *)response
                                   error:(NSError * __autoreleasing *)error {
    uint64_t seqBefore = gLCThreadTaskCreateSeq;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSURLResponse *localResp = nil;
    NSError *localErr = nil;
    NSData *result = [self lcNet_sendSynchronousRequest:request returningResponse:&localResp error:&localErr];
    if (response) *response = localResp;
    if (error) *error = localErr;
    if (gLCThreadTaskCreateSeq == seqBefore && !LCDebugNetworkIsPausedAtomic() && request && !LCDebugIsOwnDebugRequestURL(request.URL)) {
        [LCDebugNetworkEngine.shared recordURLConnectionRequest:request
                                                       response:localResp
                                                           data:result
                                                          error:localErr
                                                        startAt:t0
                                                      mechanism:@"NSURLConnection.sendSynchronous"];
    }
    return result;
}

+ (void)lcNet_sendAsynchronousRequest:(NSURLRequest *)request
                                  queue:(NSOperationQueue *)queue
                      completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    uint64_t seqBefore = gLCThreadTaskCreateSeq;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block _Atomic BOOL spawnedSessionTask = NO;
    void (^wrapped)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *resp, NSData *data, NSError *err) {
        if (!atomic_load(&spawnedSessionTask) && !LCDebugNetworkIsPausedAtomic() && request && !LCDebugIsOwnDebugRequestURL(request.URL)) {
            [LCDebugNetworkEngine.shared recordURLConnectionRequest:request
                                                           response:resp
                                                               data:data
                                                              error:err
                                                            startAt:t0
                                                          mechanism:@"NSURLConnection.sendAsynchronous"];
        }
        if (handler) handler(resp, data, err);
    };
    [self lcNet_sendAsynchronousRequest:request queue:queue completionHandler:wrapped];
    if (gLCThreadTaskCreateSeq != seqBefore) {
        atomic_store(&spawnedSessionTask, YES);
    }
}

@end
#pragma clang diagnostic pop

void LCDebugInstallURLSessionAndConnectionHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCNetInstallSessionFactoryHooks();
        LCNetInstallTaskClusterAndWebSocketHooks();

        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        LCDebugSafeSwizzleClassMethod(NSURLConnection.class,
                                      @selector(sendSynchronousRequest:returningResponse:error:),
                                      @selector(lcNet_sendSynchronousRequest:returningResponse:error:));
        LCDebugSafeSwizzleClassMethod(NSURLConnection.class,
                                      @selector(sendAsynchronousRequest:queue:completionHandler:),
                                      @selector(lcNet_sendAsynchronousRequest:queue:completionHandler:));
        #pragma clang diagnostic pop

        dispatch_async(dispatch_get_main_queue(), ^{
            LCBootstrapScanLoadedURLSessionDelegates();
        });
    });
}

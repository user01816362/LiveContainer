//
//  LCDebugNetworkEngine.m
//  TweakLoader
//
//  Transaction store, lifecycle upserts, on-demand body inspection, HAR 1.2
//  exporter, and in-process request replay engine.
//

@import Foundation;

#import "LCDebugNetworkEngine.h"
#import "LCDebugNetworkBodyCache.h"
#import "LCDebugURLSessionHooks.h"
#import "LCDebugWebViewHook.h"
#include <os/lock.h>
#include <stdatomic.h>

static _Atomic BOOL gLCNetHooksInstalled = NO;

static NSString *const kLCNetDefaultsPausedKey = @"LCDebugNetworkPaused";
static NSString *const kLCNetDefaultsMediaKey = @"LCDebugNetworkCacheMedia";
static NSString *const kLCNetDefaultsCacheLimitMBKey = @"LCDebugNetworkCacheLimitMB";
static NSString *const kLCNetDefaultsMaxRowsKey = @"LCDebugNetworkMaxRows";
static NSString *const kLCNetDefaultsRedactSensitiveKey = @"LCDebugNetworkRedactSensitive";
static NSString *const kLCNetDefaultsRedactKey = @"LCDebugNetworkRedactExports";
static NSString *const kLCNetDefaultsExcludedHostsKey = @"LCDebugNetworkExcludedHosts";

@interface LCDebugNetworkEngine () {
    os_unfair_lock _storeLock;
}
@property (nonatomic, strong) dispatch_queue_t recordQueue;
@property (nonatomic, strong) NSMutableArray<LCDebugNetworkTransaction *> *transactions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LCDebugNetworkTransaction *> *transactionsById;
@property (nonatomic, strong) NSMutableSet<NSString *> *excludedHosts;
@property (nonatomic, strong) LCDebugNetworkBodyCache *bodyCache;
@property (nonatomic, strong) NSURLSession *replaySession;
@end

@implementation LCDebugNetworkEngine

+ (instancetype)shared {
    static LCDebugNetworkEngine *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCDebugNetworkEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _storeLock = OS_UNFAIR_LOCK_INIT;
        _recordQueue = dispatch_queue_create("com.kdt.livecontainer.debug.network", DISPATCH_QUEUE_SERIAL);
        _transactions = [NSMutableArray array];
        _transactionsById = [NSMutableDictionary dictionary];
        _bodyCache = [[LCDebugNetworkBodyCache alloc] init];

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _recordingPaused = [defaults boolForKey:kLCNetDefaultsPausedKey];
        LCDebugNetworkSetPausedAtomic(_recordingPaused);

        if ([defaults objectForKey:kLCNetDefaultsMediaKey] != nil) {
            _cacheMediaBodies = [defaults boolForKey:kLCNetDefaultsMediaKey];
        } else {
            _cacheMediaBodies = YES;
        }
        NSInteger savedLimit = [defaults integerForKey:kLCNetDefaultsCacheLimitMBKey];
        _cacheLimitMB = (savedLimit >= 4 && savedLimit <= 50) ? savedLimit : 16;
        _bodyCache.totalCostLimit = (NSUInteger)_cacheLimitMB * 1024 * 1024;

        NSInteger savedMaxRows = [defaults integerForKey:kLCNetDefaultsMaxRowsKey];
        _maxTransactions = (savedMaxRows >= 100 && savedMaxRows <= 2000) ? savedMaxRows : 500;

        if ([defaults objectForKey:kLCNetDefaultsRedactSensitiveKey] != nil) {
            _redactSensitive = [defaults boolForKey:kLCNetDefaultsRedactSensitiveKey];
        } else {
            _redactSensitive = NO;
        }
        _redactExports = _redactSensitive;

        NSArray<NSString *> *savedHosts = [defaults stringArrayForKey:kLCNetDefaultsExcludedHostsKey];
        _excludedHosts = [NSMutableSet set];
        for (NSString *h in savedHosts) {
            NSString *norm = [self normalizeHostRule:h];
            if (norm.length > 0) [_excludedHosts addObject:norm];
        }
    }
    return self;
}

- (NSUInteger)maxSingleBodyBytes {
    return self.bodyCache.maxSingleEntryBytes;
}

- (void)installHooks {
    if (atomic_exchange(&gLCNetHooksInstalled, YES)) {
        return;
    }
    LCDebugInstallURLSessionAndConnectionHooks();
    LCDebugInstallWebViewHooks();
}

- (NSString *)normalizeHostRule:(NSString *)raw {
    NSString *trimmed = [[raw ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([trimmed hasPrefix:@"http://"]) trimmed = [trimmed substringFromIndex:7];
    if ([trimmed hasPrefix:@"https://"]) trimmed = [trimmed substringFromIndex:8];
    NSRange slash = [trimmed rangeOfString:@"/"];
    if (slash.location != NSNotFound) trimmed = [trimmed substringToIndex:slash.location];
    NSRange colon = [trimmed rangeOfString:@":"];
    if (colon.location != NSNotFound) trimmed = [trimmed substringToIndex:colon.location];
    while ([trimmed hasPrefix:@"."]) trimmed = [trimmed substringFromIndex:1];
    return trimmed;
}

- (BOOL)isURLDenied:(NSURL * _Nullable)url {
    if (!url || LCDebugIsOwnDebugRequestURL(url)) return YES;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    os_unfair_lock_lock(&_storeLock);
    NSSet<NSString *> *rules = [self.excludedHosts copy];
    os_unfair_lock_unlock(&_storeLock);
    for (NSString *rule in rules) {
        if ([host isEqualToString:rule] || [host hasSuffix:[@"." stringByAppendingString:rule]]) {
            return YES;
        }
    }
    return NO;
}

- (void)setRecordingPaused:(BOOL)recordingPaused {
    _recordingPaused = recordingPaused;
    LCDebugNetworkSetPausedAtomic(recordingPaused);
    [NSUserDefaults.standardUserDefaults setBool:recordingPaused forKey:kLCNetDefaultsPausedKey];
}

- (void)setCacheMediaBodies:(BOOL)cacheMediaBodies {
    _cacheMediaBodies = cacheMediaBodies;
    [NSUserDefaults.standardUserDefaults setBool:cacheMediaBodies forKey:kLCNetDefaultsMediaKey];
}

- (void)setCacheLimitMB:(NSInteger)cacheLimitMB {
    NSInteger clamped = MAX(4, MIN(50, cacheLimitMB));
    _cacheLimitMB = clamped;
    self.bodyCache.totalCostLimit = (NSUInteger)clamped * 1024 * 1024;
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kLCNetDefaultsCacheLimitMBKey];
}

- (void)setMaxTransactions:(NSInteger)maxTransactions {
    NSInteger clamped = MAX(100, MIN(2000, maxTransactions));
    _maxTransactions = clamped;
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kLCNetDefaultsMaxRowsKey];
    os_unfair_lock_lock(&_storeLock);
    [self trimTransactionsLocked];
    os_unfair_lock_unlock(&_storeLock);
}

- (void)setRedactSensitive:(BOOL)redactSensitive {
    _redactSensitive = redactSensitive;
    _redactExports = redactSensitive;
    [NSUserDefaults.standardUserDefaults setBool:redactSensitive forKey:kLCNetDefaultsRedactSensitiveKey];
    [NSUserDefaults.standardUserDefaults setBool:redactSensitive forKey:kLCNetDefaultsRedactKey];
}

- (void)setRedactExports:(BOOL)redactExports {
    [self setRedactSensitive:redactExports];
}

- (NSDictionary<NSString *, id> *)settingsDictionary {
    return @{
        @"paused": @(self.isRecordingPaused),
        @"cacheMediaBodies": @(self.cacheMediaBodies),
        @"cacheLimitMB": @(self.cacheLimitMB),
        @"maxTransactions": @(self.maxTransactions),
        @"redactSensitive": @(self.redactSensitive),
        @"redactExports": @(self.redactSensitive),
        @"excludedHosts": [self excludedHostsSnapshot]
    };
}

- (void)updateSettings:(NSDictionary<NSString *, id> *)updates {
    if (![updates isKindOfClass:NSDictionary.class]) return;
    if (updates[@"paused"] != nil) {
        self.recordingPaused = [updates[@"paused"] boolValue];
    }
    if (updates[@"cacheMediaBodies"] != nil) {
        self.cacheMediaBodies = [updates[@"cacheMediaBodies"] boolValue];
    }
    if (updates[@"cacheLimitMB"] != nil) {
        self.cacheLimitMB = [updates[@"cacheLimitMB"] integerValue];
    }
    if (updates[@"maxTransactions"] != nil) {
        self.maxTransactions = [updates[@"maxTransactions"] integerValue];
    }
    if (updates[@"redactSensitive"] != nil) {
        self.redactSensitive = [updates[@"redactSensitive"] boolValue];
    } else if (updates[@"redactExports"] != nil) {
        self.redactSensitive = [updates[@"redactExports"] boolValue];
    }
    if ([updates[@"excludedHosts"] isKindOfClass:NSArray.class]) {
        os_unfair_lock_lock(&_storeLock);
        [self.excludedHosts removeAllObjects];
        for (id item in (NSArray *)updates[@"excludedHosts"]) {
            if ([item isKindOfClass:NSString.class]) {
                NSString *norm = [self normalizeHostRule:item];
                if (norm.length > 0) [self.excludedHosts addObject:norm];
            }
        }
        NSArray<NSString *> *persisted = [self.excludedHosts.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        os_unfair_lock_unlock(&_storeLock);
        [NSUserDefaults.standardUserDefaults setObject:persisted forKey:kLCNetDefaultsExcludedHostsKey];
    }
}

- (NSArray<NSString *> *)excludedHostsSnapshot {
    os_unfair_lock_lock(&_storeLock);
    NSArray<NSString *> *list = [self.excludedHosts.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    os_unfair_lock_unlock(&_storeLock);
    return list;
}

- (void)addExcludedHost:(NSString *)host {
    NSString *norm = [self normalizeHostRule:host];
    if (norm.length == 0) return;
    os_unfair_lock_lock(&_storeLock);
    [self.excludedHosts addObject:norm];
    NSArray<NSString *> *persisted = [self.excludedHosts.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    os_unfair_lock_unlock(&_storeLock);
    [NSUserDefaults.standardUserDefaults setObject:persisted forKey:kLCNetDefaultsExcludedHostsKey];
}

- (void)removeExcludedHost:(NSString *)host {
    NSString *norm = [self normalizeHostRule:host];
    if (norm.length == 0) return;
    os_unfair_lock_lock(&_storeLock);
    [self.excludedHosts removeObject:norm];
    NSArray<NSString *> *persisted = [self.excludedHosts.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    os_unfair_lock_unlock(&_storeLock);
    [NSUserDefaults.standardUserDefaults setObject:persisted forKey:kLCNetDefaultsExcludedHostsKey];
}

- (void)clearExcludedHosts {
    os_unfair_lock_lock(&_storeLock);
    [self.excludedHosts removeAllObjects];
    os_unfair_lock_unlock(&_storeLock);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLCNetDefaultsExcludedHostsKey];
}

- (void)trimTransactionsLocked {
    NSUInteger limit = (NSUInteger)MAX(100, self.maxTransactions);
    while (self.transactions.count > limit) {
        LCDebugNetworkTransaction *oldest = self.transactions.lastObject;
        if (oldest) {
            [self.transactionsById removeObjectForKey:oldest.txId];
            [self.bodyCache removeObjectForKey:[oldest.txId stringByAppendingString:@":req"]];
            [self.bodyCache removeObjectForKey:[oldest.txId stringByAppendingString:@":resp"]];
        }
        [self.transactions removeLastObject];
    }
}

- (void)clearTransactions {
    os_unfair_lock_lock(&_storeLock);
    [self.transactions removeAllObjects];
    [self.transactionsById removeAllObjects];
    os_unfair_lock_unlock(&_storeLock);
    [self.bodyCache removeAllObjects];
}

- (NSArray<NSDictionary<NSString *, id> *> *)transactionsSnapshot {
    os_unfair_lock_lock(&_storeLock);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.transactions.count];
    for (LCDebugNetworkTransaction *tx in self.transactions) {
        [out addObject:[tx toCompactDictionary]];
    }
    os_unfair_lock_unlock(&_storeLock);
    return out;
}

- (NSDictionary<NSString *, id> *)statsSnapshot {
    os_unfair_lock_lock(&_storeLock);
    NSUInteger count = self.transactions.count;
    NSUInteger errCount = 0;
    NSUInteger inFlight = 0;
    uint64_t totalBytes = 0;
    for (LCDebugNetworkTransaction *tx in self.transactions) {
        if ([tx.state isEqualToString:@"pending"] || [tx.state isEqualToString:@"receiving"]) {
            inFlight++;
        } else if ([tx.state isEqualToString:@"failed"] || tx.statusCode < 0 || tx.statusCode >= 400 || tx.errorText.length > 0) {
            errCount++;
        }
        totalBytes += MAX(tx.responseBytes, tx.requestBytes);
    }
    os_unfair_lock_unlock(&_storeLock);
    return @{
        @"networkPaused": @(self.isRecordingPaused),
        @"networkRedactSensitive": @(self.redactSensitive),
        @"networkCount": @(count),
        @"networkErrorCount": @(errCount),
        @"networkInFlightCount": @(inFlight),
        @"networkTotalBytes": @(totalBytes)
    };
}

- (void)emitUpdate:(NSDictionary<NSString *, id> *)snapshotDict {
    if (!snapshotDict) return;
    void (^cb)(NSDictionary<NSString *, id> *) = self.onNetworkEventUpdate;
    if (cb) {
        cb(snapshotDict);
    }
}

- (LCDebugNetworkTransaction *)upsertTransactionLockedWithId:(NSString *)txId {
    LCDebugNetworkTransaction *tx = self.transactionsById[txId];
    if (!tx) {
        tx = [[LCDebugNetworkTransaction alloc] init];
        tx.txId = txId;
        self.transactionsById[txId] = tx;
        [self.transactions insertObject:tx atIndex:0];
        [self trimTransactionsLocked];
    }
    return tx;
}

- (void)populateRequest:(NSURLRequest *)req
               bodyData:(nullable NSData *)bodyData
              fileBytes:(NSUInteger)fileBytes
          onTransaction:(LCDebugNetworkTransaction *)tx
             txIdForKey:(NSString *)txId {
    NSURL *url = req.URL;
    tx.method = req.HTTPMethod.length > 0 ? req.HTTPMethod : @"GET";
    tx.urlString = url.absoluteString ?: @"";
    tx.host = url.host ?: @"";
    tx.path = url.path.length > 0 ? url.path : @"/";
    tx.requestHeaders = LCDebugSanitizeHeaders(req.allHTTPHeaderFields, NO);
    tx.requestEncoding = LCDebugHeaderValueCaseInsensitive(req.allHTTPHeaderFields, @"Content-Encoding") ?: @"";

    NSData *effectiveReqBody = bodyData ?: req.HTTPBody;
    if (!effectiveReqBody && req.HTTPBodyStream) {
        effectiveReqBody = LCDebugReadCopyableBodyStream(req.HTTPBodyStream, 256 * 1024);
        if (!effectiveReqBody) {
            tx.requestBodyPreview = @"<Streamed HTTPBodyStream (non-copyable)>";
        }
    }

    if (effectiveReqBody.length > 0) {
        NSData *inflatedReq = (tx.requestEncoding.length > 0)
            ? (LCDebugInflateData(effectiveReqBody, tx.requestEncoding, 1024 * 1024) ?: effectiveReqBody)
            : effectiveReqBody;
        tx.requestBytes = MAX(effectiveReqBody.length, fileBytes);
        tx.hasRequestBody = YES;
        NSString *reqMime = LCDebugHeaderValueCaseInsensitive(req.allHTTPHeaderFields, @"Content-Type");
        [self.bodyCache setData:inflatedReq
                       mimeType:reqMime
                contentEncoding:tx.requestEncoding
                         forKey:[txId stringByAppendingString:@":req"]];
        tx.requestBodyPreview = LCDebugPreviewString(inflatedReq, reqMime, 1024);

        BOOL isGQL = NO;
        NSString *gqlOp = @"";
        LCDebugDetectGraphQL(url, inflatedReq, &isGQL, &gqlOp);
        tx.isGraphQL = isGQL;
        tx.graphQLOperation = gqlOp ?: @"";
    } else if (fileBytes > 0) {
        tx.requestBytes = fileBytes;
    }

    tx.curl = LCDebugBuildCurlCommand(req, effectiveReqBody, tx.requestEncoding, NO);
}

// MARK: - Lifecycle Recording Methods

- (void)recordStartForContext:(LCDebugNetTaskContext *)ctx request:(NSURLRequest *)request {
    if (!ctx || !request || [self isURLDenied:request.URL]) return;
    [ctx lock];
    NSData *reqBodyCopy = [ctx.requestBody copy];
    NSUInteger fileBytes = ctx.requestFileBytes;
    NSString *source = [ctx.source copy];
    NSString *mech = [ctx.mechanism copy];
    NSString *redirFrom = [ctx.redirectFromId copy];
    NSString *txId = [ctx.txId copy];
    CFAbsoluteTime startTime = ctx.startTime;
    [ctx unlock];

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = [self upsertTransactionLockedWithId:txId];
        tx.timestamp = startTime;
        tx.redirectFromId = redirFrom;
        tx.state = [source isEqualToString:@"websocket"] ? @"receiving" : @"pending";
        tx.source = source ?: @"urlsession";
        tx.mechanism = mech ?: @"NSURLSessionTask";
        tx.statusCode = [source isEqualToString:@"websocket"] ? 101 : 0;
        if ([source isEqualToString:@"websocket"]) {
            tx.mimeType = @"websocket";
        }
        [self populateRequest:request bodyData:reqBodyCopy fileBytes:fileBytes onTransaction:tx txIdForKey:txId];
        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

- (void)recordResponseForContext:(LCDebugNetTaskContext *)ctx response:(NSURLResponse *)response {
    if (!ctx || !response) return;
    [ctx lock];
    NSURLRequest *req = ctx.request;
    NSString *txId = [ctx.txId copy];
    CFAbsoluteTime t0 = ctx.startTime;
    CFAbsoluteTime tResp = ctx.responseTime > 0 ? ctx.responseTime : CFAbsoluteTimeGetCurrent();
    [ctx unlock];
    if (req && [self isURLDenied:req.URL]) return;

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = self.transactionsById[txId];
        if (!tx) {
            os_unfair_lock_unlock(&self->_storeLock);
            return;
        }
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            tx.statusCode = http.statusCode;
            tx.responseHeaders = LCDebugSanitizeHeaders(http.allHeaderFields, NO);
            tx.responseEncoding = LCDebugHeaderValueCaseInsensitive(http.allHeaderFields, @"Content-Encoding") ?: @"";
        }
        tx.mimeType = response.MIMEType ?: @"";
        tx.state = @"receiving";
        tx.latencyMs = (NSInteger)MAX(0.0, llround((tResp - t0) * 1000.0));
        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

- (void)recordProgressForContext:(LCDebugNetTaskContext *)ctx {
    if (!ctx) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [ctx lock];
    if (now - ctx.lastProgressBroadcastTime < 0.25) {
        [ctx unlock];
        return;
    }
    ctx.lastProgressBroadcastTime = now;
    NSUInteger bytes = ctx.totalReceivedBytes;
    NSURLResponse *resp = ctx.response;
    NSString *txId = [ctx.txId copy];
    CFAbsoluteTime t0 = ctx.startTime;
    [ctx unlock];

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = self.transactionsById[txId];
        if (!tx || [tx.state isEqualToString:@"finished"] || [tx.state isEqualToString:@"failed"]) {
            os_unfair_lock_unlock(&self->_storeLock);
            return;
        }
        tx.state = @"receiving";
        tx.responseBytes = MAX(tx.responseBytes, bytes);
        tx.durationMs = (NSInteger)MAX(0.0, llround((now - t0) * 1000.0));
        if ([resp isKindOfClass:NSHTTPURLResponse.class] && tx.statusCode == 0) {
            tx.statusCode = ((NSHTTPURLResponse *)resp).statusCode;
            tx.mimeType = resp.MIMEType ?: @"";
        }
        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

- (void)recordCompletionForContext:(LCDebugNetTaskContext *)ctx
                          response:(nullable NSURLResponse *)response
                      overrideData:(nullable NSData *)overrideData
                     receivedBytes:(NSUInteger)receivedBytes
                             error:(nullable NSError *)error
                           metrics:(nullable NSDictionary<NSString *, id> *)metrics {
    if (!ctx || ![ctx tryMarkCompletedOnce]) return;

    [ctx lock];
    NSURLRequest *req = ctx.request;
    NSData *reqBody = ctx.requestBody;
    NSUInteger fileBytes = ctx.requestFileBytes;
    NSURLResponse *finalResp = response ?: ctx.response;
    NSData *respData = overrideData ?: [ctx.receivedData copy];
    NSUInteger totalRecv = MAX(MAX(receivedBytes, ctx.totalReceivedBytes), respData.length);
    CFAbsoluteTime startT = ctx.startTime;
    CFAbsoluteTime respT = ctx.responseTime;
    CFAbsoluteTime endT = ctx.endTime > 0 ? ctx.endTime : CFAbsoluteTimeGetCurrent();
    NSDictionary *finalMetrics = metrics ?: ctx.metricsDict;
    NSString *txId = [ctx.txId copy];
    NSString *source = [ctx.source copy];
    NSString *mech = [ctx.mechanism copy];
    NSString *redirFrom = [ctx.redirectFromId copy];
    [ctx unlock];

    if (!req || [self isURLDenied:req.URL]) return;

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = [self upsertTransactionLockedWithId:txId];
        tx.timestamp = startT;
        tx.redirectFromId = redirFrom;
        tx.source = source ?: @"urlsession";
        tx.mechanism = mech ?: @"NSURLSessionTask";
        [self populateRequest:req bodyData:reqBody fileBytes:fileBytes onTransaction:tx txIdForKey:txId];

        NSInteger status = 0;
        if ([finalResp isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)finalResp;
            status = http.statusCode;
            tx.responseHeaders = LCDebugSanitizeHeaders(http.allHeaderFields, NO);
            tx.responseEncoding = LCDebugHeaderValueCaseInsensitive(http.allHeaderFields, @"Content-Encoding") ?: @"";
        } else if ([source isEqualToString:@"websocket"]) {
            status = error ? -1 : 101;
        } else if (error) {
            status = -1;
        }
        tx.statusCode = status;
        tx.mimeType = finalResp.MIMEType ?: ([source isEqualToString:@"websocket"] ? @"websocket" : @"");
        tx.responseBytes = totalRecv;
        tx.durationMs = (NSInteger)MAX(0.0, llround((endT - startT) * 1000.0));
        if (respT > 0) {
            tx.latencyMs = (NSInteger)MAX(0.0, llround((respT - startT) * 1000.0));
        } else if (finalMetrics[@"waitMs"]) {
            tx.latencyMs = [finalMetrics[@"waitMs"] integerValue];
        }
        tx.metrics = finalMetrics;
        tx.errorText = error ? (error.localizedDescription ?: @"Request failed") : @"";
        tx.state = error ? @"failed" : @"finished";

        if (respData.length > 0) {
            NSString *mime = tx.mimeType ?: @"";
            BOOL isAudioVideo = ([mime.lowercaseString hasPrefix:@"audio/"] || [mime.lowercaseString hasPrefix:@"video/"]);
            BOOL allowCache = !isAudioVideo && (![mime.lowercaseString hasPrefix:@"image/"] || self.cacheMediaBodies);
            NSData *decodedResp = (tx.responseEncoding.length > 0 && !isAudioVideo)
                ? (LCDebugInflateData(respData, tx.responseEncoding, 2 * 1024 * 1024) ?: respData)
                : respData;
            tx.hasResponseBody = allowCache;
            if (allowCache) {
                [self.bodyCache setData:decodedResp
                               mimeType:mime
                        contentEncoding:tx.responseEncoding
                                 forKey:[txId stringByAppendingString:@":resp"]];
            }
            tx.responseBodyPreview = LCDebugPreviewString(decodedResp, mime, 1024);
        } else if (error) {
            tx.responseBodyPreview = tx.errorText;
        }

        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

- (void)recordURLConnectionRequest:(NSURLRequest *)request
                          response:(nullable NSURLResponse *)response
                              data:(nullable NSData *)data
                             error:(nullable NSError *)error
                           startAt:(CFAbsoluteTime)startAt
                         mechanism:(NSString *)mechanism {
    if (!request || [self isURLDenied:request.URL]) return;
    CFAbsoluteTime endAt = CFAbsoluteTimeGetCurrent();
    NSString *txId = NSUUID.UUID.UUIDString;

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = [self upsertTransactionLockedWithId:txId];
        tx.timestamp = startAt;
        tx.source = @"urlconnection";
        tx.mechanism = mechanism ?: @"NSURLConnection";
        [self populateRequest:request bodyData:request.HTTPBody fileBytes:0 onTransaction:tx txIdForKey:txId];
        tx.statusCode = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode
            : (error ? -1 : 0);
        tx.responseHeaders = [response isKindOfClass:NSHTTPURLResponse.class]
            ? LCDebugSanitizeHeaders(((NSHTTPURLResponse *)response).allHeaderFields, NO)
            : @{};
        tx.mimeType = response.MIMEType ?: @"";
        tx.responseBytes = data.length;
        tx.durationMs = (NSInteger)MAX(0.0, llround((endAt - startAt) * 1000.0));
        tx.errorText = error ? (error.localizedDescription ?: @"Request failed") : @"";
        tx.state = error ? @"failed" : @"finished";
        if (data.length > 0) {
            tx.hasResponseBody = YES;
            [self.bodyCache setData:data
                           mimeType:tx.mimeType
                    contentEncoding:LCDebugHeaderValueCaseInsensitive(tx.responseHeaders, @"Content-Encoding")
                             forKey:[txId stringByAppendingString:@":resp"]];
            tx.responseBodyPreview = LCDebugPreviewString(data, tx.mimeType, 1024);
        }
        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

static NSString *LCPreviewSafeText(NSData * _Nullable data, NSUInteger maxBytes) {
    if (!data || data.length == 0) return @"";
    NSData *slice = data.length > maxBytes ? [data subdataWithRange:NSMakeRange(0, maxBytes)] : data;
    NSString *utf8 = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (utf8 && [utf8 rangeOfString:@"\0"].location == NSNotFound) {
        return utf8;
    }
    return [LCDebugFormatHexPreview(slice, 128) stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

- (void)recordWebSocketTask:(NSURLSessionWebSocketTask *)task
                  direction:(NSString *)direction
                    message:(nullable NSURLSessionWebSocketMessage *)message
                  closeNote:(nullable NSString *)closeNote
                      error:(nullable NSError *)error {
    NSURLRequest *req = (!LCDebugIsAVAggregateAssetTask(task)) ? (task.currentRequest ?: task.originalRequest) : nil;
    if (req && [self isURLDenied:req.URL]) return;

    LCDebugNetTaskContext *ctx = LCDebugGetOrCreateTaskContext(task, req, nil, @"NSURLSessionWebSocketTask", @"websocket");
    if (!ctx) return;

    static NSDateFormatter *timeFmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeFmt = [[NSDateFormatter alloc] init];
        timeFmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *stamp = [timeFmt stringFromDate:NSDate.date];

    NSString *frameSummary = nil;
    NSUInteger frameBytes = 0;
    if (message) {
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSString *txt = message.string ?: @"";
            frameBytes = [txt lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            frameSummary = [NSString stringWithFormat:@"[%@] [%@] (%lu B) %@", stamp, direction, (unsigned long)frameBytes, txt];
        } else {
            NSData *d = message.data;
            frameBytes = d.length;
            NSString *preview = LCPreviewSafeText(d, 512);
            frameSummary = [NSString stringWithFormat:@"[%@] [%@] <binary %lu B> %@", stamp, direction, (unsigned long)frameBytes, preview];
        }
    } else if (closeNote.length > 0) {
        frameSummary = [NSString stringWithFormat:@"[%@] [CLOSE] %@", stamp, closeNote];
    } else if (error) {
        frameSummary = [NSString stringWithFormat:@"[%@] [%@] Error: %@", stamp, direction, error.localizedDescription ?: @"WebSocket error"];
    }
    if (!frameSummary) return;

    [ctx lock];
    NSString *txId = [ctx.txId copy];
    CFAbsoluteTime startT = ctx.startTime;
    [ctx unlock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL isClose = [direction isEqualToString:@"CLOSE"] || error != nil;
    BOOL isSend = [direction isEqualToString:@"SEND"];

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = self.transactionsById[txId];
        if (!tx) {
            tx = [self upsertTransactionLockedWithId:txId];
            tx.timestamp = startT;
            tx.source = @"websocket";
            tx.mechanism = @"NSURLSessionWebSocketTask";
            tx.statusCode = 101;
            tx.mimeType = @"websocket";
            tx.state = @"receiving";
            if (req) [self populateRequest:req bodyData:nil fileBytes:0 onTransaction:tx txIdForKey:txId];
        }
        if (!tx.wsFrames) tx.wsFrames = [NSMutableArray array];
        [tx.wsFrames addObject:frameSummary];
        if (tx.wsFrames.count > 250) {
            [tx.wsFrames removeObjectAtIndex:0];
        }
        if (isSend) {
            tx.requestBytes += frameBytes;
        } else {
            tx.responseBytes += frameBytes;
        }
        tx.durationMs = (NSInteger)MAX(0.0, llround((now - tx.timestamp) * 1000.0));
        if (isClose) {
            tx.state = error ? @"failed" : @"finished";
            if (error) tx.errorText = error.localizedDescription ?: @"WebSocket error";
        } else {
            tx.state = @"receiving";
        }
        NSString *transcript = [tx.wsFrames componentsJoinedByString:@"\n"];
        NSData *tData = [transcript dataUsingEncoding:NSUTF8StringEncoding];
        if (tData.length > 0) {
            tx.hasResponseBody = YES;
            [self.bodyCache setData:tData mimeType:@"text/plain" contentEncoding:nil forKey:[txId stringByAppendingString:@":resp"]];
            tx.responseBodyPreview = frameSummary.length > 1024 ? [[frameSummary substringToIndex:1024] stringByAppendingString:@"…"] : frameSummary;
        }
        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

- (void)recordWebViewMessage:(NSDictionary *)payload {
    NSString *urlStr = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url && [self isURLDenied:url]) return;

    NSString *txId = [payload[@"id"] isKindOfClass:NSString.class] ? payload[@"id"] : NSUUID.UUID.UUIDString;
    NSString *phase = [payload[@"phase"] isKindOfClass:NSString.class] ? payload[@"phase"] : @"finish";
    NSString *method = [payload[@"method"] isKindOfClass:NSString.class] ? payload[@"method"] : @"GET";
    NSString *mechanism = [payload[@"mechanism"] isKindOfClass:NSString.class] ? payload[@"mechanism"] : @"WKWebView";
    NSInteger statusCode = [payload[@"statusCode"] integerValue];
    NSInteger durationMs = [payload[@"durationMs"] integerValue];
    NSString *mimeType = [payload[@"mimeType"] isKindOfClass:NSString.class] ? payload[@"mimeType"] : @"";
    NSString *reqBody = [payload[@"requestBody"] isKindOfClass:NSString.class] ? payload[@"requestBody"] : @"";
    NSString *respBody = [payload[@"responseBody"] isKindOfClass:NSString.class] ? payload[@"responseBody"] : @"";
    NSInteger respBytesField = [payload[@"responseBytes"] integerValue];
    NSString *errText = [payload[@"error"] isKindOfClass:NSString.class] ? payload[@"error"] : @"";
    NSDictionary *reqHeaders = [payload[@"requestHeaders"] isKindOfClass:NSDictionary.class] ? payload[@"requestHeaders"] : @{};
    NSDictionary *respHeaders = [payload[@"responseHeaders"] isKindOfClass:NSDictionary.class] ? payload[@"responseHeaders"] : @{};

    dispatch_async(self.recordQueue, ^{
        os_unfair_lock_lock(&self->_storeLock);
        LCDebugNetworkTransaction *tx = [self upsertTransactionLockedWithId:txId];
        if (tx.timestamp == 0) tx.timestamp = CFAbsoluteTimeGetCurrent();
        tx.source = @"webview";
        tx.mechanism = mechanism;
        tx.method = method.uppercaseString;
        tx.urlString = urlStr;
        tx.host = url.host ?: @"";
        tx.path = url.path.length > 0 ? url.path : @"/";
        tx.requestHeaders = LCDebugSanitizeHeaders(reqHeaders, NO);
        tx.responseHeaders = LCDebugSanitizeHeaders(respHeaders, NO);

        if (reqBody.length > 0) {
            NSData *reqData = [reqBody dataUsingEncoding:NSUTF8StringEncoding];
            tx.requestBytes = reqData.length;
            tx.hasRequestBody = (reqData.length > 0);
            if (reqData.length > 0) {
                [self.bodyCache setData:reqData mimeType:@"text/plain" contentEncoding:nil forKey:[txId stringByAppendingString:@":req"]];
            }
            tx.requestBodyPreview = reqBody.length > 1024 ? [[reqBody substringToIndex:1024] stringByAppendingString:@"…"] : reqBody;
            BOOL isGQL = NO;
            NSString *gqlOp = @"";
            LCDebugDetectGraphQL(url, reqData, &isGQL, &gqlOp);
            tx.isGraphQL = isGQL;
            tx.graphQLOperation = gqlOp ?: @"";
        }

        if ([phase isEqualToString:@"start"]) {
            tx.state = @"pending";
        } else {
            tx.statusCode = statusCode;
            tx.mimeType = mimeType.length > 0 ? mimeType : @"text/plain";
            tx.durationMs = MAX(0, durationMs);
            tx.errorText = errText;
            tx.state = ([phase isEqualToString:@"error"] || errText.length > 0 || statusCode < 0) ? @"failed" : @"finished";
            NSData *respData = respBody.length > 0 ? [respBody dataUsingEncoding:NSUTF8StringEncoding] : nil;
            tx.responseBytes = MAX((NSUInteger)MAX(0, (int)respBytesField), respData.length);
            if (respData.length > 0) {
                tx.hasResponseBody = YES;
                [self.bodyCache setData:respData mimeType:tx.mimeType contentEncoding:nil forKey:[txId stringByAppendingString:@":resp"]];
                tx.responseBodyPreview = respBody.length > 1024 ? [[respBody substringToIndex:1024] stringByAppendingString:@"…"] : respBody;
            }
        }

        NSURL *parsedURL = url;
        NSMutableURLRequest *synthetic = parsedURL ? [NSMutableURLRequest requestWithURL:parsedURL] : nil;
        synthetic.HTTPMethod = tx.method;
        synthetic.allHTTPHeaderFields = tx.requestHeaders;
        NSData *reqData = reqBody.length > 0 ? [reqBody dataUsingEncoding:NSUTF8StringEncoding] : nil;
        tx.curl = LCDebugBuildCurlCommand(synthetic, reqData, nil, NO);

        NSDictionary *snap = [tx toCompactDictionary];
        os_unfair_lock_unlock(&self->_storeLock);
        [self emitUpdate:snap];
    });
}

// MARK: - On-Demand Full Body, HAR 1.2 Export & Replay

- (NSDictionary<NSString *, id> *)bodyPayloadForTransactionId:(NSString *)transactionID
                                                         part:(NSString *)part
                                                       redact:(BOOL)redact {
    BOOL isReq = [[part lowercaseString] isEqualToString:@"request"];
    NSString *key = [transactionID stringByAppendingString:(isReq ? @":req" : @":resp")];
    LCDebugBodyCacheNode *node = [self.bodyCache nodeForKey:key];

    os_unfair_lock_lock(&_storeLock);
    LCDebugNetworkTransaction *tx = self.transactionsById[transactionID];
    NSString *mime = node.mimeType ?: (isReq ? LCDebugHeaderValueCaseInsensitive(tx.requestHeaders, @"Content-Type") : tx.mimeType) ?: @"";
    NSString *enc = node.contentEncoding ?: (isReq ? tx.requestEncoding : tx.responseEncoding) ?: @"";
    NSString *fallbackPreview = isReq ? tx.requestBodyPreview : tx.responseBodyPreview;
    NSString *urlStr = tx.urlString ?: @"";
    NSDictionary<NSString *, NSString *> *reqHeaders = LCDebugSanitizeHeaders(tx.requestHeaders, redact);
    NSDictionary<NSString *, NSString *> *respHeaders = LCDebugSanitizeHeaders(tx.responseHeaders, redact);
    NSURL *parsedURL = (urlStr.length > 0) ? [NSURL URLWithString:urlStr] : nil;
    NSMutableURLRequest *synthetic = parsedURL ? [NSMutableURLRequest requestWithURL:parsedURL] : nil;
    if (synthetic) {
        synthetic.HTTPMethod = tx.method ?: @"GET";
        synthetic.allHTTPHeaderFields = tx.requestHeaders;
    }
    os_unfair_lock_unlock(&_storeLock);

    if (!node || node.data.length == 0) {
        return @{
            @"id": transactionID ?: @"",
            @"part": isReq ? @"request" : @"response",
            @"byteCount": @(0),
            @"mimeType": mime,
            @"encoding": enc,
            @"isBinary": @NO,
            @"isImage": @NO,
            @"text": fallbackPreview ?: @"",
            @"base64": @"",
            @"hexPreview": @"",
            @"truncated": @(fallbackPreview.length > 0),
            @"requestHeaders": reqHeaders,
            @"responseHeaders": respHeaders,
            @"curl": synthetic ? LCDebugBuildCurlCommand(synthetic, nil, enc, redact) : @""
        };
    }

    NSData *data = node.data;
    BOOL isImage = [mime.lowercaseString hasPrefix:@"image/"];
    BOOL isText = !isImage && LCDebugIsTextLikeMime(mime, data);

    NSString *text = @"";
    NSString *base64 = @"";
    NSString *hexPreview = LCDebugFormatHexPreview(data, 4096);
    BOOL truncated = NO;

    if (isImage) {
        if (data.length <= 2 * 1024 * 1024) {
            base64 = [data base64EncodedStringWithOptions:0];
        } else {
            truncated = YES;
        }
    } else if (isText) {
        NSUInteger maxTextBytes = 512 * 1024;
        NSData *slice = data.length > maxTextBytes ? [data subdataWithRange:NSMakeRange(0, maxTextBytes)] : data;
        truncated = (data.length > maxTextBytes);
        text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:slice encoding:NSISOLatin1StringEncoding]
            ?: @"";
    } else {
        NSUInteger maxB64Bytes = 256 * 1024;
        NSData *slice = data.length > maxB64Bytes ? [data subdataWithRange:NSMakeRange(0, maxB64Bytes)] : data;
        truncated = (data.length > maxB64Bytes);
        base64 = [slice base64EncodedStringWithOptions:0];
    }

    return @{
        @"id": transactionID ?: @"",
        @"part": isReq ? @"request" : @"response",
        @"byteCount": @(data.length),
        @"mimeType": mime,
        @"encoding": enc,
        @"isBinary": @(!isText),
        @"isImage": @(isImage),
        @"text": text,
        @"base64": base64,
        @"hexPreview": hexPreview,
        @"truncated": @(truncated),
        @"requestHeaders": reqHeaders,
        @"responseHeaders": respHeaders,
        @"curl": synthetic ? LCDebugBuildCurlCommand(synthetic, isReq ? data : nil, enc, redact) : @""
    };
}

- (NSData *)buildHARDataWithRedact:(BOOL)redact {
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;

    os_unfair_lock_lock(&_storeLock);
    NSMutableArray<NSDictionary<NSString *, id> *> *txSnapshots = [NSMutableArray arrayWithCapacity:self.transactions.count];
    for (LCDebugNetworkTransaction *tx in [self.transactions reverseObjectEnumerator]) {
        [txSnapshots addObject:[tx toCompactDictionary]];
    }
    os_unfair_lock_unlock(&_storeLock);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:txSnapshots.count];
    for (NSDictionary<NSString *, id> *tx in txSnapshots) {
        NSString *txId = [tx[@"id"] isKindOfClass:NSString.class] ? tx[@"id"] : @"";
        CFAbsoluteTime timestamp = [tx[@"timestamp"] doubleValue];
        NSString *urlString = [tx[@"url"] isKindOfClass:NSString.class] ? tx[@"url"] : @"";
        NSString *method = [tx[@"method"] isKindOfClass:NSString.class] ? tx[@"method"] : @"GET";
        NSString *mimeType = [tx[@"mimeType"] isKindOfClass:NSString.class] ? tx[@"mimeType"] : @"application/octet-stream";
        NSInteger statusCode = [tx[@"statusCode"] integerValue];
        NSInteger durationMs = [tx[@"durationMs"] integerValue];
        NSInteger latencyMs = [tx[@"latencyMs"] integerValue];
        NSUInteger requestBytes = [tx[@"requestBytes"] unsignedIntegerValue];
        NSUInteger responseBytes = [tx[@"responseBytes"] unsignedIntegerValue];
        NSString *errorText = [tx[@"error"] isKindOfClass:NSString.class] ? tx[@"error"] : @"";
        NSDictionary *metrics = [tx[@"metrics"] isKindOfClass:NSDictionary.class] ? tx[@"metrics"] : nil;
        NSDictionary *rawReqHeaders = [tx[@"requestHeaders"] isKindOfClass:NSDictionary.class] ? tx[@"requestHeaders"] : @{};
        NSDictionary *rawRespHeaders = [tx[@"responseHeaders"] isKindOfClass:NSDictionary.class] ? tx[@"responseHeaders"] : @{};

        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:timestamp];
        NSDictionary *reqHeaders = LCDebugSanitizeHeaders(rawReqHeaders, redact);
        NSDictionary *respHeaders = LCDebugSanitizeHeaders(rawRespHeaders, redact);

        NSMutableArray *harReqHeaders = [NSMutableArray array];
        [reqHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            [harReqHeaders addObject:@{ @"name": k, @"value": v }];
        }];
        NSMutableArray *harRespHeaders = [NSMutableArray array];
        [respHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            [harRespHeaders addObject:@{ @"name": k, @"value": v }];
        }];

        NSMutableArray *harQuery = [NSMutableArray array];
        NSURLComponents *comp = [NSURLComponents componentsWithString:urlString];
        for (NSURLQueryItem *qi in comp.queryItems) {
            [harQuery addObject:@{ @"name": qi.name ?: @"", @"value": qi.value ?: @"" }];
        }

        NSMutableDictionary *postData = nil;
        LCDebugBodyCacheNode *reqNode = [self.bodyCache nodeForKey:[txId stringByAppendingString:@":req"]];
        if (reqNode.data.length > 0 && reqNode.data.length <= 131072 && LCDebugIsTextLikeMime(reqNode.mimeType, reqNode.data)) {
            NSString *reqTxt = [[NSString alloc] initWithData:reqNode.data encoding:NSUTF8StringEncoding];
            if (reqTxt) {
                postData = [@{
                    @"mimeType": reqNode.mimeType ?: @"application/octet-stream",
                    @"text": reqTxt
                } mutableCopy];
            }
        }

        NSMutableDictionary *content = [@{
            @"size": @(responseBytes),
            @"mimeType": mimeType.length > 0 ? mimeType : @"application/octet-stream"
        } mutableCopy];
        LCDebugBodyCacheNode *respNode = [self.bodyCache nodeForKey:[txId stringByAppendingString:@":resp"]];
        if (respNode.data.length > 0 && respNode.data.length <= 262144) {
            if (LCDebugIsTextLikeMime(mimeType, respNode.data)) {
                NSString *txt = [[NSString alloc] initWithData:respNode.data encoding:NSUTF8StringEncoding];
                if (txt) content[@"text"] = txt;
            } else {
                content[@"text"] = [respNode.data base64EncodedStringWithOptions:0];
                content[@"encoding"] = @"base64";
            }
        }

        NSMutableDictionary *harReq = [@{
            @"method": method,
            @"url": urlString,
            @"httpVersion": metrics[@"protocolName"] ?: @"HTTP/1.1",
            @"headers": harReqHeaders,
            @"queryString": harQuery,
            @"cookies": @[],
            @"headersSize": @(-1),
            @"bodySize": @(requestBytes)
        } mutableCopy];
        if (postData) harReq[@"postData"] = postData;

        NSDictionary *harEntry = @{
            @"startedDateTime": [iso stringFromDate:date] ?: @"",
            @"time": @(durationMs),
            @"request": harReq,
            @"response": @{
                @"status": @(MAX(0, (int)statusCode)),
                @"statusText": statusCode > 0 ? [NSHTTPURLResponse localizedStringForStatusCode:statusCode] : errorText,
                @"httpVersion": metrics[@"protocolName"] ?: @"HTTP/1.1",
                @"headers": harRespHeaders,
                @"cookies": @[],
                @"content": content,
                @"redirectURL": @"",
                @"headersSize": @(-1),
                @"bodySize": @(responseBytes)
            },
            @"cache": @{},
            @"timings": @{
                @"dns": metrics[@"dnsMs"] ?: @(-1),
                @"connect": metrics[@"connectMs"] ?: @(-1),
                @"ssl": metrics[@"tlsMs"] ?: @(-1),
                @"send": metrics[@"requestMs"] ?: @(0),
                @"wait": @(MAX(0, (int)latencyMs)),
                @"receive": metrics[@"responseMs"] ?: @(MAX(0, (int)(durationMs - latencyMs)))
            }
        };
        [entries addObject:harEntry];
    }

    NSDictionary *har = @{
        @"log": @{
            @"version": @"1.2",
            @"creator": @{
                @"name": @"LiveContainer Debug Studio",
                @"version": @"1.0"
            },
            @"entries": entries
        }
    };
    return [NSJSONSerialization dataWithJSONObject:har options:NSJSONWritingPrettyPrinted error:nil]
        ?: [NSData dataWithBytes:"{}" length:2];
}

- (void)replayRequestWithPayload:(NSDictionary<NSString *, id> *)payload
                      completion:(void (^)(NSDictionary<NSString *, id> *result))completion {
    NSString *urlStr = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : @"";
    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) || LCDebugIsOwnDebugRequestURL(url)) {
        if (completion) completion(@{ @"ok": @NO, @"error": @"Invalid or disallowed replay URL" });
        return;
    }

    NSString *txId = [payload[@"transactionId"] isKindOfClass:NSString.class] ? payload[@"transactionId"] : nil;
    NSString *method = [payload[@"method"] isKindOfClass:NSString.class] ? [payload[@"method"] uppercaseString] : @"GET";
    NSDictionary *headers = [payload[@"headers"] isKindOfClass:NSDictionary.class] ? payload[@"headers"] : nil;
    NSString *bodyString = [payload[@"body"] isKindOfClass:NSString.class] ? payload[@"body"] : nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method.length > 0 ? method : @"GET";
    if (headers) {
        [headers enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && [val isKindOfClass:NSString.class]) {
                NSString *lk = ((NSString *)key).lowercaseString;
                if ([lk isEqualToString:@"content-length"] || [lk isEqualToString:@"host"]) return;
                [req setValue:val forHTTPHeaderField:key];
            }
        }];
    }
    if (bodyString != nil) {
        req.HTTPBody = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    } else if (txId.length > 0 && ![req.HTTPMethod isEqualToString:@"GET"] && ![req.HTTPMethod isEqualToString:@"HEAD"]) {
        LCDebugBodyCacheNode *reqNode = [self.bodyCache nodeForKey:[txId stringByAppendingString:@":req"]];
        if (reqNode.data.length > 0) {
            req.HTTPBody = reqNode.data;
        }
    }

    os_unfair_lock_lock(&_storeLock);
    NSURLSession *session = self.replaySession;
    if (!session) {
        NSURLSessionConfiguration *replayCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        replayCfg.timeoutIntervalForRequest = 30;
        replayCfg.timeoutIntervalForResource = 60;
        session = [NSURLSession sessionWithConfiguration:replayCfg];
        self.replaySession = session;
    }
    os_unfair_lock_unlock(&_storeLock);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSInteger elapsed = (NSInteger)MAX(0.0, llround((CFAbsoluteTimeGetCurrent() - t0) * 1000.0));
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : (err ? -1 : 0);
        if (completion) {
            completion(@{
                @"ok": @(err == nil),
                @"statusCode": @(status),
                @"durationMs": @(elapsed),
                @"bytes": @(data.length),
                @"error": err ? (err.localizedDescription ?: @"Replay failed") : @""
            });
        }
    }];
    LCDebugGetOrCreateTaskContext(task, req, req.HTTPBody, @"LCDebugNetworkReplay", @"urlsession");
    [task resume];
}

@end

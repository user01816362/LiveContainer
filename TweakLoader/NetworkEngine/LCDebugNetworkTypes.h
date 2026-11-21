//
//  LCDebugNetworkTypes.h
//  TweakLoader
//
//  Shared runtime safety primitives, method swizzling helpers, compression/cURL
//  utilities, and transaction models for LiveContainer's NetworkEngine.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Validates whether an Objective-C Class is safe for runtime method/ivar inspection.
FOUNDATION_EXPORT BOOL LCDebugIsSafeObjCClass(Class _Nullable cls);

/// Safely swizzles an instance method on `cls`, returning YES when exchanged.
FOUNDATION_EXPORT BOOL LCDebugSafeSwizzleInstanceMethod(Class _Nullable cls, SEL originalSel, SEL swizzledSel);

/// Safely swizzles a class method on `cls`, returning YES when exchanged.
FOUNDATION_EXPORT BOOL LCDebugSafeSwizzleClassMethod(Class _Nullable cls, SEL originalSel, SEL swizzledSel);

/// Finds the exact class in `cls`'s hierarchy that defines `sel` directly.
FOUNDATION_EXPORT Class _Nullable LCDebugOwningClassForSelector(Class _Nullable cls, SEL sel);

/// Atomically records `(ownerCls, sel)` as hooked, returning YES only the first time.
FOUNDATION_EXPORT BOOL LCDebugMarkSelectorHooked(Class ownerCls, SEL sel);

/// Returns YES if `cls` overrides `forwardingTargetForSelector:` or `forwardInvocation:`.
FOUNDATION_EXPORT BOOL LCDebugClassOverridesForwarding(Class cls);

/// Returns YES if `task` is an `AVAggregateAssetDownloadTask` (unsafe for `.currentRequest`).
FOUNDATION_EXPORT BOOL LCDebugIsAVAggregateAssetTask(id _Nullable task);

/// Escapes single quotes for POSIX shell single-quoted literals.
FOUNDATION_EXPORT NSString *LCEscapeSingleQuotes(NSString * _Nullable raw);

/// Configures loopback and LAN ports belonging to LiveContainer's own debug HTTP server.
FOUNDATION_EXPORT void LCDebugNetworkSetExcludedLocalPorts(uint16_t localPort, uint16_t lanPort);

/// Returns YES if `url` targets LiveContainer's own local debug server.
FOUNDATION_EXPORT BOOL LCDebugIsOwnDebugRequestURL(NSURL * _Nullable url);

/// Global pause atomic flag checked by all network/webview hooks.
FOUNDATION_EXPORT BOOL LCDebugNetworkIsPausedAtomic(void);
FOUNDATION_EXPORT void LCDebugNetworkSetPausedAtomic(BOOL paused);

/// Case-insensitive header lookup and sensitive-header redaction.
FOUNDATION_EXPORT NSString * _Nullable LCDebugHeaderValueCaseInsensitive(NSDictionary * _Nullable headers, NSString *name);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *LCDebugSanitizeHeaders(NSDictionary * _Nullable headers, BOOL redactSensitive);

/// Inflates gzip, zlib, deflate, or Brotli payloads up to `maxOutputBytes`.
FOUNDATION_EXPORT NSData * _Nullable LCDebugInflateData(NSData * _Nullable data,
                                                        NSString * _Nullable contentEncoding,
                                                        NSUInteger maxOutputBytes);

/// Reads up to `maxBytes` from a copyable `NSInputStream` without consuming the original stream.
FOUNDATION_EXPORT NSData * _Nullable LCDebugReadCopyableBodyStream(NSInputStream * _Nullable stream, NSUInteger maxBytes);

/// MIME & preview helpers.
FOUNDATION_EXPORT BOOL LCDebugIsTextLikeMime(NSString * _Nullable mimeType, NSData * _Nullable data);
FOUNDATION_EXPORT BOOL LCDebugIsMediaMime(NSString * _Nullable mimeType);
FOUNDATION_EXPORT NSString *LCDebugPreviewString(NSData * _Nullable data, NSString * _Nullable mimeType, NSUInteger maxBytes);
FOUNDATION_EXPORT NSString *LCDebugFormatHexPreview(NSData * _Nullable data, NSUInteger maxBytes);
FOUNDATION_EXPORT void LCDebugDetectGraphQL(NSURL * _Nullable url,
                                            NSData * _Nullable bodyData,
                                            BOOL *outIsGraphQL,
                                            NSString * _Nonnull __autoreleasing * _Nonnull outOperation);

/// Builds a shell-safe cURL command for a request with optional sensitive-header redaction.
FOUNDATION_EXPORT NSString *LCDebugBuildCurlCommand(NSURLRequest * _Nullable request,
                                                    NSData * _Nullable overrideBody,
                                                    NSString * _Nullable contentEncoding,
                                                    BOOL redactSensitive);

// MARK: - Per-Task Context & Recorded Transaction Models

@interface LCDebugNetTaskContext : NSObject
@property (nonatomic, copy) NSString *txId;
@property (nonatomic, copy, nullable) NSString *redirectFromId;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *mechanism;
@property (nonatomic, strong, nullable) NSURLRequest *request;
@property (nonatomic, strong, nullable) NSData *requestBody;
@property (nonatomic, assign) NSUInteger requestFileBytes;
@property (nonatomic, strong, nullable) NSURLResponse *response;
@property (nonatomic, strong, nullable) NSMutableData *receivedData;
@property (nonatomic, assign) NSUInteger totalReceivedBytes;
@property (nonatomic, assign) BOOL truncatedForCache;
@property (nonatomic, assign) CFAbsoluteTime startTime;
@property (nonatomic, assign) CFAbsoluteTime responseTime;
@property (nonatomic, assign) CFAbsoluteTime endTime;
@property (nonatomic, assign) CFAbsoluteTime lastProgressBroadcastTime;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *metricsDict;

- (void)lock;
- (void)unlock;
- (void)markStarted;
- (BOOL)tryMarkStartedOnce;
- (BOOL)tryMarkCompletedOnce;
- (void)appendResponseChunk:(NSData *)chunk maxCaptureBytes:(NSUInteger)maxCaptureBytes;
@end

@interface LCDebugNetworkTransaction : NSObject
@property (nonatomic, copy) NSString *txId;
@property (nonatomic, copy, nullable) NSString *redirectFromId;
@property (nonatomic, assign) CFAbsoluteTime timestamp;
@property (nonatomic, copy) NSString *state; // pending | receiving | finished | failed
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *mechanism;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, copy) NSString *requestEncoding;
@property (nonatomic, copy) NSString *responseEncoding;
@property (nonatomic, assign) NSInteger latencyMs;
@property (nonatomic, assign) NSInteger durationMs;
@property (nonatomic, assign) NSUInteger requestBytes;
@property (nonatomic, assign) NSUInteger responseBytes;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (nonatomic, copy) NSString *requestBodyPreview;
@property (nonatomic, copy) NSString *responseBodyPreview;
@property (nonatomic, assign) BOOL hasRequestBody;
@property (nonatomic, assign) BOOL hasResponseBody;
@property (nonatomic, assign) BOOL isGraphQL;
@property (nonatomic, copy) NSString *graphQLOperation;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *metrics;
@property (nonatomic, copy) NSString *curl;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic, strong, nullable) NSMutableArray<NSString *> *wsFrames;

- (NSDictionary<NSString *, id> *)toCompactDictionary;
@end

NS_ASSUME_NONNULL_END

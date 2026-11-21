//
//  LCDebugNetworkEngine.h
//  TweakLoader
//
//  Coordinator, transaction store, HAR 1.2 exporter, and in-process request
//  replay engine for LiveContainer's modular NetworkEngine.
//

#import <Foundation/Foundation.h>
#import "LCDebugNetworkTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface LCDebugNetworkEngine : NSObject

+ (instancetype)shared;

/// Invoked whenever a transaction starts, updates in-flight, or finishes/fails.
@property (nonatomic, copy, nullable) void (^onNetworkEventUpdate)(NSDictionary<NSString *, id> *entry);

/// Invoked when the WKWebView JS bridge captures console output or uncaught page errors.
@property (nonatomic, copy, nullable) void (^onWebViewConsoleLog)(NSString *level, NSString *text);

@property (nonatomic, assign, getter=isRecordingPaused) BOOL recordingPaused;
@property (nonatomic, assign) BOOL cacheMediaBodies;
@property (nonatomic, assign) NSInteger cacheLimitMB;
@property (nonatomic, assign) NSInteger maxTransactions;
@property (nonatomic, assign) BOOL redactSensitive;
@property (nonatomic, assign) BOOL redactExports;
@property (nonatomic, readonly) NSUInteger maxSingleBodyBytes;

/// Installs NSURLSession, WebSocket, NSURLConnection, and WKWebView hooks once.
- (void)installHooks;

/// Thread-safe snapshot of recent transactions (newest first), excluding large bodies.
- (NSArray<NSDictionary<NSString *, id> *> *)transactionsSnapshot;

/// Aggregate network metrics for `/api/status` telemetry.
- (NSDictionary<NSString *, id> *)statsSnapshot;

/// Current persisted capture & privacy settings for `/api/network/settings`.
- (NSDictionary<NSString *, id> *)settingsDictionary;

/// Applies partial settings updates.
- (void)updateSettings:(NSDictionary<NSString *, id> *)updates;

/// Excluded host management.
- (NSArray<NSString *> *)excludedHostsSnapshot;
- (void)addExcludedHost:(NSString *)host;
- (void)removeExcludedHost:(NSString *)host;
- (void)clearExcludedHosts;

/// Clears recorded transactions and frees all cached request/response bodies.
- (void)clearTransactions;

/// Fetches the cached full request or response body for `transactionID`.
- (NSDictionary<NSString *, id> *)bodyPayloadForTransactionId:(NSString *)transactionID
                                                         part:(NSString *)part
                                                       redact:(BOOL)redact;

/// Exports retained HTTP/HTTPS transactions in HAR 1.2 JSON format.
- (NSData *)buildHARDataWithRedact:(BOOL)redact;

/// Replays an HTTP/HTTPS request through an ephemeral session inside the guest app.
- (void)replayRequestWithPayload:(NSDictionary<NSString *, id> *)payload
                      completion:(void (^)(NSDictionary<NSString *, id> *result))completion;

// Internal hook ingestion entry points used by LCDebugURLSessionHooks & LCDebugWebViewHook
- (void)recordStartForContext:(LCDebugNetTaskContext *)ctx request:(NSURLRequest *)request;
- (void)recordResponseForContext:(LCDebugNetTaskContext *)ctx response:(NSURLResponse *)response;
- (void)recordProgressForContext:(LCDebugNetTaskContext *)ctx;
- (void)recordCompletionForContext:(LCDebugNetTaskContext *)ctx
                          response:(nullable NSURLResponse *)response
                      overrideData:(nullable NSData *)overrideData
                     receivedBytes:(NSUInteger)receivedBytes
                             error:(nullable NSError *)error
                           metrics:(nullable NSDictionary<NSString *, id> *)metrics;
- (void)recordWebSocketTask:(NSURLSessionWebSocketTask *)task
                  direction:(NSString *)direction
                    message:(nullable NSURLSessionWebSocketMessage *)message
                  closeNote:(nullable NSString *)closeNote
                      error:(nullable NSError *)error;
- (void)recordWebViewMessage:(NSDictionary *)payload;
- (void)recordURLConnectionRequest:(NSURLRequest *)request
                          response:(nullable NSURLResponse *)response
                              data:(nullable NSData *)data
                             error:(nullable NSError *)error
                           startAt:(CFAbsoluteTime)startAt
                         mechanism:(NSString *)mechanism;

@end

NS_ASSUME_NONNULL_END

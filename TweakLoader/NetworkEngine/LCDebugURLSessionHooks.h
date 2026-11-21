//
//  LCDebugURLSessionHooks.h
//  TweakLoader
//
//  Non-invasive JIT-less Foundation network observation hooks for NSURLSession,
//  NSURLSessionTask cluster subclasses, NSURLSessionWebSocketTask frames, and
//  legacy NSURLConnection. Does not weaken or bypass TLS certificate validation.
//

#import <Foundation/Foundation.h>
#import "LCDebugNetworkTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Installs all NSURLSession, task cluster, WebSocket frame, and NSURLConnection hooks.
FOUNDATION_EXPORT void LCDebugInstallURLSessionAndConnectionHooks(void);

/// Attaches or updates a `LCDebugNetTaskContext` on `task` in a thread-safe manner.
FOUNDATION_EXPORT LCDebugNetTaskContext * _Nullable LCDebugGetOrCreateTaskContext(NSURLSessionTask * _Nullable task,
                                                                                   NSURLRequest * _Nullable req,
                                                                                   NSData * _Nullable uploadBody,
                                                                                   NSString * _Nullable mechanism,
                                                                                   NSString * _Nullable source);

NS_ASSUME_NONNULL_END

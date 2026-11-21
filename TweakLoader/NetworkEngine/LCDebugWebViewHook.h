//
//  LCDebugWebViewHook.h
//  TweakLoader
//
//  Isolated WKWebView JavaScript bridge capturing fetch(), XMLHttpRequest,
//  navigator.sendBeacon, console.*, window.onerror, and unhandledrejection.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs WKWebView initialization hooks (`initWithFrame:configuration:` and `initWithCoder:`)
/// and forwards captured DOM network events and console logs to `LCDebugNetworkEngine.shared`.
FOUNDATION_EXPORT void LCDebugInstallWebViewHooks(void);

NS_ASSUME_NONNULL_END

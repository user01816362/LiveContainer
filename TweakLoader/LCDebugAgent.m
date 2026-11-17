//
//  LCDebugAgent.m
//  TweakLoader
//
//  In-process live developer instrumentation agent for LiveContainer.
//  Provides real-time stdout/stderr streaming, NSURLProtocol HTTP/HTTPS sniffing,
//  Mach telemetry & FPS monitoring, UI X-Ray & Tap-to-Inspect, hierarchy/dyld/ObjC
//  runtime inspection, sandbox/Keychain inspection, and a live-toggleable
//  127.0.0.1 + LAN (0.0.0.0 + Bonjour _http._tcp) HTTP/SSE Web Console.
//

@import Foundation;
@import UIKit;
@import QuartzCore;
@import Security;

#include <arpa/inet.h>
#include <dlfcn.h>
#include <dns_sd.h>
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
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#import "../LiveContainer/utils.h"

extern NSDictionary *LCProfileGetTelemetrySnapshot(void);

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif

static _Atomic uint16_t gLCDebugLocalPort = 0;
static _Atomic uint16_t gLCDebugLANPort = 0;

static uint32_t (*g_orig_dyld_image_count)(void) = NULL;
static const char *(*g_orig_dyld_get_image_name)(uint32_t) = NULL;
static const struct mach_header *(*g_orig_dyld_get_image_header)(uint32_t) = NULL;

static uint32_t LCDebugImageCount(void) {
    return g_orig_dyld_image_count ? g_orig_dyld_image_count() : _dyld_image_count();
}

static const char *LCDebugImageName(uint32_t idx) {
    return g_orig_dyld_get_image_name ? g_orig_dyld_get_image_name(idx) : _dyld_get_image_name(idx);
}

static const struct mach_header *LCDebugImageHeader(uint32_t idx) {
    return g_orig_dyld_get_image_header ? g_orig_dyld_get_image_header(idx) : _dyld_get_image_header(idx);
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

// MARK: - Networking Helper

/**
 Resolves the best active IPv4 LAN interface address (`en0`/`en1` first, then other `en*`/`bridge*`).

 Uses `dlsym(RTLD_NEXT, ...)` so `DYLD_INTERPOSE(hook_getifaddrs, getifaddrs)` in
 `UIKit+GuestHooks.m` does not conceal the LAN IP needed to display the Mac Web Console URL.
 */
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

static UIWindow *LCActiveGuestWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (win.isKeyWindow && !win.isHidden) {
                return win;
            }
        }
        for (UIWindow *win in ws.windows) {
            if (!win.isHidden && win.alpha > 0.0) {
                return win;
            }
        }
    }
    return nil;
}

// MARK: - Forward Declarations

@interface LCDebugServer : NSObject
+ (instancetype)shared;
- (void)start;
- (void)appendLogStream:(NSString *)stream text:(NSString *)text;
- (void)recordNetworkEvent:(NSDictionary *)entry;
- (NSDictionary *)currentStatusDictionary;
- (void)setXRayEnabled:(BOOL)enabled;
- (void)setTapInspectEnabled:(BOOL)enabled;
- (void)setLANEnabled:(BOOL)enabled;
@end

// MARK: - NSURLProtocol Network Sniffer

static NSString *const kLCDebugHandledProperty = @"LCDebugURLProtocolHandled";

@interface LCDebugURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *proxyTask;
@property (nonatomic, strong) NSMutableData *capturedResponseData;
@property (nonatomic, strong) NSURLResponse *capturedResponse;
@property (nonatomic, assign) CFAbsoluteTime startTime;
@end

static NSURLSession *LCDebugProxySession(void) {
    static NSURLSession *proxySession = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSMutableArray *classes = [(cfg.protocolClasses ?: @[]) mutableCopy];
        [classes removeObject:[LCDebugURLProtocol class]];
        cfg.protocolClasses = classes;
        proxySession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return proxySession;
}

static NSString *LCBuildCurlCommand(NSURLRequest *req) {
    NSMutableString *curl = [NSMutableString stringWithFormat:@"curl -X %@", req.HTTPMethod ?: @"GET"];
    [req.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        NSString *escaped = [v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [curl appendFormat:@" -H '%@: %@'", k, escaped];
    }];
    if (req.HTTPBody.length > 0 && req.HTTPBody.length <= 4096) {
        NSString *bodyStr = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
        if (bodyStr) {
            NSString *escaped = [bodyStr stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
            [curl appendFormat:@" --data '%@'", escaped];
        }
    }
    [curl appendFormat:@" '%@'", req.URL.absoluteString ?: @""];
    return curl;
}

@implementation LCDebugURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kLCDebugHandledProperty inRequest:request]) {
        return NO;
    }
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return NO;
    }
    // Never capture traffic going to our own debug console server
    NSString *host = request.URL.host.lowercaseString;
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) {
        NSNumber *port = request.URL.port;
        if (port) {
            uint16_t reqPort = port.unsignedShortValue;
            uint16_t localPort = atomic_load(&gLCDebugLocalPort);
            uint16_t lanPort = atomic_load(&gLCDebugLANPort);
            if ((localPort > 0 && reqPort == localPort) || (lanPort > 0 && reqPort == lanPort)) {
                return NO;
            }
        }
    }
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    self.startTime = CFAbsoluteTimeGetCurrent();
    self.capturedResponseData = [NSMutableData data];

    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kLCDebugHandledProperty inRequest:mutableReq];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [LCDebugProxySession() dataTaskWithRequest:mutableReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        CFAbsoluteTime elapsedMs = (CFAbsoluteTimeGetCurrent() - strongSelf.startTime) * 1000.0;
        NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : (error ? -1 : 0);

        NSString *preview = @"";
        if (data.length > 0) {
            NSData *slice = data.length > 8192 ? [data subdataWithRange:NSMakeRange(0, 8192)] : data;
            preview = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding]
                ?: [NSString stringWithFormat:@"<Binary %lu bytes>", (unsigned long)data.length];
        } else if (error) {
            preview = error.localizedDescription ?: @"Request failed";
        }

        NSString *reqBodyPreview = @"";
        if (strongSelf.request.HTTPBody.length > 0) {
            NSData *slice = strongSelf.request.HTTPBody.length > 4096
                ? [strongSelf.request.HTTPBody subdataWithRange:NSMakeRange(0, 4096)]
                : strongSelf.request.HTTPBody;
            reqBodyPreview = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding]
                ?: [NSString stringWithFormat:@"<Binary %lu bytes>", (unsigned long)strongSelf.request.HTTPBody.length];
        }

        NSDictionary *respHeaders = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).allHeaderFields ?: @{}
            : @{};

        [LCDebugServer.shared recordNetworkEvent:@{
            @"id": NSUUID.UUID.UUIDString,
            @"timestamp": @(CFAbsoluteTimeGetCurrent()),
            @"method": strongSelf.request.HTTPMethod ?: @"GET",
            @"url": strongSelf.request.URL.absoluteString ?: @"",
            @"statusCode": @(statusCode),
            @"mimeType": response.MIMEType ?: @"",
            @"durationMs": @((NSInteger)llround(elapsedMs)),
            @"bytes": @(data.length),
            @"requestHeaders": strongSelf.request.allHTTPHeaderFields ?: @{},
            @"responseHeaders": respHeaders,
            @"requestBodyPreview": reqBodyPreview,
            @"responseBodyPreview": preview,
            @"curl": LCBuildCurlCommand(strongSelf.request),
            @"error": error ? (error.localizedDescription ?: @"") : @""
        }];

        if (error) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }
        if (response) {
            [strongSelf.client URLProtocol:strongSelf didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }
        if (data.length > 0) {
            [strongSelf.client URLProtocol:strongSelf didLoadData:data];
        }
        [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
    }];
    self.proxyTask = task;
    [task resume];
}

- (void)stopLoading {
    [self.proxyTask cancel];
    self.proxyTask = nil;
}

@end

@implementation NSURLSessionConfiguration (LCDebugNetworkHook)

+ (NSURLSessionConfiguration *)lcDebug_defaultSessionConfiguration {
    NSURLSessionConfiguration *cfg = [self lcDebug_defaultSessionConfiguration];
    NSMutableArray *classes = [(cfg.protocolClasses ?: @[]) mutableCopy];
    if (![classes containsObject:[LCDebugURLProtocol class]]) {
        [classes insertObject:[LCDebugURLProtocol class] atIndex:0];
        cfg.protocolClasses = classes;
    }
    return cfg;
}

+ (NSURLSessionConfiguration *)lcDebug_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = [self lcDebug_ephemeralSessionConfiguration];
    NSMutableArray *classes = [(cfg.protocolClasses ?: @[]) mutableCopy];
    if (![classes containsObject:[LCDebugURLProtocol class]]) {
        [classes insertObject:[LCDebugURLProtocol class] atIndex:0];
        cfg.protocolClasses = classes;
    }
    return cfg;
}

@end

// MARK: - X-Ray & Tap Inspect Helpers

static char kLCXRaySavedBorderKey;

static UIColor *LCDebugColorForClassName(NSString *name) {
    NSUInteger h = name.hash;
    CGFloat hue = ((h & 0xFF) / 255.0);
    return [UIColor colorWithHue:hue saturation:0.85 brightness:0.95 alpha:0.9];
}

static void LCApplyXRayToView(UIView *view, BOOL enabled) {
    if (!view || [NSStringFromClass(view.class) hasPrefix:@"LCDebug"]) {
        return;
    }
    CALayer *layer = view.layer;
    NSArray *saved = objc_getAssociatedObject(view, &kLCXRaySavedBorderKey);
    if (enabled) {
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
    for (UIView *sub in view.subviews) {
        LCApplyXRayToView(sub, enabled);
    }
}

@interface LCDebugInspectOverlayView : UIView
@property (nonatomic, strong) UIView *highlightBox;
@property (nonatomic, copy) void (^onInspectView)(NSDictionary *info);
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
    UIWindow *win = self.window;
    if (!win) return;
    CGPoint pt = [tap locationInView:win];
    self.hidden = YES;
    UIView *hit = [win hitTest:pt withEvent:nil];
    self.hidden = NO;
    if (!hit) return;

    CGRect rectInSelf = [hit convertRect:hit.bounds toView:self];
    self.highlightBox.frame = rectInSelf;
    self.highlightBox.hidden = NO;

    NSString *vcName = @"";
    UIResponder *responder = hit.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            vcName = NSStringFromClass(responder.class);
            break;
        }
        responder = responder.nextResponder;
    }

    NSDictionary *info = @{
        @"class": NSStringFromClass(hit.class) ?: @"",
        @"viewController": vcName ?: @"",
        @"frame": NSStringFromCGRect(hit.frame) ?: @"",
        @"bounds": NSStringFromCGRect(hit.bounds) ?: @"",
        @"accessibilityIdentifier": hit.accessibilityIdentifier ?: @"",
        @"accessibilityLabel": hit.accessibilityLabel ?: @"",
        @"alpha": @(hit.alpha),
        @"hidden": @(hit.isHidden),
        @"tag": @(hit.tag),
        @"backgroundColor": hit.backgroundColor ? [hit.backgroundColor description] : @"",
        @"subviewCount": @(hit.subviews.count)
    };
    if (self.onInspectView) {
        self.onInspectView(info);
    }
}

@end

// MARK: - Single-Process Floating Pill (Classic Mode Fallback)

@interface LCDebugClassicPillWindow : UIWindow
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation LCDebugClassicPillWindow
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
    "<div class='pills'><strong id='title'>LiveContainer Debug</strong><span class='pill' id='p-pid'>PID -</span><span class='pill' id='p-cpu'>CPU -</span><span class='pill' id='p-ram'>RAM -</span><span class='pill' id='p-fps'>FPS -</span><span class='pill' id='p-jit'>JIT -</span></div>"
    "<div class='pills'><button class='btn' id='b-xray' onclick=\"act('toggle_xray')\">UI X-Ray</button><button class='btn' id='b-tap' onclick=\"act('toggle_tap_inspect')\">Tap Inspect</button><button class='btn' onclick=\"act('memory_warning')\">Mem Warning</button><button class='btn' onclick=\"act('clear_logs')\">Clear Logs</button></div>"
    "</header>"
    "<div class='tabs'>"
    "<button class='tab active' onclick=\"showTab('console',this)\">Console</button>"
    "<button class='tab' onclick=\"showTab('network',this)\">Network</button>"
    "<button class='tab' onclick=\"showTab('hierarchy',this);loadHierarchy()\">Hierarchy</button>"
    "<button class='tab' onclick=\"showTab('dylibs',this);loadDylibs();searchClasses()\">Dylibs & ObjC</button>"
    "<button class='tab' onclick=\"showTab('sandbox',this);loadSandbox()\">Sandbox & Keys</button>"
    "<button class='tab' onclick=\"showTab('frida',this);loadFrida()\">Frida / LLDB</button>"
    "</div>"
    "<main>"
    "<div id='tapbanner' class='row' style='display:none'></div>"
    "<div id='console' class='panel active'><input class='search' id='logFilter' placeholder='Filter logs...' oninput='renderLogs()'/><div class='logbox' id='logbox'></div></div>"
    "<div id='network' class='panel'><div id='netlist'></div></div>"
    "<div id='hierarchy' class='panel'><div class='logbox' id='hierbox'>Loading...</div></div>"
    "<div id='dylibs' class='panel'><input class='search' id='clsQ' placeholder='Search Objective-C class...' oninput='searchClasses()'/><div id='dylibbox'></div><div id='clsbox'></div></div>"
    "<div id='sandbox' class='panel'><div class='logbox' id='sbox'>Loading...</div></div>"
    "<div id='frida' class='panel'><div class='logbox' id='fbox'>Loading...</div></div>"
    "</main>"
    "<script>"
    "let logs=[],nets=[];"
    "function showTab(id,el){document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.getElementById(id).classList.add('active');el.classList.add('active');}"
    "function applyStatus(s){document.getElementById('title').textContent=s.bundleId||'LiveContainer';document.getElementById('p-pid').textContent='PID '+s.pid;document.getElementById('p-cpu').textContent='CPU '+(s.cpuPercent||0).toFixed(1)+'%';document.getElementById('p-ram').textContent='RAM '+(s.memoryMB||0).toFixed(1)+' MB';document.getElementById('p-fps').textContent=(s.fps||0)+' FPS';document.getElementById('p-jit').textContent=s.isJIT?'JIT ON':'JIT OFF';document.getElementById('b-xray').classList.toggle('on',!!s.xrayEnabled);document.getElementById('b-tap').classList.toggle('on',!!s.tapInspectEnabled);if(s.selectedView){let b=document.getElementById('tapbanner');b.style.display='block';b.innerHTML='<strong>Inspected View:</strong> <code>'+s.selectedView.class+'</code> | VC: <code>'+(s.selectedView.viewController||'-')+'</code> | '+s.selectedView.frame;}}"
    "function renderLogs(){let q=document.getElementById('logFilter').value.toLowerCase();let el=document.getElementById('logbox');el.textContent=logs.filter(l=>!q||(l.text||'').toLowerCase().includes(q)).map(l=>'['+l.stream+'] '+l.text).join('\\n');el.scrollTop=el.scrollHeight;}"
    "function renderNets(){let el=document.getElementById('netlist');el.innerHTML=nets.map((n,i)=>'<div class=\"row\"><div><strong>'+n.method+'</strong> ['+n.statusCode+'] '+n.durationMs+'ms · '+n.bytes+'B · <code>'+n.url+'</code></div><details style=\"margin-top:6px\"><summary>Details & cURL</summary><pre>'+((n.curl||'')+'\\n\\nResponse Preview:\\n'+(n.responseBodyPreview||'')).replace(/</g,'&lt;')+'</pre></details></div>').join('');}"
    "async function act(name){await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:name})});if(name==='clear_logs'){logs=[];renderLogs();}}"
    "async function loadHierarchy(){let r=await fetch('/api/hierarchy');document.getElementById('hierbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function loadDylibs(){let r=await fetch('/api/dylibs');let d=await r.json();document.getElementById('dylibbox').innerHTML='<h4>Loaded Images ('+d.length+')</h4><div class=\"logbox\" style=\"max-height:220px\">'+d.map(x=>x.base+'  '+x.path).join('\\n')+'</div>';}"
    "async function searchClasses(){let q=document.getElementById('clsQ').value;let r=await fetch('/api/classes?q='+encodeURIComponent(q));let d=await r.json();document.getElementById('clsbox').innerHTML='<h4>ObjC Classes ('+d.length+')</h4><div class=\"logbox\" style=\"max-height:220px\">'+d.join('\\n')+'</div>';}"
    "async function loadSandbox(){let r=await fetch('/api/sandbox');document.getElementById('sbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function loadFrida(){let r=await fetch('/api/frida');document.getElementById('fbox').textContent=JSON.stringify(await r.json(),null,2);}"
    "async function boot(){"
    "applyStatus(await(await fetch('/api/status')).json());"
    "logs=await(await fetch('/api/logs')).json();renderLogs();"
    "nets=await(await fetch('/api/network')).json();renderNets();"
    "const es=new EventSource('/api/stream');"
    "es.addEventListener('telemetry',e=>applyStatus(JSON.parse(e.data)));"
    "es.addEventListener('log',e=>{logs.push(JSON.parse(e.data));if(logs.length>600)logs.shift();renderLogs();});"
    "es.addEventListener('network',e=>{nets.unshift(JSON.parse(e.data));if(nets.length>200)nets.pop();renderNets();});"
    "es.addEventListener('tap',e=>{let s={bundleId:document.getElementById('title').textContent,selectedView:JSON.parse(e.data)};applyStatus(s);});"
    "}"
    "boot();"
    "</script></body></html>";
}

// MARK: - Core Server & Telemetry

@interface LCDebugServer ()
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *logs;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *networkEntries;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sseClientFDs;

@property (nonatomic, assign) int localListenFD;
@property (nonatomic, assign) uint16_t localPort;
@property (nonatomic, strong) dispatch_source_t localAcceptSource;

@property (nonatomic, assign) int lanListenFD;
@property (nonatomic, assign) uint16_t lanPort;
@property (nonatomic, strong) dispatch_source_t lanAcceptSource;
@property (nonatomic, assign) DNSServiceRef bonjourRef;
@property (nonatomic, strong) dispatch_source_t bonjourSource;

@property (nonatomic, assign) int savedStdoutFD;
@property (nonatomic, assign) int savedStderrFD;
@property (nonatomic, strong) dispatch_source_t stdoutSource;
@property (nonatomic, strong) dispatch_source_t stderrSource;

@property (nonatomic, strong) dispatch_source_t telemetryTimer;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSUInteger frameCounter;
@property (nonatomic, assign) CFTimeInterval lastFPSTimestamp;
@property (nonatomic, assign) NSInteger currentFPS;
@property (nonatomic, assign) double lastCPUPercent;
@property (nonatomic, assign) double lastMemoryMB;
@property (nonatomic, assign) NSUInteger lastThreadCount;
@property (nonatomic, assign) BOOL lastJITState;

@property (nonatomic, assign) BOOL xrayEnabled;
@property (nonatomic, assign) BOOL tapInspectEnabled;
@property (nonatomic, assign) BOOL lanEnabled;
@property (nonatomic, strong) NSDictionary *selectedViewInfo;
@property (nonatomic, strong) LCDebugInspectOverlayView *inspectOverlay;
@property (nonatomic, strong) LCDebugClassicPillWindow *classicPillWindow;
@end

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
        _serverQueue = dispatch_queue_create("com.kdt.livecontainer.debugserver", DISPATCH_QUEUE_SERIAL);
        _logs = [NSMutableArray array];
        _networkEntries = [NSMutableArray array];
        _sseClientFDs = [NSMutableArray array];
        _localListenFD = -1;
        _lanListenFD = -1;
        _savedStdoutFD = -1;
        _savedStderrFD = -1;
        _bonjourRef = NULL;
    }
    return self;
}

- (void)start {
    signal(SIGPIPE, SIG_IGN);

    [self installLogTee];
    [self installNetworkHooks];
    [self startLocalServer];
    [self startTelemetry];

    if ([NSUserDefaults respondsToSelector:@selector(lcSharedDefaults)]) {
        if ([[NSUserDefaults lcSharedDefaults] boolForKey:@"LCDebugLANEnabled"]) {
            [self setLANEnabled:YES];
        }
    }

    if ([NSUserDefaults respondsToSelector:@selector(isLiveProcess)] && ![NSUserDefaults isLiveProcess]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self installClassicPillHUD];
        });
    }
}

- (void)installLogTee {
    int outPipe[2];
    if (pipe(outPipe) == 0) {
        self.savedStdoutFD = dup(STDOUT_FILENO);
        dup2(outPipe[1], STDOUT_FILENO);
        close(outPipe[1]);
        fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
        int readFD = outPipe[0];
        int passthroughFD = self.savedStdoutFD;
        self.stdoutSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)readFD, 0, self.serverQueue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.stdoutSource, ^{
            char buf[4096];
            ssize_t n = read(readFD, buf, sizeof(buf) - 1);
            if (n > 0) {
                if (passthroughFD >= 0) write(passthroughFD, buf, (size_t)n);
                buf[n] = '\0';
                NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSISOLatin1StringEncoding];
                if (s.length > 0) [weakSelf appendLogStream:@"stdout" text:s];
            }
        });
        dispatch_source_set_cancel_handler(self.stdoutSource, ^{
            close(readFD);
        });
        dispatch_resume(self.stdoutSource);
    }

    int errPipe[2];
    if (pipe(errPipe) == 0) {
        self.savedStderrFD = dup(STDERR_FILENO);
        dup2(errPipe[1], STDERR_FILENO);
        close(errPipe[1]);
        fcntl(errPipe[0], F_SETFL, O_NONBLOCK);
        int readFD = errPipe[0];
        int passthroughFD = self.savedStderrFD;
        self.stderrSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)readFD, 0, self.serverQueue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.stderrSource, ^{
            char buf[4096];
            ssize_t n = read(readFD, buf, sizeof(buf) - 1);
            if (n > 0) {
                if (passthroughFD >= 0) write(passthroughFD, buf, (size_t)n);
                buf[n] = '\0';
                NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding]
                    ?: [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSISOLatin1StringEncoding];
                if (s.length > 0) [weakSelf appendLogStream:@"stderr" text:s];
            }
        });
        dispatch_source_set_cancel_handler(self.stderrSource, ^{
            close(readFD);
        });
        dispatch_resume(self.stderrSource);
    }
}

- (void)installNetworkHooks {
    [NSURLProtocol registerClass:[LCDebugURLProtocol class]];
    swizzleClassMethod(NSURLSessionConfiguration.class,
                       @selector(defaultSessionConfiguration),
                       @selector(lcDebug_defaultSessionConfiguration));
    swizzleClassMethod(NSURLSessionConfiguration.class,
                       @selector(ephemeralSessionConfiguration),
                       @selector(lcDebug_ephemeralSessionConfiguration));
}

- (void)appendLogStream:(NSString *)stream text:(NSString *)text {
    if (text.length == 0) return;
    dispatch_async(self.serverQueue, ^{
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            NSDictionary *entry = @{
                @"id": NSUUID.UUID.UUIDString,
                @"timestamp": @(CFAbsoluteTimeGetCurrent()),
                @"stream": stream ?: @"stdout",
                @"text": line
            };
            [self.logs addObject:entry];
            if (self.logs.count > 600) {
                [self.logs removeObjectAtIndex:0];
            }
            [self broadcastSSEEvent:"log" payload:entry];
        }
    });
}

- (void)recordNetworkEvent:(NSDictionary *)entry {
    if (!entry) return;
    dispatch_async(self.serverQueue, ^{
        [self.networkEntries insertObject:entry atIndex:0];
        if (self.networkEntries.count > 200) {
            [self.networkEntries removeLastObject];
        }
        [self broadcastSSEEvent:"network" payload:entry];
    });
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
        if (self.classicPillWindow.statusLabel) {
            self.classicPillWindow.statusLabel.text = [NSString stringWithFormat:@"DBG %ld FPS · %.0f MB", (long)self.currentFPS, self.lastMemoryMB];
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

    [self publishSharedSessionInfo];
    [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionaryUnsafe]];
}

- (NSDictionary *)currentStatusDictionaryUnsafe {
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"Unknown";
    NSString *lanIP = self.lanEnabled ? (LCBestLANIPv4Address() ?: @"") : @"";
    return @{
        @"pid": @(getpid()),
        @"bundleId": bundleId,
        @"localPort": @(self.localPort),
        @"lanPort": @(self.lanPort),
        @"lanEnabled": @(self.lanEnabled),
        @"lanIP": lanIP,
        @"cpuPercent": @(self.lastCPUPercent),
        @"memoryMB": @(self.lastMemoryMB),
        @"fps": @(self.currentFPS),
        @"threadCount": @(self.lastThreadCount),
        @"isJIT": @(self.lastJITState),
        @"xrayEnabled": @(self.xrayEnabled),
        @"tapInspectEnabled": @(self.tapInspectEnabled),
        @"selectedView": self.selectedViewInfo ?: NSNull.null,
        @"profileTelemetry": LCProfileGetTelemetrySnapshot() ?: @{}
    };
}

- (NSDictionary *)currentStatusDictionary {
    __block NSDictionary *res = nil;
    dispatch_sync(self.serverQueue, ^{
        res = [self currentStatusDictionaryUnsafe];
    });
    return res;
}

- (void)publishSharedSessionInfo {
    if (![NSUserDefaults respondsToSelector:@selector(lcSharedDefaults)]) return;
    NSString *lanIP = self.lanEnabled ? (LCBestLANIPv4Address() ?: @"") : @"";
    NSDictionary *session = @{
        @"pid": @(getpid()),
        @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"Unknown",
        @"localPort": @(self.localPort),
        @"lanPort": @(self.lanPort),
        @"lanEnabled": @(self.lanEnabled),
        @"lanIP": lanIP,
        @"updatedAt": @(CFAbsoluteTimeGetCurrent())
    };
    [[NSUserDefaults lcSharedDefaults] setObject:session forKey:@"LCDebugActiveSession"];
}

// MARK: - HTTP + SSE Socket Server

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
        [self publishSharedSessionInfo];
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
        [self publishSharedSessionInfo];
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionaryUnsafe]];
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
            dispatch_source_set_event_handler(self.bonjourSource, ^{
                if (self.bonjourRef) {
                    DNSServiceProcessResult(self.bonjourRef);
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
            [weakSelf handleClientSocket:clientFD];
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(listenFD);
    });
    dispatch_resume(src);
    return src;
}

- (void)handleClientSocket:(int)clientFD {
    // Read HTTP request on an async concurrent queue so blocking clients never stall accept loop.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

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
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].integerValue;
            }
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
        [strongSelf routeMethod:method target:fullPath body:bodyData clientFD:clientFD];
    });
}

- (void)writeResponseFD:(int)fd status:(int)status contentType:(const char *)ctype data:(NSData *)body {
    NSString *statusText = status == 200 ? @"OK" : (status == 404 ? @"Not Found" : @"Bad Request");
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %lu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n",
        status, statusText, ctype, (unsigned long)body.length];
    NSData *hdrData = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, hdrData.bytes, hdrData.length, 0);
    if (body.length > 0) {
        size_t sent = 0;
        const uint8_t *ptr = body.bytes;
        while (sent < body.length) {
            ssize_t n = send(fd, ptr + sent, body.length - sent, 0);
            if (n <= 0) break;
            sent += (size_t)n;
        }
    }
    close(fd);
}

- (void)broadcastSSEEvent:(const char *)eventType payload:(id)payload {
    if (self.sseClientFDs.count == 0) return;
    NSString *json = LCJSONStringFromObject(payload);
    NSString *frame = [NSString stringWithFormat:@"event: %s\ndata: %@\n\n", eventType, json];
    NSData *data = [frame dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableIndexSet *deadIndices = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < self.sseClientFDs.count; i++) {
        int fd = self.sseClientFDs[i].intValue;
        ssize_t n = send(fd, data.bytes, data.length, 0);
        if (n <= 0) {
            [deadIndices addIndex:i];
            close(fd);
        }
    }
    if (deadIndices.count > 0) {
        [self.sseClientFDs removeObjectsAtIndexes:deadIndices];
    }
}

- (void)routeMethod:(NSString *)method target:(NSString *)target body:(NSData *)body clientFD:(int)clientFD {
    NSURLComponents *comp = [NSURLComponents componentsWithString:target];
    NSString *path = comp.path ?: target;

    if ([method isEqualToString:@"OPTIONS"]) {
        [self writeResponseFD:clientFD status:200 contentType:"text/plain" data:[NSData data]];
        return;
    }

    if ([path isEqualToString:@"/api/stream"]) {
        const char *sseHeader =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/event-stream\r\n"
            "Cache-Control: no-cache\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Connection: keep-alive\r\n\r\n";
        if (send(clientFD, sseHeader, strlen(sseHeader), 0) <= 0) {
            close(clientFD);
            return;
        }
        dispatch_async(self.serverQueue, ^{
            [self.sseClientFDs addObject:@(clientFD)];
            NSDictionary *status = [self currentStatusDictionaryUnsafe];
            NSString *initFrame = [NSString stringWithFormat:@"event: telemetry\ndata: %@\n\n", LCJSONStringFromObject(status)];
            NSData *initData = [initFrame dataUsingEncoding:NSUTF8StringEncoding];
            send(clientFD, initData.bytes, initData.length, 0);
        });
        return;
    }

    if ([path isEqualToString:@"/"]) {
        NSData *html = [LCDebugWebConsoleHTML() dataUsingEncoding:NSUTF8StringEncoding];
        [self writeResponseFD:clientFD status:200 contentType:"text/html; charset=utf-8" data:html];
        return;
    }

    if ([path isEqualToString:@"/api/status"]) {
        NSDictionary *status = [self currentStatusDictionary];
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(status)];
        return;
    }

    if ([path isEqualToString:@"/api/logs"]) {
        __block NSArray *snapshot = nil;
        dispatch_sync(self.serverQueue, ^{
            snapshot = [self.logs copy];
        });
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(snapshot ?: @[])];
        return;
    }

    if ([path isEqualToString:@"/api/network"]) {
        __block NSArray *snapshot = nil;
        dispatch_sync(self.serverQueue, ^{
            snapshot = [self.networkEntries copy];
        });
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(snapshot ?: @[])];
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
            BOOL en = [json[@"enabled"] boolValue];
            [self setLANEnabled:en];
        } else if ([action isEqualToString:@"toggle_xray"]) {
            __block BOOL next = NO;
            dispatch_sync(self.serverQueue, ^{
                next = !self.xrayEnabled;
            });
            [self setXRayEnabled:next];
        } else if ([action isEqualToString:@"toggle_tap_inspect"]) {
            __block BOOL next = NO;
            dispatch_sync(self.serverQueue, ^{
                next = !self.tapInspectEnabled;
            });
            [self setTapInspectEnabled:next];
        } else if ([action isEqualToString:@"memory_warning"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:UIApplication.sharedApplication];
                SEL memSel = sel_registerName("_performMemoryWarning");
                if ([UIApplication.sharedApplication respondsToSelector:memSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, memSel);
                }
            });
            [self appendLogStream:@"debug" text:@"Simulated UIApplication memory warning"];
        } else if ([action isEqualToString:@"clear_logs"]) {
            dispatch_async(self.serverQueue, ^{
                [self.logs removeAllObjects];
            });
        } else if ([action isEqualToString:@"clear_network"]) {
            dispatch_async(self.serverQueue, ^{
                [self.networkEntries removeAllObjects];
            });
        }
        [self writeResponseFD:clientFD status:200 contentType:"application/json" data:LCJSONDataFromObject(@{ @"ok": @YES })];
        return;
    }

    [self writeResponseFD:clientFD status:404 contentType:"application/json" data:LCJSONDataFromObject(@{ @"error": @"Not Found" })];
}

// MARK: - Runtime & UI Introspection

- (void)setXRayEnabled:(BOOL)enabled {
    dispatch_async(self.serverQueue, ^{
        self.xrayEnabled = enabled;
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionaryUnsafe]];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                LCApplyXRayToView(win, enabled);
            }
        }
    });
}

- (void)setTapInspectEnabled:(BOOL)enabled {
    dispatch_async(self.serverQueue, ^{
        self.tapInspectEnabled = enabled;
        [self broadcastSSEEvent:"telemetry" payload:[self currentStatusDictionaryUnsafe]];
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
                    dispatch_async(strongSelf.serverQueue, ^{
                        strongSelf.selectedViewInfo = info;
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
    if (!view || depth > 16 || *budget <= 0 || [NSStringFromClass(view.class) hasPrefix:@"LCDebug"]) {
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
        UIWindow *win = LCActiveGuestWindow();
        if (!win) return;
        NSInteger budget = 600;
        NSDictionary *root = LCSerializeViewNode(win, 0, &budget);
        result = @{
            @"windowClass": NSStringFromClass(win.class) ?: @"UIWindow",
            @"rootViewController": win.rootViewController ? (NSStringFromClass(win.rootViewController.class) ?: @"") : @"",
            @"tree": root ?: @{}
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
    for (NSString *sub in @[@"Documents", @"Library/Preferences", @"tmp"]) {
        NSString *dir = [home stringByAppendingPathComponent:sub];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in items) {
            if (topFiles.count >= 120) break;
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
        @"fridaGadgetTip": @"Drop FridaGadget.dylib into this app's Tweaks folder (or Global Tweaks) to spawn a Frida RPC server on launch.",
        @"lldbCmd": [NSString stringWithFormat:@"process attach --pid %d", getpid()]
    };
}

// MARK: - Classic Mode In-App Pill Fallback

- (void)installClassicPillHUD {
    UIWindow *guestWin = LCActiveGuestWindow();
    if (!guestWin.windowScene) return;

    LCDebugClassicPillWindow *pillWin = [[LCDebugClassicPillWindow alloc] initWithWindowScene:guestWin.windowScene];
    pillWin.frame = CGRectMake(16, 56, 178, 34);
    pillWin.windowLevel = UIWindowLevelAlert + 50;
    pillWin.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    pillWin.layer.cornerRadius = 17;
    pillWin.layer.borderColor = [UIColor.systemCyanColor colorWithAlphaComponent:0.5].CGColor;
    pillWin.layer.borderWidth = 1.0;
    pillWin.clipsToBounds = YES;

    UIViewController *vc = [[UIViewController alloc] init];
    UILabel *lbl = [[UILabel alloc] initWithFrame:pillWin.bounds];
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = UIColor.whiteColor;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.text = @"DBG Starting…";
    [vc.view addSubview:lbl];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleClassicPillPan:)];
    [vc.view addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleClassicPillTap)];
    [vc.view addGestureRecognizer:tap];

    pillWin.rootViewController = vc;
    pillWin.statusLabel = lbl;
    pillWin.hidden = NO;
    self.classicPillWindow = pillWin;
}

- (void)handleClassicPillPan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.classicPillWindow];
    self.classicPillWindow.center = CGPointMake(self.classicPillWindow.center.x + t.x, self.classicPillWindow.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self.classicPillWindow];
}

- (void)handleClassicPillTap {
    NSDictionary *st = [self currentStatusDictionary];
    NSString *msg = [NSString stringWithFormat:@"PID: %@\nLocal Port: %@\nLAN Enabled: %@ (%@:%@)",
                     st[@"pid"], st[@"localPort"], st[@"lanEnabled"], st[@"lanIP"], st[@"lanPort"]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"LiveContainer Debug" message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:self.xrayEnabled ? @"Disable UI X-Ray" : @"Enable UI X-Ray" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setXRayEnabled:!weakSelf.xrayEnabled];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:self.lanEnabled ? @"Disable Mac LAN Console" : @"Enable Mac LAN Console" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf setLANEnabled:!weakSelf.lanEnabled];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Simulate Memory Warning" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:UIApplication.sharedApplication];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self.classicPillWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

@end

// MARK: - Public Entry Point

void LCDebugAgentInitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL shouldEnable = NO;
        if ([NSUserDefaults respondsToSelector:@selector(guestAppInfo)]) {
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

        g_orig_dyld_image_count = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "orig_dyld_image_count");
        g_orig_dyld_get_image_name = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "orig_dyld_get_image_name");
        g_orig_dyld_get_image_header = (const struct mach_header *(*)(uint32_t))dlsym(RTLD_DEFAULT, "orig_dyld_get_image_header");

        [LCDebugServer.shared start];
    });
}

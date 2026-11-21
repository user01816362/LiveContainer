//
//  LCDebugWebViewHook.m
//  TweakLoader
//
//  Isolated WKWebView JavaScript instrumentation bridge for LiveContainer.
//

@import Foundation;
@import WebKit;

#import "LCDebugWebViewHook.h"
#import "LCDebugNetworkTypes.h"
#import "LCDebugNetworkEngine.h"

static char kLCNetWKInstalledKey;
static NSString *const kLCNetWKHandlerName = @"lcDebugBridge";

@interface LCDebugNetWKScriptHandler : NSObject <WKScriptMessageHandler>
@end

@implementation LCDebugNetWKScriptHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = (NSDictionary *)message.body;
    NSString *kind = [dict[@"kind"] isKindOfClass:NSString.class] ? dict[@"kind"] : @"";
    if ([kind isEqualToString:@"console"]) {
        NSString *level = [dict[@"level"] isKindOfClass:NSString.class] ? dict[@"level"] : @"info";
        NSString *text = [dict[@"text"] isKindOfClass:NSString.class] ? dict[@"text"] : @"";
        void (^logCB)(NSString *, NSString *) = LCDebugNetworkEngine.shared.onWebViewConsoleLog;
        if (text.length > 0 && logCB) {
            logCB(level, text);
        }
    } else if ([kind isEqualToString:@"network"] && !LCDebugNetworkIsPausedAtomic()) {
        [LCDebugNetworkEngine.shared recordWebViewMessage:dict];
    }
}

@end

static NSString *LCNetWebViewHookScript(void) {
    return @
    "(function(){"
    "if(window.__lcDebugHooked)return;window.__lcDebugHooked=true;"
    "var seq=1;"
    "function nextId(){return 'wv-'+(Date.now()).toString(36)+'-'+(seq++);}"
    "function post(o){try{window.webkit.messageHandlers.lcDebugBridge.postMessage(o);}catch(e){}}"
    "function absUrl(u){try{var raw=(typeof u==='string')?u:(u&&(u.url||u.href)?String(u.url||u.href):String(u||''));return new URL(raw,location.href).href;}catch(e){return String(u||'');}}"
    "function fmt(args){return Array.prototype.slice.call(args).map(function(a){try{return typeof a==='object'?JSON.stringify(a):String(a);}catch(e){return String(a);}}).join(' ');}"
    "function hdrObj(h){var o={};if(!h)return o;try{if(typeof h.forEach==='function'){h.forEach(function(v,k){o[k]=v;});}else if(Array.isArray(h)){h.forEach(function(p){if(p&&p.length>=2)o[String(p[0])]=String(p[1]);});}else if(typeof h==='object'){Object.keys(h).forEach(function(k){o[k]=String(h[k]);});}}catch(e){}return o;}"
    "function bodyStr(b){try{if(!b)return '';if(typeof b==='string')return b.slice(0,65536);if(b instanceof URLSearchParams)return b.toString().slice(0,65536);if(b instanceof FormData)return '<FormData>';if(b instanceof Blob)return '<Blob '+b.size+'B>';return '';}catch(e){return '';}}"
    "['log','info','warn','error','debug'].forEach(function(lv){var orig=console[lv];console[lv]=function(){post({kind:'console',level:lv==='log'?'info':lv,text:fmt(arguments)});if(orig)return orig.apply(console,arguments);};});"
    "window.addEventListener('error',function(ev){post({kind:'console',level:'error',text:'JS Error: '+(ev.message||'')+' @ '+(ev.filename||'')+':'+(ev.lineno||0)});});"
    "window.addEventListener('unhandledrejection',function(ev){post({kind:'console',level:'error',text:'Unhandled Rejection: '+String(ev.reason||'')});});"
    "if(window.fetch){var origFetch=window.fetch;window.fetch=function(input,init){var id=nextId();var t0=Date.now();var url=absUrl(input);var method=((init&&init.method)||(input&&input.method)||'GET').toUpperCase();var reqH=hdrObj((init&&init.headers)||(input&&input.headers));var reqB=bodyStr(init&&init.body);post({kind:'network',phase:'start',id:id,mechanism:'WKWebView.fetch',method:method,url:url,requestHeaders:reqH,requestBody:reqB});return origFetch.apply(this,arguments).then(function(res){var dur=Date.now()-t0;var respH=hdrObj(res.headers);var ct=(res.headers&&res.headers.get('content-type'))||'';var cl=parseInt((res.headers&&res.headers.get('content-length'))||'0',10)||0;var textLike=!ct||/json|text|xml|javascript|form|graphql|svg/i.test(ct);if(textLike&&cl<=524288){try{res.clone().text().then(function(txt){post({kind:'network',phase:'finish',id:id,mechanism:'WKWebView.fetch',method:method,url:res.url||url,statusCode:res.status,mimeType:ct,durationMs:dur,requestHeaders:reqH,responseHeaders:respH,requestBody:reqB,responseBody:(txt||'').slice(0,131072),responseBytes:cl||(txt?txt.length:0),error:''});}).catch(function(){post({kind:'network',phase:'finish',id:id,mechanism:'WKWebView.fetch',method:method,url:res.url||url,statusCode:res.status,mimeType:ct,durationMs:dur,requestHeaders:reqH,responseHeaders:respH,requestBody:reqB,responseBody:'',responseBytes:cl,error:''});});}catch(e){post({kind:'network',phase:'finish',id:id,mechanism:'WKWebView.fetch',method:method,url:res.url||url,statusCode:res.status,mimeType:ct,durationMs:dur,requestHeaders:reqH,responseHeaders:respH,requestBody:reqB,responseBody:'',responseBytes:cl,error:''});}}else{post({kind:'network',phase:'finish',id:id,mechanism:'WKWebView.fetch',method:method,url:res.url||url,statusCode:res.status,mimeType:ct||'binary',durationMs:dur,requestHeaders:reqH,responseHeaders:respH,requestBody:reqB,responseBody:'<Binary or large response: '+ct+'>',responseBytes:cl,error:''});}return res;}).catch(function(err){post({kind:'network',phase:'error',id:id,mechanism:'WKWebView.fetch',method:method,url:url,statusCode:-1,mimeType:'',durationMs:Date.now()-t0,requestHeaders:reqH,responseHeaders:{},requestBody:reqB,responseBody:'',responseBytes:0,error:String(err)});throw err;});};}"
    "var origOpen=XMLHttpRequest.prototype.open;var origSetHdr=XMLHttpRequest.prototype.setRequestHeader;var origSend=XMLHttpRequest.prototype.send;"
    "XMLHttpRequest.prototype.open=function(m,u){this.__lcId=nextId();this.__lcM=(m||'GET').toUpperCase();this.__lcU=absUrl(u);this.__lcH={};return origOpen.apply(this,arguments);};"
    "XMLHttpRequest.prototype.setRequestHeader=function(k,v){try{if(!this.__lcH)this.__lcH={};this.__lcH[k]=v;}catch(e){}return origSetHdr.apply(this,arguments);};"
    "XMLHttpRequest.prototype.send=function(b){var xhr=this;var t0=Date.now();var reqB=bodyStr(b);var id=xhr.__lcId||nextId();var method=xhr.__lcM||'GET';var url=xhr.__lcU||'';var reqH=xhr.__lcH||{};post({kind:'network',phase:'start',id:id,mechanism:'WKWebView.xhr',method:method,url:url,requestHeaders:reqH,requestBody:reqB});xhr.addEventListener('loadend',function(){var rh={};try{var rawRh=xhr.getAllResponseHeaders()||'';rawRh.trim().split(/[\\r\\n]+/).forEach(function(line){var idx=line.indexOf(':');if(idx>0){rh[line.slice(0,idx).trim()]=line.slice(idx+1).trim();}});}catch(e){}var ct=rh['content-type']||rh['Content-Type']||'';var txt='';try{if(!xhr.responseType||xhr.responseType==='text'||xhr.responseType==='json'){txt=(typeof xhr.responseText==='string'?xhr.responseText:JSON.stringify(xhr.response||'')).slice(0,131072);}}catch(e){}var errMsg=(xhr.status===0)?'XHR failed or aborted':'';post({kind:'network',phase:errMsg?'error':'finish',id:id,mechanism:'WKWebView.xhr',method:method,url:xhr.responseURL||url,statusCode:xhr.status||-1,mimeType:ct,durationMs:Date.now()-t0,requestHeaders:reqH,responseHeaders:rh,requestBody:reqB,responseBody:txt,responseBytes:txt?txt.length:0,error:errMsg});});return origSend.apply(this,arguments);};"
    "if(navigator.sendBeacon){var origBeacon=navigator.sendBeacon.bind(navigator);navigator.sendBeacon=function(u,d){var ok=false;try{ok=origBeacon(u,d);}finally{post({kind:'network',phase:ok?'finish':'error',id:nextId(),mechanism:'WKWebView.beacon',method:'POST',url:absUrl(u),statusCode:ok?200:-1,mimeType:'',durationMs:0,requestHeaders:{},responseHeaders:{},requestBody:bodyStr(d),responseBody:'',responseBytes:0,error:ok?'':'sendBeacon rejected'});}return ok;};}"
    "})();";
}

static void LCNetInstallWKUserScripts(WKWebViewConfiguration * _Nullable cfg) {
    WKUserContentController *ucc = cfg.userContentController;
    if (!ucc || objc_getAssociatedObject(ucc, &kLCNetWKInstalledKey)) {
        return;
    }
    objc_setAssociatedObject(ucc, &kLCNetWKInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static LCDebugNetWKScriptHandler *sharedHandler = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sharedHandler = [[LCDebugNetWKScriptHandler alloc] init];
    });
    [ucc removeScriptMessageHandlerForName:kLCNetWKHandlerName];
    [ucc addScriptMessageHandler:sharedHandler name:kLCNetWKHandlerName];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:LCNetWebViewHookScript()
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO];
    [ucc addUserScript:script];
}

@implementation WKWebView (LCDebugNetworkEngineSwizzle)

- (instancetype)lcNet_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    WKWebViewConfiguration *cfg = configuration ?: [[WKWebViewConfiguration alloc] init];
    LCNetInstallWKUserScripts(cfg);
    return [self lcNet_initWithFrame:frame configuration:cfg];
}

- (instancetype)lcNet_initWithCoder:(NSCoder *)coder {
    WKWebView *wv = [self lcNet_initWithCoder:coder];
    if (wv) {
        LCNetInstallWKUserScripts(wv.configuration);
    }
    return wv;
}

@end

void LCDebugInstallWebViewHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCDebugSafeSwizzleInstanceMethod(WKWebView.class,
                                         @selector(initWithFrame:configuration:),
                                         @selector(lcNet_initWithFrame:configuration:));
        LCDebugSafeSwizzleInstanceMethod(WKWebView.class,
                                         @selector(initWithCoder:),
                                         @selector(lcNet_initWithCoder:));
    });
}

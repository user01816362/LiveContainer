//
//  LCDebugNetworkTypes.m
//  TweakLoader
//
//  Implementation of runtime safety checks, swizzling helpers, streaming
//  decompression, cURL formatting, and transaction data models.
//

@import Foundation;
@import Compression;

#import "LCDebugNetworkTypes.h"
#include <string.h>

static _Atomic uint16_t gLCNetExcludedLocalPort = 0;
static _Atomic uint16_t gLCNetExcludedLANPort = 0;
static _Atomic BOOL gLCNetRecordingPaused = NO;

static os_unfair_lock gLCHookedSelectorLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gLCHookedSelectors = nil;

BOOL LCDebugNetworkIsPausedAtomic(void) {
    return atomic_load(&gLCNetRecordingPaused);
}

void LCDebugNetworkSetPausedAtomic(BOOL paused) {
    atomic_store(&gLCNetRecordingPaused, paused);
}

BOOL LCDebugIsSafeObjCClass(Class _Nullable cls) {
    if (!cls || class_isMetaClass(cls)) {
        return NO;
    }
    const char *name = class_getName(cls);
    if (!name || name[0] == '\0') {
        return NO;
    }
    if (objc_lookUpClass(name) != cls) {
        return NO;
    }
    if (!class_getSuperclass(cls) && cls != NSObject.class && cls != NSProxy.class) {
        return NO;
    }
    if (strncmp(name, "__ARCLite__", 11) == 0 ||
        strncmp(name, "_NSZombie_", 10) == 0 ||
        strncmp(name, "_CNZombie_", 10) == 0 ||
        strncmp(name, "NSPlaceholder", 13) == 0 ||
        strncmp(name, "__NSPlaceholder", 15) == 0 ||
        strncmp(name, "__NSGenericDeallocHandler", 25) == 0 ||
        strncmp(name, "JSExport", 8) == 0 ||
        strncmp(name, "NSAutoreleasePool", 17) == 0 ||
        strncmp(name, "VMUArchitecture", 15) == 0 ||
        strncmp(name, "__NSMessageBuilder", 18) == 0 ||
        strncmp(name, "LCDebug", 7) == 0) {
        return NO;
    }
    return YES;
}

BOOL LCDebugSafeSwizzleInstanceMethod(Class _Nullable cls, SEL originalSel, SEL swizzledSel) {
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

BOOL LCDebugSafeSwizzleClassMethod(Class _Nullable cls, SEL originalSel, SEL swizzledSel) {
    if (!cls || !originalSel || !swizzledSel) return NO;
    Class metaCls = object_getClass(cls);
    if (!metaCls || metaCls == cls) return NO;
    return LCDebugSafeSwizzleInstanceMethod(metaCls, originalSel, swizzledSel);
}

static BOOL LCDebugClassDirectlyDefinesSelector(Class _Nullable cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

Class _Nullable LCDebugOwningClassForSelector(Class _Nullable cls, SEL sel) {
    Class cursor = cls;
    while (cursor) {
        if (LCDebugClassDirectlyDefinesSelector(cursor, sel)) {
            return cursor;
        }
        cursor = class_getSuperclass(cursor);
    }
    return Nil;
}

BOOL LCDebugMarkSelectorHooked(Class ownerCls, SEL sel) {
    if (!ownerCls || !sel) return NO;
    NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(ownerCls), sel_getName(sel)];
    os_unfair_lock_lock(&gLCHookedSelectorLock);
    if (!gLCHookedSelectors) {
        gLCHookedSelectors = [NSMutableSet set];
    }
    BOOL already = [gLCHookedSelectors containsObject:key];
    if (!already) {
        [gLCHookedSelectors addObject:key];
    }
    os_unfair_lock_unlock(&gLCHookedSelectorLock);
    return !already;
}

BOOL LCDebugClassOverridesForwarding(Class cls) {
    SEL fwdTargetSel = @selector(forwardingTargetForSelector:);
    SEL fwdInvocSel = @selector(forwardInvocation:);
    Class cursor = cls;
    while (cursor && cursor != NSObject.class && cursor != NSProxy.class) {
        if (LCDebugClassDirectlyDefinesSelector(cursor, fwdTargetSel) ||
            LCDebugClassDirectlyDefinesSelector(cursor, fwdInvocSel)) {
            return YES;
        }
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

BOOL LCDebugIsAVAggregateAssetTask(id _Nullable task) {
    if (!task) return NO;
    Class avCls = NSClassFromString(@"AVAggregateAssetDownloadTask");
    return (avCls != Nil && [task isKindOfClass:avCls]);
}

NSString *LCEscapeSingleQuotes(NSString * _Nullable raw) {
    return [(raw ?: @"") stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

void LCDebugNetworkSetExcludedLocalPorts(uint16_t localPort, uint16_t lanPort) {
    atomic_store(&gLCNetExcludedLocalPort, localPort);
    atomic_store(&gLCNetExcludedLANPort, lanPort);
}

BOOL LCDebugIsOwnDebugRequestURL(NSURL * _Nullable url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"] || [host isEqualToString:@"::1"]) {
        NSNumber *port = url.port;
        if (port) {
            uint16_t reqPort = port.unsignedShortValue;
            uint16_t localPort = atomic_load(&gLCNetExcludedLocalPort);
            uint16_t lanPort = atomic_load(&gLCNetExcludedLANPort);
            if ((localPort > 0 && reqPort == localPort) || (lanPort > 0 && reqPort == lanPort)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL LCNetIsSensitiveHeader(NSString *headerName) {
    NSString *lower = headerName.lowercaseString;
    return [lower isEqualToString:@"authorization"] ||
           [lower isEqualToString:@"proxy-authorization"] ||
           [lower isEqualToString:@"cookie"] ||
           [lower isEqualToString:@"set-cookie"] ||
           [lower isEqualToString:@"x-api-key"] ||
           [lower isEqualToString:@"x-auth-token"] ||
           [lower isEqualToString:@"x-csrf-token"] ||
           [lower isEqualToString:@"x-access-token"] ||
           [lower containsString:@"secret"] ||
           [lower containsString:@"token"];
}

NSDictionary<NSString *, NSString *> *LCDebugSanitizeHeaders(NSDictionary * _Nullable headers, BOOL redactSensitive) {
    if (![headers isKindOfClass:NSDictionary.class] || headers.count == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionaryWithCapacity:headers.count];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
        NSString *k = [key isKindOfClass:NSString.class] ? key : [key description];
        NSString *v = [val isKindOfClass:NSString.class] ? val : [val description];
        if (!k || !v) return;
        out[k] = (redactSensitive && LCNetIsSensitiveHeader(k)) ? @"<redacted>" : v;
    }];
    return out;
}

NSString * _Nullable LCDebugHeaderValueCaseInsensitive(NSDictionary * _Nullable headers, NSString *name) {
    if (![headers isKindOfClass:NSDictionary.class] || name.length == 0) return nil;
    id direct = headers[name];
    if ([direct isKindOfClass:NSString.class]) return direct;
    NSString *lower = name.lowercaseString;
    for (id key in headers) {
        if ([key isKindOfClass:NSString.class] && [((NSString *)key).lowercaseString isEqualToString:lower]) {
            id val = headers[key];
            return [val isKindOfClass:NSString.class] ? val : [val description];
        }
    }
    return nil;
}

// MARK: - Safe Streaming Decompression

static BOOL LCNetStripGzipHeaderAndTrailer(const uint8_t *bytes, NSUInteger length, NSUInteger *outOffset, NSUInteger *outLen) {
    if (!bytes || length < 10 || bytes[0] != 0x1F || bytes[1] != 0x8B || bytes[2] != 8) {
        return NO;
    }
    uint8_t flags = bytes[3];
    NSUInteger pos = 10;

    if (flags & 0x04) {
        if (pos + 2 > length) return NO;
        uint16_t xlen = (uint16_t)bytes[pos] | ((uint16_t)bytes[pos + 1] << 8);
        pos += 2;
        if (xlen > length - pos) return NO;
        pos += xlen;
    }
    if (flags & 0x08) {
        while (pos < length && bytes[pos] != 0) pos++;
        if (pos >= length) return NO;
        pos++;
    }
    if (flags & 0x10) {
        while (pos < length && bytes[pos] != 0) pos++;
        if (pos >= length) return NO;
        pos++;
    }
    if (flags & 0x02) {
        if (pos + 2 > length) return NO;
        pos += 2;
    }
    NSUInteger payloadEnd = length;
    if (payloadEnd >= pos + 8) {
        payloadEnd -= 8;
    }
    if (payloadEnd <= pos) return NO;
    *outOffset = pos;
    *outLen = payloadEnd - pos;
    return YES;
}

static BOOL LCNetStripZlibHeaderAndTrailer(const uint8_t *bytes, NSUInteger length, NSUInteger *outOffset, NSUInteger *outLen) {
    if (!bytes || length < 6) return NO;
    uint8_t cmf = bytes[0];
    uint8_t flg = bytes[1];
    if ((cmf & 0x0F) != 8) return NO;
    if ((((uint16_t)cmf << 8) | flg) % 31 != 0) return NO;
    NSUInteger pos = 2;
    if (flg & 0x20) {
        if (pos + 4 > length) return NO;
        pos += 4;
    }
    NSUInteger end = length;
    if (end >= pos + 4) {
        end -= 4;
    }
    if (end <= pos) return NO;
    *outOffset = pos;
    *outLen = end - pos;
    return YES;
}

static NSData * _Nullable LCNetDecodeWithCompressionStream(const uint8_t *src,
                                                          size_t srcLen,
                                                          compression_algorithm algo,
                                                          NSUInteger maxOutputBytes) {
    if (!src || srcLen == 0 || maxOutputBytes == 0) return nil;
    compression_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algo) != COMPRESSION_STATUS_OK) {
        return nil;
    }

    stream.src_ptr = src;
    stream.src_size = srcLen;

    uint8_t scratch[16384];
    NSMutableData *out = [NSMutableData dataWithCapacity:MIN(maxOutputBytes, MAX((NSUInteger)4096, (NSUInteger)srcLen * 3))];
    BOOL ok = NO;

    for (;;) {
        stream.dst_ptr = scratch;
        stream.dst_size = sizeof(scratch);
        compression_status st = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        size_t produced = sizeof(scratch) - stream.dst_size;
        if (produced > 0) {
            NSUInteger room = (out.length < maxOutputBytes) ? (maxOutputBytes - out.length) : 0;
            if (room > 0) {
                [out appendBytes:scratch length:MIN(produced, room)];
            }
            if (out.length >= maxOutputBytes) {
                ok = YES;
                break;
            }
        }
        if (st == COMPRESSION_STATUS_END) {
            ok = YES;
            break;
        }
        if (st == COMPRESSION_STATUS_ERROR) {
            ok = NO;
            break;
        }
        if (produced == 0 && stream.src_size == 0) {
            ok = (out.length > 0);
            break;
        }
    }

    compression_stream_destroy(&stream);
    return (ok && out.length > 0) ? [out copy] : nil;
}

NSData * _Nullable LCDebugInflateData(NSData * _Nullable data,
                                      NSString * _Nullable contentEncoding,
                                      NSUInteger maxOutputBytes) {
    if (data.length == 0 || maxOutputBytes == 0) return data;
    NSString *enc = contentEncoding.lowercaseString ?: @"";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;

    BOOL looksGzip = (len >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) || [enc containsString:@"gzip"];
    BOOL looksDeflate = [enc containsString:@"deflate"];
    BOOL looksBrotli = [enc containsString:@"br"];

    if (!looksGzip && !looksDeflate && !looksBrotli) {
        return data;
    }

    if (looksGzip) {
        NSUInteger off = 0, subLen = 0;
        if (LCNetStripGzipHeaderAndTrailer(bytes, len, &off, &subLen)) {
            NSData *inflated = LCNetDecodeWithCompressionStream(bytes + off, subLen, COMPRESSION_ZLIB, maxOutputBytes);
            if (inflated) return inflated;
        }
    }

    if (looksDeflate) {
        NSUInteger off = 0, subLen = 0;
        if (LCNetStripZlibHeaderAndTrailer(bytes, len, &off, &subLen)) {
            NSData *inflated = LCNetDecodeWithCompressionStream(bytes + off, subLen, COMPRESSION_ZLIB, maxOutputBytes);
            if (inflated) return inflated;
        }
        NSData *rawDeflate = LCNetDecodeWithCompressionStream(bytes, len, COMPRESSION_ZLIB, maxOutputBytes);
        if (rawDeflate) return rawDeflate;
    }

    if (looksBrotli) {
        NSData *br = LCNetDecodeWithCompressionStream(bytes, len, COMPRESSION_BROTLI, maxOutputBytes);
        if (br) return br;
    }

    return data;
}

NSData * _Nullable LCDebugReadCopyableBodyStream(NSInputStream * _Nullable stream, NSUInteger maxBytes) {
    if (!stream || maxBytes == 0) return nil;
    if (![stream conformsToProtocol:@protocol(NSCopying)]) {
        return nil;
    }
    NSInputStream *copiedStream = nil;
    @try {
        copiedStream = [(id<NSCopying>)stream copyWithZone:nil];
    } @catch (__unused NSException *ex) {
        return nil;
    }
    if (![copiedStream isKindOfClass:NSInputStream.class] ||
        copiedStream == stream ||
        copiedStream.streamStatus != NSStreamStatusNotOpen) {
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    [copiedStream open];
    @try {
        while (data.length < maxBytes) {
            NSUInteger toRead = MIN((NSUInteger)sizeof(buffer), maxBytes - data.length);
            NSInteger readBytes = [copiedStream read:buffer maxLength:toRead];
            if (readBytes <= 0) {
                break;
            }
            [data appendBytes:buffer length:(NSUInteger)readBytes];
        }
    } @finally {
        [copiedStream close];
    }
    return data.length > 0 ? [data copy] : nil;
}

// MARK: - Previews, GraphQL & cURL

BOOL LCDebugIsTextLikeMime(NSString * _Nullable mimeType, NSData * _Nullable data) {
    NSString *lower = mimeType.lowercaseString ?: @"";
    if ([lower containsString:@"json"] ||
        [lower containsString:@"xml"] ||
        [lower containsString:@"text/"] ||
        [lower containsString:@"javascript"] ||
        [lower containsString:@"ecmascript"] ||
        [lower containsString:@"x-www-form-urlencoded"] ||
        [lower containsString:@"graphql"] ||
        [lower containsString:@"svg"]) {
        return YES;
    }
    if ([lower hasPrefix:@"image/"] || [lower hasPrefix:@"audio/"] || [lower hasPrefix:@"video/"]) {
        return NO;
    }
    if (data.length == 0) return YES;
    NSUInteger sampleLen = MIN(data.length, (NSUInteger)512);
    NSData *sample = [data subdataWithRange:NSMakeRange(0, sampleLen)];
    NSString *utf8 = [[NSString alloc] initWithData:sample encoding:NSUTF8StringEncoding];
    if (!utf8 && sampleLen < data.length && sampleLen >= 4) {
        sample = [data subdataWithRange:NSMakeRange(0, sampleLen - 3)];
        utf8 = [[NSString alloc] initWithData:sample encoding:NSUTF8StringEncoding];
    }
    if (!utf8) return NO;
    const uint8_t *bytes = (const uint8_t *)sample.bytes;
    for (NSUInteger i = 0; i < sample.length; i++) {
        if (bytes[i] == 0) return NO;
    }
    return YES;
}

BOOL LCDebugIsMediaMime(NSString * _Nullable mimeType) {
    NSString *lower = mimeType.lowercaseString ?: @"";
    return [lower hasPrefix:@"image/"] || [lower hasPrefix:@"audio/"] || [lower hasPrefix:@"video/"];
}

NSString *LCDebugPreviewString(NSData * _Nullable data, NSString * _Nullable mimeType, NSUInteger maxBytes) {
    if (!data || data.length == 0) return @"";
    if ([mimeType.lowercaseString hasPrefix:@"image/"]) {
        return [NSString stringWithFormat:@"<Image %@ · %lu bytes>", mimeType ?: @"image", (unsigned long)data.length];
    }
    if ([mimeType.lowercaseString hasPrefix:@"audio/"] || [mimeType.lowercaseString hasPrefix:@"video/"]) {
        return [NSString stringWithFormat:@"<Media %@ · %lu bytes>", mimeType ?: @"media", (unsigned long)data.length];
    }
    NSUInteger sliceLen = MIN(data.length, maxBytes);
    NSData *slice = [data subdataWithRange:NSMakeRange(0, sliceLen)];
    NSString *utf8 = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!utf8 && sliceLen > 4 && data.length > sliceLen) {
        utf8 = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, sliceLen - 3)] encoding:NSUTF8StringEncoding];
    }
    if (!utf8 && LCDebugIsTextLikeMime(mimeType, slice)) {
        utf8 = [[NSString alloc] initWithData:slice encoding:NSISOLatin1StringEncoding];
    }
    if (utf8) {
        return data.length > sliceLen
            ? [utf8 stringByAppendingFormat:@"\n… (%lu bytes total)", (unsigned long)data.length]
            : utf8;
    }
    return [NSString stringWithFormat:@"<Binary %lu bytes>", (unsigned long)data.length];
}

NSString *LCDebugFormatHexPreview(NSData * _Nullable data, NSUInteger maxBytes) {
    if (!data || data.length == 0) return @"";
    NSUInteger cap = MIN(data.length, maxBytes);
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:cap * 4];
    for (NSUInteger offset = 0; offset < cap; offset += 16) {
        [out appendFormat:@"%06lx  ", (unsigned long)offset];
        for (NSUInteger i = 0; i < 16; i++) {
            if (offset + i < cap) {
                [out appendFormat:@"%02x ", bytes[offset + i]];
            } else {
                [out appendString:@"   "];
            }
            if (i == 7) [out appendString:@" "];
        }
        [out appendString:@" |"];
        for (NSUInteger i = 0; i < 16 && (offset + i < cap); i++) {
            uint8_t c = bytes[offset + i];
            [out appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
        }
        [out appendString:@"|\n"];
    }
    if (data.length > cap) {
        [out appendFormat:@"… (%lu bytes total)", (unsigned long)data.length];
    }
    return out;
}

void LCDebugDetectGraphQL(NSURL * _Nullable url,
                          NSData * _Nullable bodyData,
                          BOOL *outIsGraphQL,
                          NSString * _Nonnull __autoreleasing * _Nonnull outOperation) {
    *outIsGraphQL = NO;
    *outOperation = @"";
    if (!url && bodyData.length == 0) return;

    NSString *path = url.path.lowercaseString ?: @"";
    BOOL pathHint = [path containsString:@"graphql"];
    if (bodyData.length > 0 && bodyData.length <= 262144) {
        id json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = (NSDictionary *)json;
            BOOL hasQuery = [dict[@"query"] isKindOfClass:NSString.class];
            BOOL hasOpName = [dict[@"operationName"] isKindOfClass:NSString.class];
            NSDictionary *ext = [dict[@"extensions"] isKindOfClass:NSDictionary.class] ? dict[@"extensions"] : nil;
            BOOL hasPersisted = [ext[@"persistedQuery"] isKindOfClass:NSDictionary.class];
            if (hasQuery || hasPersisted || (pathHint && (hasOpName || dict[@"variables"]))) {
                *outIsGraphQL = YES;
                NSString *opName = hasOpName ? dict[@"operationName"] : @"";
                if (opName.length == 0 && hasQuery) {
                    NSString *q = dict[@"query"];
                    NSRange firstLine = [q rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet];
                    NSString *head = firstLine.location == NSNotFound ? q : [q substringToIndex:firstLine.location];
                    opName = [head stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (opName.length > 48) opName = [opName substringToIndex:48];
                }
                *outOperation = opName ?: @"GraphQL";
                return;
            }
        }
    }
    if (pathHint && url) {
        NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *qi in comp.queryItems) {
            if ([qi.name isEqualToString:@"operationName"] && qi.value.length > 0) {
                *outIsGraphQL = YES;
                *outOperation = qi.value;
                return;
            }
        }
    }
}

NSString *LCDebugBuildCurlCommand(NSURLRequest * _Nullable request,
                                  NSData * _Nullable overrideBody,
                                  NSString * _Nullable contentEncoding,
                                  BOOL redactSensitive) {
    if (!request) return @"";
    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod : @"GET";
    NSMutableString *curl = [NSMutableString stringWithFormat:@"curl -X %@ \\\n", method];

    if (request.HTTPShouldHandleCookies && !redactSensitive && request.URL) {
        NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:request.URL];
        if (cookies.count > 0 && !LCDebugHeaderValueCaseInsensitive(request.allHTTPHeaderFields, @"Cookie")) {
            NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:cookies.count];
            for (NSHTTPCookie *cookie in cookies) {
                [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
            }
            NSString *cookieHeader = [pairs componentsJoinedByString:@"; "];
            [curl appendFormat:@"  -H 'Cookie: %@' \\\n", LCEscapeSingleQuotes(cookieHeader)];
        }
    }

    NSDictionary<NSString *, NSString *> *headers = LCDebugSanitizeHeaders(request.allHTTPHeaderFields, redactSensitive);
    for (NSString *key in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        [curl appendFormat:@"  -H '%@: %@' \\\n", LCEscapeSingleQuotes(key), LCEscapeSingleQuotes(headers[key])];
    }

    NSData *body = overrideBody ?: request.HTTPBody;
    NSString *enc = contentEncoding ?: LCDebugHeaderValueCaseInsensitive(request.allHTTPHeaderFields, @"Content-Encoding");
    if (body.length > 0 && enc.length > 0) {
        body = LCDebugInflateData(body, enc, 512 * 1024) ?: body;
    }

    NSString *prefix = @"";
    if (body.length > 0) {
        if (body.length <= 65536) {
            NSString *utf8 = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (utf8 && [utf8 rangeOfString:@"\0"].location == NSNotFound) {
                [curl appendFormat:@"  --data-raw '%@' \\\n", LCEscapeSingleQuotes(utf8)];
            } else {
                NSString *b64 = [body base64EncodedStringWithOptions:0];
                prefix = [NSString stringWithFormat:@"echo -n '%@' | base64 -D | ", b64];
                [curl appendString:@"  --data-binary @- \\\n"];
            }
        } else {
            [curl appendFormat:@"  # (body %lu bytes omitted)\n", (unsigned long)body.length];
        }
    }

    [curl appendFormat:@"  '%@'", LCEscapeSingleQuotes(request.URL.absoluteString ?: @"")];
    return prefix.length > 0 ? [prefix stringByAppendingString:curl] : [curl copy];
}

// MARK: - Models

@implementation LCDebugNetTaskContext {
    os_unfair_lock _lock;
    _Atomic BOOL _started;
    _Atomic BOOL _completed;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        atomic_init(&_started, NO);
        atomic_init(&_completed, NO);
        _txId = NSUUID.UUID.UUIDString;
        _source = @"urlsession";
        _mechanism = @"NSURLSessionTask";
        _startTime = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (void)lock {
    os_unfair_lock_lock(&_lock);
}

- (void)unlock {
    os_unfair_lock_unlock(&_lock);
}

- (void)markStarted {
    atomic_store(&_started, YES);
}

- (BOOL)tryMarkStartedOnce {
    return !atomic_exchange(&_started, YES);
}

- (BOOL)tryMarkCompletedOnce {
    return !atomic_exchange(&_completed, YES);
}

- (void)appendResponseChunk:(NSData *)chunk maxCaptureBytes:(NSUInteger)maxCaptureBytes {
    if (chunk.length == 0) return;
    os_unfair_lock_lock(&_lock);
    _totalReceivedBytes += chunk.length;
    if (!_truncatedForCache) {
        if (!_receivedData) {
            _receivedData = [NSMutableData dataWithCapacity:MIN(chunk.length, (NSUInteger)16384)];
        }
        if (_receivedData.length + chunk.length <= maxCaptureBytes) {
            [_receivedData appendData:chunk];
        } else {
            NSUInteger room = maxCaptureBytes > _receivedData.length ? (maxCaptureBytes - _receivedData.length) : 0;
            if (room > 0) {
                [_receivedData appendBytes:chunk.bytes length:room];
            }
            _truncatedForCache = YES;
        }
    }
    os_unfair_lock_unlock(&_lock);
}

@end

@implementation LCDebugNetworkTransaction

- (NSDictionary<NSString *, id> *)toCompactDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": self.txId ?: @"",
        @"redirectFromId": self.redirectFromId ?: @"",
        @"timestamp": @(self.timestamp),
        @"state": self.state ?: @"finished",
        @"source": self.source ?: @"urlsession",
        @"mechanism": self.mechanism ?: @"",
        @"method": self.method ?: @"GET",
        @"url": self.urlString ?: @"",
        @"host": self.host ?: @"",
        @"path": self.path ?: @"",
        @"statusCode": @(self.statusCode),
        @"mimeType": self.mimeType ?: @"",
        @"latencyMs": @(self.latencyMs),
        @"durationMs": @(self.durationMs),
        @"requestBytes": @(self.requestBytes),
        @"responseBytes": @(self.responseBytes),
        @"bytes": @(MAX(self.responseBytes, self.requestBytes)),
        @"requestHeaders": self.requestHeaders ?: @{},
        @"responseHeaders": self.responseHeaders ?: @{},
        @"requestBodyPreview": self.requestBodyPreview ?: @"",
        @"responseBodyPreview": self.responseBodyPreview ?: @"",
        @"hasRequestBody": @(self.hasRequestBody),
        @"hasResponseBody": @(self.hasResponseBody),
        @"isGraphQL": @(self.isGraphQL),
        @"graphQLOperation": self.graphQLOperation ?: @"",
        @"curl": self.curl ?: @"",
        @"error": self.errorText ?: @""
    }];
    if (self.metrics) {
        d[@"metrics"] = self.metrics;
    }
    return d;
}

@end

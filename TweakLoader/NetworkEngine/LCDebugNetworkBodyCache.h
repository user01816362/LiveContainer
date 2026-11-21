//
//  LCDebugNetworkBodyCache.h
//  TweakLoader
//
//  O(1) bounded LRU request/response payload cache protected by os_unfair_lock
//  with automatic memory-warning eviction.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCDebugBodyCacheNode : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy, nullable) NSString *contentEncoding;
@property (nonatomic, assign) NSUInteger cost;
@property (nonatomic, weak, nullable) LCDebugBodyCacheNode *prev;
@property (nonatomic, weak, nullable) LCDebugBodyCacheNode *next;
@end

@interface LCDebugNetworkBodyCache : NSObject
@property (nonatomic, assign) NSUInteger totalCostLimit;
@property (nonatomic, assign) NSUInteger maxSingleEntryBytes;

- (void)setData:(NSData *)data
       mimeType:(nullable NSString *)mimeType
contentEncoding:(nullable NSString *)encoding
         forKey:(NSString *)key;

- (nullable LCDebugBodyCacheNode *)nodeForKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (void)removeAllObjects;
@end

NS_ASSUME_NONNULL_END

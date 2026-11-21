//
//  LCDebugNetworkBodyCache.m
//  TweakLoader
//
//  O(1) doubly-linked-list + dictionary LRU payload cache.
//  All nodes are strongly owned by `_map` and linked via weak `prev`/`next`
//  pointers so removal and bulk clear never cause deep recursive dealloc chains.
//

@import Foundation;
@import UIKit;

#import "LCDebugNetworkBodyCache.h"
#include <os/lock.h>

@implementation LCDebugBodyCacheNode
@end

@implementation LCDebugNetworkBodyCache {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, LCDebugBodyCacheNode *> *_map;
    __weak LCDebugBodyCacheNode *_head;
    __weak LCDebugBodyCacheNode *_tail;
    NSUInteger _currentCost;
    id _memWarnObserver;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _map = [NSMutableDictionary dictionary];
        _totalCostLimit = 16 * 1024 * 1024;
        _maxSingleEntryBytes = 2 * 1024 * 1024;
        __weak typeof(self) weakSelf = self;
        _memWarnObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                                           object:nil
                                                                            queue:nil
                                                                       usingBlock:^(__unused NSNotification *note) {
            [weakSelf removeAllObjects];
        }];
    }
    return self;
}

- (void)dealloc {
    if (_memWarnObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_memWarnObserver];
    }
}

- (void)setTotalCostLimit:(NSUInteger)totalCostLimit {
    os_unfair_lock_lock(&_lock);
    _totalCostLimit = totalCostLimit;
    [self evictToLimitLocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)unlinkNodeLocked:(LCDebugBodyCacheNode *)node {
    LCDebugBodyCacheNode *prev = node.prev;
    LCDebugBodyCacheNode *next = node.next;
    if (prev) {
        prev.next = next;
    } else {
        _head = next;
    }
    if (next) {
        next.prev = prev;
    } else {
        _tail = prev;
    }
    node.prev = nil;
    node.next = nil;
}

- (void)insertAtHeadLocked:(LCDebugBodyCacheNode *)node {
    node.prev = nil;
    LCDebugBodyCacheNode *oldHead = _head;
    node.next = oldHead;
    if (oldHead) {
        oldHead.prev = node;
    }
    _head = node;
    if (!_tail) {
        _tail = node;
    }
}

- (void)evictToLimitLocked {
    while (_currentCost > _totalCostLimit && _tail) {
        LCDebugBodyCacheNode *victim = _tail;
        [self unlinkNodeLocked:victim];
        [_map removeObjectForKey:victim.key];
        _currentCost = (_currentCost >= victim.cost) ? (_currentCost - victim.cost) : 0;
    }
}

- (void)setData:(NSData *)data
       mimeType:(nullable NSString *)mimeType
contentEncoding:(nullable NSString *)encoding
         forKey:(NSString *)key {
    if (key.length == 0 || data.length == 0) {
        return;
    }
    NSData *copy = [data copy];
    os_unfair_lock_lock(&_lock);
    if (copy.length > _maxSingleEntryBytes || _totalCostLimit == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    LCDebugBodyCacheNode *existing = _map[key];
    if (existing) {
        _currentCost = (_currentCost >= existing.cost) ? (_currentCost - existing.cost) : 0;
        [self unlinkNodeLocked:existing];
    }
    LCDebugBodyCacheNode *node = [[LCDebugBodyCacheNode alloc] init];
    node.key = [key copy];
    node.data = copy;
    node.mimeType = [mimeType copy];
    node.contentEncoding = [encoding copy];
    node.cost = copy.length;
    _map[node.key] = node;
    _currentCost += copy.length;
    [self insertAtHeadLocked:node];
    [self evictToLimitLocked];
    os_unfair_lock_unlock(&_lock);
}

- (nullable LCDebugBodyCacheNode *)nodeForKey:(NSString *)key {
    if (key.length == 0) return nil;
    os_unfair_lock_lock(&_lock);
    LCDebugBodyCacheNode *node = _map[key];
    if (node) {
        [self unlinkNodeLocked:node];
        [self insertAtHeadLocked:node];
    }
    os_unfair_lock_unlock(&_lock);
    return node;
}

- (void)removeObjectForKey:(NSString *)key {
    if (key.length == 0) return;
    os_unfair_lock_lock(&_lock);
    LCDebugBodyCacheNode *node = _map[key];
    if (node) {
        [self unlinkNodeLocked:node];
        [_map removeObjectForKey:key];
        _currentCost = (_currentCost >= node.cost) ? (_currentCost - node.cost) : 0;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)removeAllObjects {
    os_unfair_lock_lock(&_lock);
    [_map removeAllObjects];
    _head = nil;
    _tail = nil;
    _currentCost = 0;
    os_unfair_lock_unlock(&_lock);
}

@end

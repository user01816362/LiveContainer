//
//  XPCServer.h
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

__attribute__((swift_attr("@Sendable")))
@protocol RefreshServer
- (void)updateProgress:(double)value;
- (void)finish:(nullable NSString*)error;
- (void)onConnection:(nonnull NSXPCConnection*)connection;
- (void)finishedLaunching;
- (void)addNotificationRequest:(nonnull UNNotificationRequest*)request;
- (void)removePendingNotificationRequestsWithIdentifiers:(nonnull NSArray<NSString*>*)identifiers;
@end

__attribute__((swift_attr("@Sendable")))
@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(nonnull NSString*)identifier mangledTypeName:(nonnull NSString *)mangledTypeName;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property (class, readonly, strong, nonnull) LiveProcessSideStoreHandler* shared;
@property (nullable) NSXPCConnection* connection;
@property (nullable) NSObject<RefreshServer>* server;

@end

NSXPCListener * _Nullable startAnonymousListener(NSObject<RefreshServer> * _Nonnull reporter);
NSData * _Nullable bookmarkForURL(NSURL * _Nonnull url);

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

__attribute__((swift_attr("@Sendable")))
@interface SideStoreClient : NSObject<RefreshClient>
@property (class, readonly, nonnull) SideStoreClient* shared;
- (void) relaunchLC;
@end

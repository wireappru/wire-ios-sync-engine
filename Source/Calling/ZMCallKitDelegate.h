//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

#import <Foundation/Foundation.h>
@import CallKit;

NS_ASSUME_NONNULL_BEGIN

@class INPerson;
@class ZMUserSession;
@class ZMConversation;
@class ZMFlowSync;
@class ZMOnDemandFlowManager;
@class AVSMediaManager;

/// Needed to unbound @c ZMCallKitDelegate from OS CallKit implementation (for testing).
@protocol CallKitProviderType <NSObject>
- (instancetype)initWithConfiguration:(CXProviderConfiguration *)configuration;
- (void)setDelegate:(nullable id<CXProviderDelegate>)delegate queue:(nullable dispatch_queue_t)queue;
- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID
                               update:(CXCallUpdate *)update
                           completion:(void (^)(NSError *_Nullable error))completion;
- (void)reportCallWithUUID:(NSUUID *)UUID endedAtDate:(nullable NSDate *)dateEnded reason:(CXCallEndedReason)endedReason;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID startedConnectingAtDate:(nullable NSDate *)dateStartedConnecting;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID connectedAtDate:(nullable NSDate *)dateConnected;
@end

@interface CXProvider (TypeConformance) <CallKitProviderType>
@end

/// Needed to unbound @c ZMCallKitDelegate from OS CallKit implementation (for testing).
@protocol CallKitCallController <NSObject>
- (void)requestTransaction:(CXTransaction *)transaction completion:(void (^)(NSError *_Nullable error))completion;
@end

@interface CXCallController (TypeConformance) <CallKitCallController>
@end

@interface ZMUser (Handle)
/// Generates the handle for CallKit, either a phone number or an email one.
- (CXHandle *)callKitHandle;
@end

@interface ZMConversation (Handle)
/// Generates the handle for CallKit, either a phone number or an email one for one to one conversations and generic one
/// for the group chats.
- (CXHandle *)callKitHandle;

/// Finds the appropriate conversation described by the list of @c INPerson objects.
+ (nullable instancetype)resolveConversationForPersons:(NSArray<INPerson *> *)persons
                                             inContext:(NSManagedObjectContext *)context;
@end

@interface CXCallAction (Conversation)
/// Fetches the conversation associated by @c callUUID with the call action.
- (nullable ZMConversation *)conversationInContext:(NSManagedObjectContext *)context;
@end


/*
 * @c ZMCallKitDelegate is designed to provide the interaction with iOS integrated calling UI as a replacement of
 * the push notifications for calls, replacing it with native calling screen.
 */
@interface ZMCallKitDelegate : NSObject
- (instancetype)initWithCallKitProvider:(id<CallKitProviderType>)callKitProvider
                         callController:(id<CallKitCallController>)callController
                            userSession:(nullable ZMUserSession *)userSession
                           mediaManager:(nullable AVSMediaManager *)mediaManager;

/// Provides default configuration for CallKit provider.
+ (CXProviderConfiguration *)providerConfiguration;

/// Must be called in order to start the call. It checks with CallKit if the call can be started at the point of time
/// and if it is possible starts the call (calling `-[ZMVoiceChannel join]` or `-[ZMVoiceChannel joinVideoCall:]`).
- (void)requestStartCallInConversation:(ZMConversation *)conversation videoCall:(BOOL)video;
/// Must be called in order to end the call. It checks with CallKit if the call can be ended and end the call
/// (calling `-[ZMVoiceChannel leave]`).
- (void)requestEndCallInConversation:(ZMConversation *)conversation;

/// Must be called with the @c NSUserActivity that is provided to the application via @c UIApplicationDelegate protocol.
/// Needed to handle the action to select the call from user's "Phone" app.
- (BOOL)continueUserActivity:(NSUserActivity *)userActivity;
@end

@interface ZMCallKitDelegate (VoiceChannelObserver) <ZMVoiceChannelStateObserver>
@end

NS_ASSUME_NONNULL_END

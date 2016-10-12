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

@class ZMUserSession;
@class ZMConversation;
@class ZMFlowSync;
@class ZMOnDemandFlowManager;
@class AVSMediaManager;


@protocol CallKitProviderType <NSObject>
- (instancetype)initWithConfiguration:(CXProviderConfiguration *)configuration;
- (void)setDelegate:(nullable id<CXProviderDelegate>)delegate queue:(nullable dispatch_queue_t)queue;
- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID update:(CXCallUpdate *)update completion:(void (^)(NSError *_Nullable error))completion;
- (void)reportCallWithUUID:(NSUUID *)UUID endedAtDate:(nullable NSDate *)dateEnded reason:(CXCallEndedReason)endedReason;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID startedConnectingAtDate:(nullable NSDate *)dateStartedConnecting;
- (void)reportOutgoingCallWithUUID:(NSUUID *)UUID connectedAtDate:(nullable NSDate *)dateConnected;
@end

@interface CXProvider (TypeConformance) <CallKitProviderType>
@end

@protocol CallKitCallController <NSObject>
- (void)requestTransaction:(CXTransaction *)transaction completion:(void (^)(NSError *_Nullable error))completion;
@end

@interface CXCallController (TypeConformance) <CallKitCallController>
@end

@interface ZMCallKitDelegate : NSObject
- (instancetype)initWithCallKitProvider:(id<CallKitProviderType>)callKitProvider
                         callController:(id<CallKitCallController>)callController
                            userSession:(ZMUserSession *)userSession
                               flowSync:(ZMFlowSync *)flowSync
                    onDemandFlowManager:(ZMOnDemandFlowManager *)onDemandFlowManager
                           mediaManager:(AVSMediaManager *)mediaManager;

+ (CXProviderConfiguration *)providerConfiguration;

- (void)requestStartCallInConversation:(ZMConversation *)conversation videoCall:(BOOL)video;
- (void)requestEndCallInConversation:(ZMConversation *)conversation;
@end

NS_ASSUME_NONNULL_END

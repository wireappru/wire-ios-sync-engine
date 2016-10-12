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


#import "ZMCallKitDelegate.h"
#import "ZMUserSession.h"
#import "ZMVoiceChannel+CallFlow.h"
#import "ZMVoiceChannel+CallFlowPrivate.h"
#import "AVSFlowManager.h"
#import "AVSMediaManager.h"
#import "AVSMediaManager+Client.h"
#import <zmessaging/zmessaging-Swift.h>
@import ZMCDataModel;
@import CallKit;
@import UIKit;
@import ZMCSystem;

static char* const ZMLogTag ZM_UNUSED = "CallKit";

@implementation CXProvider (TypeConformance)
@end

@interface ZMVoiceChannel (ActiveStates)
+ (NSSet *)activeStates;
- (BOOL)inActiveState;
@end

@interface CXCallAction (Conversation)
- (ZMConversation *)conversationInContext:(NSManagedObjectContext *)context;
@end

@implementation CXCallAction (Conversation)

- (ZMConversation *)conversationInContext:(NSManagedObjectContext *)context
{
    ZMConversation *result = [ZMConversation conversationWithRemoteID:self.callUUID
                                                       createIfNeeded:NO
                                                            inContext:context];
    
    assert(result != nil);
    return result;
}

@end

@implementation ZMVoiceChannel (ActiveStates)

+ (NSSet *)activeStates {
    return [NSSet setWithObjects:@(ZMVoiceChannelStateOutgoingCall),
            @(ZMVoiceChannelStateOutgoingCallInactive),
            @(ZMVoiceChannelStateSelfIsJoiningActiveChannel),
            @(ZMVoiceChannelStateSelfConnectedToActiveChannel),  nil];
}

- (BOOL)inActiveState
{
    return [self.class.activeStates containsObject:@(self.state)];
}

@end


@interface ZMCallKitDelegate ()
@property (nonatomic) id<CallKitProviderType> provider;
@property (nonatomic) id<CallKitCallController> callController;
@property (nonatomic) ZMUserSession *userSession;
@property (nonatomic) ZMFlowSync *flowSync;
@property (nonatomic) ZMOnDemandFlowManager *onDemandFlowManager;
@property (nonatomic) AVSMediaManager *mediaManager;

@property (nonatomic) id <ZMVoiceChannelStateObserverOpaqueToken> voiceChannelStateObserverToken;
@end

@interface ZMCallKitDelegate (ProviderDelegate) <CXProviderDelegate>
@end

@interface ZMCallKitDelegate (VoiceChannelObserver) <ZMVoiceChannelStateObserver>
@end

@implementation ZMCallKitDelegate

- (void)dealloc
{
    [ZMVoiceChannel removeGlobalVoiceChannelStateObserverForToken:self.voiceChannelStateObserverToken inUserSession:self.userSession];
}

- (instancetype)initWithCallKitProvider:(id<CallKitProviderType>)callKitProvider
                         callController:(id<CallKitCallController>)callController
                            userSession:(ZMUserSession *)userSession
                               flowSync:(ZMFlowSync *)flowSync
                    onDemandFlowManager:(ZMOnDemandFlowManager *)onDemandFlowManager
                           mediaManager:(AVSMediaManager *)mediaManager

{
    self = [super init];
    if (nil != self) {
        NSCParameterAssert(callKitProvider);
        NSCParameterAssert(callController);
        NSCParameterAssert(userSession);
        NSCParameterAssert(flowSync);
        NSCParameterAssert(onDemandFlowManager);
        NSCParameterAssert(mediaManager);

        
        self.provider = callKitProvider;
        self.callController = callController;
        [self.provider setDelegate:self queue:nil];
        self.userSession = userSession;
        self.flowSync = flowSync;
        self.onDemandFlowManager = onDemandFlowManager;
        self.mediaManager = mediaManager;
        
        self.voiceChannelStateObserverToken = [ZMVoiceChannel addGlobalVoiceChannelStateObserver:self inUserSession:self.userSession];
    }
    return self;
}

+ (CXProviderConfiguration *)providerConfiguration
{
    NSString* localizedName = [NSBundle mainBundle].infoDictionary[@"CFBundleName"];
    if (localizedName == nil) {
        localizedName = @"Wire";
    }
    CXProviderConfiguration* providerConfiguration = [[CXProviderConfiguration alloc] initWithLocalizedName:localizedName];

    providerConfiguration.supportsVideo = YES;
    providerConfiguration.maximumCallsPerCallGroup = 1;
    providerConfiguration.supportedHandleTypes = [NSSet setWithObjects:@(CXHandleTypePhoneNumber), @(CXHandleTypeEmailAddress), nil];
    providerConfiguration.iconTemplateImageData = UIImagePNGRepresentation([UIImage imageNamed:@"AppIcon"]); // TODO add correct icon
    providerConfiguration.ringtoneSound = [ZMCustomSound notificationRingingSoundName];

    return providerConfiguration;
}

- (void)requestStartCallInConversation:(ZMConversation *)conversation videoCall:(BOOL)video
{
    CXHandle *selfUserHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric
                                                        value:[ZMUser selfUserInUserSession:self.userSession].remoteIdentifier.UUIDString];

    CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:conversation.remoteIdentifier handle:selfUserHandle];
    startCallAction.video = video;
    
    CXTransaction *startCallTransaction = [[CXTransaction alloc] initWithAction:startCallAction];
    
    [self.callController requestTransaction:startCallTransaction completion:^(NSError * _Nullable error) {
        if (nil != error) {
            ZMLogError(@"Cannot start call: %@", error);
        }
    }];
}

- (void)requestEndCallInConversation:(ZMConversation *)conversation
{
    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:conversation.remoteIdentifier];
    
    CXTransaction *endCallTransaction = [[CXTransaction alloc] initWithAction:endCallAction];
    
    [self.callController requestTransaction:endCallTransaction completion:^(NSError * _Nullable error) {
        if (nil != error) {
            ZMLogError(@"Cannot end call: %@", error);
        }
    }];
}

- (ZMConversation *)activeCallConversation
{
    ZMConversationList *nonIdleConversations = [ZMConversationList nonIdleVoiceChannelConversationsInUserSession:self.userSession];
    
    NSArray *activeCallConversations = [nonIdleConversations objectsAtIndexes:[nonIdleConversations indexesOfObjectsPassingTest:^BOOL(ZMConversation *conversation, NSUInteger __unused idx, BOOL __unused *stop) {
        return conversation.voiceChannel.inActiveState;
    }]];
    
    return activeCallConversations.firstObject;
}

- (void)indicateIncomingCallInConversation:(ZMConversation *)conversation
{
    // Construct a CXCallUpdate describing the incoming call, including the caller.
    CXCallUpdate* update = [[CXCallUpdate alloc] init];
    
    ZMUser *caller = [conversation.voiceChannel.participants firstObject];
    NSUUID *callerUUID = [caller remoteIdentifier];
    
    update.localizedCallerName = caller.displayName;
    update.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric
                                                   value:callerUUID.UUIDString];
    update.hasVideo = conversation.isVideoCall;
    [self.provider reportNewIncomingCallWithUUID:conversation.remoteIdentifier
                                          update:update
                                      completion:^(NSError * _Nullable error) {
                                          if (nil != error) {
                                              [conversation.voiceChannel leave];
                                              ZMLogError(@"Cannot report incoming call: %@", error);
                                          }
                                      }];
}

- (void)leaveAllActiveCalls
{
    [self.userSession enqueueChanges:^{
        for (ZMConversation *conversation in [ZMConversationList nonIdleVoiceChannelConversationsInUserSession:self.userSession]) {
            if (conversation.voiceChannel.state == ZMVoiceChannelStateIncomingCall) {
                [conversation.voiceChannel ignoreIncomingCall];
            }
            else if (conversation.voiceChannel.state == ZMVoiceChannelStateSelfConnectedToActiveChannel ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateSelfIsJoiningActiveChannel ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateDeviceTransferReady ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateOutgoingCall ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateOutgoingCallInactive) {
                [conversation.voiceChannel leave];
            }
        }
    }];
}

@end

@implementation ZMCallKitDelegate (VoiceChannelObserver)

- (void)voiceChannelStateDidChange:(VoiceChannelStateChangeInfo *)info
{
    ZMConversation *conversation = info.voiceChannel.conversation;
    
    switch (info.voiceChannel.state) {
    case ZMVoiceChannelStateIncomingCall:
            [self indicateIncomingCallInConversation:conversation];
        break;
    case ZMVoiceChannelStateSelfIsJoiningActiveChannel:
            if (conversation.isOutgoingCall) {
                [self.provider reportOutgoingCallWithUUID:conversation.remoteIdentifier startedConnectingAtDate:[NSDate date]];
            }
        break;
    case ZMVoiceChannelStateSelfConnectedToActiveChannel:
            if (conversation.isOutgoingCall) {
                [self.provider reportOutgoingCallWithUUID:conversation.remoteIdentifier connectedAtDate:[NSDate date]];
            }
        break;
    case ZMVoiceChannelStateNoActiveUsers:
        {
            if (!conversation.isOutgoingCall) {
                CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:conversation.remoteIdentifier];
                
                CXTransaction *endCallTransaction = [[CXTransaction alloc] initWithAction:endCallAction];
                
                [self.callController requestTransaction:endCallTransaction completion:^(NSError * _Nullable error) {
                    if (nil != error) {
                        ZMLogError(@"Cannot end call: %@", error);
                    }
                }];
            }
         }
        break;
    default:
        break;
    }
}

@end


@implementation ZMCallKitDelegate (ProviderDelegate)

- (void)providerDidBegin:(CXProvider *)provider
{
    ZMLogInfo(@"CXProvider %@ didBegin", provider);
}

- (void)providerDidReset:(CXProvider *)provider
{
    ZMLogInfo(@"CXProvider %@ didReset", provider);
    [self leaveAllActiveCalls];
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action
{
    ZMLogInfo(@"CXProvider %@ performStartCallAction", provider);
    ZMConversation *callConversation = [action conversationInContext:self.userSession.managedObjectContext];
    [self.userSession performChanges:^{
        if (action.video) {
            NSError *error = nil;
            [callConversation.voiceChannel joinVideoCall:&error];
            if (nil != error) {
                ZMLogError(@"Error joining video call: %@", error);
                [action fail];
            }
            else {
                [action fulfill];
            }
        }
        else {
            [callConversation.voiceChannel join];
            [action fulfill];
        }
    }];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action
{
    ZMLogInfo(@"CXProvider %@ performAnswerCallAction", provider);

    [self.userSession performChanges:^{
        ZMConversation *callConversation = [action conversationInContext:self.userSession.managedObjectContext];
        if (callConversation.isVideoCall) {
            [callConversation.voiceChannel joinVideoCall:nil];
        }
        else {
            [callConversation.voiceChannel join];
        }
        
        [action fulfill];
    }];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(nonnull CXEndCallAction *)action
{
    ZMLogInfo(@"CXProvider %@ performEndCallAction", provider);

    ZMConversation *callConversation = [action conversationInContext:self.userSession.managedObjectContext];
    [self.userSession performChanges:^{
        [callConversation.voiceChannel leave];
    }];
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(nonnull CXSetHeldCallAction *)action
{
    ZMLogInfo(@"CXProvider %@ performSetHeldCallAction", provider);

    // ZMConversation *callConversation = [action conversationInContext:self.userSession.managedObjectContext];

    // TODO
    
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action
{
    ZMLogInfo(@"CXProvider %@ performSetMutedCallAction", provider);

    self.mediaManager.microphoneMuted = action.muted;
    
    [action fulfill];
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action
{
    ZMLogInfo(@"CXProvider %@ timedOutPerformingAction %@", provider, action);

}

- (void)provider:(CXProvider __unused *)provider didActivateAudioSession:(AVAudioSession __unused *)audioSession
{
    ZMLogInfo(@"CXProvider %@ didActivateAudioSession", provider);
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession __unused *)audioSession
{
    ZMLogInfo(@"CXProvider %@ didDeactivateAudioSession", provider);
}

@end

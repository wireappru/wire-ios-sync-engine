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


@import WireDataModel;
#import "ZMHotFixDirectory.h"
#import "ZMUserSession.h"
#import <WireTransport/WireTransport.h>
#import <WireSyncEngine/WireSyncEngine-Swift.h>

static NSString* ZMLogTag ZM_UNUSED = @"HotFix";

@implementation ZMHotFixPatch

+ (instancetype)patchWithVersion:(NSString *)version patchCode:(ZMHotFixPatchCode)code
{
    ZMHotFixPatch *patch = [[ZMHotFixPatch alloc] init];
    patch->_code = ^(NSManagedObjectContext *context) {
        ZMLogDebug(@"Executing HotFix for version %@", version);
        code(context);
    };
    patch->_version = [version copy];
    return patch;
}

@end



@implementation ZMHotFixDirectory

- (NSArray *)patches
{
    static dispatch_once_t onceToken;
    static NSArray *patches;
    dispatch_once(&onceToken, ^{
        patches = @[
                    [ZMHotFixPatch
                     patchWithVersion:@"40.4"
                     patchCode:^(__unused NSManagedObjectContext *context){
                         [ZMHotFixDirectory resetPushTokens];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"40.23"
                     patchCode:^(__unused NSManagedObjectContext *context){
                         [ZMHotFixDirectory removeSharingExtension];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"41.43"
                     patchCode:^(NSManagedObjectContext *context){
                         [ZMHotFixDirectory moveOrUpdateSignalingKeysInContext:context];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"42.11"
                     patchCode:^(NSManagedObjectContext *context){
                         [ZMHotFixDirectory updateUploadedStateForNotUploadedFileMessages:context];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"45.0.1"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory insertNewConversationSystemMessage:context];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"45.1"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory updateSystemMessages:context];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"54.0.1"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory removeDeliveryReceiptsForDeletedMessages:context];
                     }],
                    [ZMHotFixPatch
                     patchWithVersion:@"61.0.0"
                     patchCode:^(__unused NSManagedObjectContext *context) {
                        [ZMHotFixDirectory purgePINCachesInHostBundle];
                    }],

                    /// Introduction of usernames: We need to refetch all connected users as they might already
                    /// have updated their username before we updated to a version supporting them.
                    [ZMHotFixPatch
                     patchWithVersion:@"62.3.1"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory refetchConnectedUsers:context];
                     }],

                    /// Introcution of Asset V3 Profile Pictures: We need to refetch all connected users as they might
                    /// already have uploaded profile pictures using the /assets/v3 endpoint which we do not yet have
                    /// locally and couldn't download before we updated to a version supporting them.
                    [ZMHotFixPatch
                     patchWithVersion:@"76.0.0"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory refetchConnectedUsers:context];
                     }],

                    /// We need to force a slow sync with the introduction of Teams, as users might have missed
                    /// update events when being added to teams or team conversations.
                    [ZMHotFixPatch
                     patchWithVersion:@"88.0.0"
                     patchCode:^(__unused NSManagedObjectContext *context) {
                         [ZMHotFixDirectory restartSlowSync:context];
                     }],

                    /// We need to refetch all team conversations to get data about access levels that were
                    /// introduced after implementing wireless users functionality.
                    [ZMHotFixPatch
                     patchWithVersion:@"146.0.0"
                     patchCode:^(__unused NSManagedObjectContext *context) {
                         [ZMHotFixDirectory refetchTeamGroupConversations:context];
                     }],
                    
                    /// We need to refetch all users after adding the persisted `teamIdentifier` property which is used
                    /// to decide if they belong to a team or not (relevant for updated asset retention policies).
                    [ZMHotFixPatch
                     patchWithVersion:@"157.0.0"
                     patchCode:^(NSManagedObjectContext *context) {
                         [ZMHotFixDirectory refetchUsers:context];
                     }],
                    ];
    });
    return patches;
}


+ (void)resetPushTokens
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ZMUserSessionResetPushTokensNotificationName object:nil];
}

+ (void)removeSharingExtension
{
    NSURL *directoryURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:[NSUserDefaults groupName]];
    if (directoryURL == nil) {
        ZMLogError(@"File url not valid");
        return;
    }
    
    NSURL *imageURL = [directoryURL URLByAppendingPathComponent:@"profile_images"];
    NSURL *conversationUrl = [directoryURL URLByAppendingPathComponent:@"conversations"];
    
    [[NSFileManager defaultManager] removeItemAtURL:imageURL error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:conversationUrl error:nil];
}

+ (void)removeDeliveryReceiptsForDeletedMessages:(NSManagedObjectContext *)context {
    NSFetchRequest *requestForInsertedMessages = [ZMClientMessage sortedFetchRequestWithPredicate:[ZMClientMessage predicateForObjectsThatNeedToBeInsertedUpstream]];
    NSArray *possibleMatches = [context executeFetchRequestOrAssert:requestForInsertedMessages];
    
    NSArray *confirmationReceiptsForDeletedMessages = [possibleMatches filterWithBlock:^BOOL(ZMClientMessage *candidateConfirmationReceipt) {
        if (candidateConfirmationReceipt.genericMessage.hasConfirmation &&
            candidateConfirmationReceipt.genericMessage.confirmation.firstMessageId) {
            ZMClientMessage *confirmationReceipt = candidateConfirmationReceipt;
            
            NSUUID *originalMessageUUID = [NSUUID uuidWithTransportString:confirmationReceipt.genericMessage.confirmation.firstMessageId];
            
            ZMMessage *originalConfirmedMessage = [ZMMessage fetchMessageWithNonce:originalMessageUUID
                                                                   forConversation:confirmationReceipt.conversation
                                                            inManagedObjectContext:context];
            
            if (nil != originalConfirmedMessage && (originalConfirmedMessage.hasBeenDeleted || originalConfirmedMessage.sender == nil)) {
                return YES;
            }
        }
        return NO;
    }];
    
    for (ZMClientMessage *message in confirmationReceiptsForDeletedMessages) {
        [context deleteObject:message];
    }
    
    [context saveOrRollback];
}

@end

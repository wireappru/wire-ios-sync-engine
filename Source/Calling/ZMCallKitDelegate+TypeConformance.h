//
//  ZMCallKitDelegate+TypeConformance.h
//  zmessaging-cocoa
//
//  Created by Mihail Gerasimenko on 11/2/16.
//  Copyright © 2016 Zeta Project Gmbh. All rights reserved.
//


@interface CXProvider (TypeConformance) <CallKitProviderType>
@end

@interface CXCallController (TypeConformance) <CallKitCallController>
@end

@interface CXCallAction (Conversation)
/// Fetches the conversation associated by @c callUUID with the call action.
- (nullable ZMConversation *)conversationInContext:(nonnull NSManagedObjectContext *)context;
@end

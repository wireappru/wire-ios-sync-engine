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

import Foundation
import WireDataModel
import CoreData

@objc(ZMCallStateObserver)
public final class CallStateObserver : NSObject {
    
    static public let CallInProgressNotification = Notification.Name(rawValue: "ZMCallInProgressNotification")
    static public let CallInProgressKey = "callInProgress"
    
    fileprivate weak var userSession: ZMUserSession?
    fileprivate let localNotificationDispatcher : LocalNotificationDispatcher
    fileprivate let syncManagedObjectContext : NSManagedObjectContext
    fileprivate var callStateToken : Any? = nil
    fileprivate var missedCalltoken : Any? = nil
    fileprivate let systemMessageGenerator = CallSystemMessageGenerator()
    
    public init(localNotificationDispatcher : LocalNotificationDispatcher, userSession: ZMUserSession) {
        self.userSession = userSession
        self.localNotificationDispatcher = localNotificationDispatcher
        self.syncManagedObjectContext = userSession.syncManagedObjectContext
        
        super.init()
        
        self.callStateToken = WireCallCenterV3.addCallStateObserver(observer: self, context: userSession.managedObjectContext)
        self.missedCalltoken = WireCallCenterV3.addMissedCallObserver(observer: self, context: userSession.managedObjectContext)
    }
    
    fileprivate var callInProgress : Bool = false {
        didSet {
            if callInProgress != oldValue {
                syncManagedObjectContext.performGroupedBlock {
                    NotificationInContext(name: CallStateObserver.CallInProgressNotification,
                                          context: self.syncManagedObjectContext.notificationContext,
                                          userInfo: [ CallStateObserver.CallInProgressKey : self.callInProgress ]).post()
                }
            }
        }
    }
    
}

extension CallStateObserver : WireCallCenterCallStateObserver, WireCallCenterMissedCallObserver  {
    
    public func callCenterDidChange(callState: CallState, conversation: ZMConversation, caller: ZMUser, timestamp: Date?) {
        
        let callerId = caller.remoteIdentifier
        let conversationId = conversation.remoteIdentifier
        
        syncManagedObjectContext.performGroupedBlock {
            guard
                let callerId = callerId,
                let conversationId = conversationId,
                let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: self.syncManagedObjectContext),
                let caller = ZMUser(remoteID: callerId, createIfNeeded: false, in: self.syncManagedObjectContext)
            else {
                return
            }
            
            let uiManagedObjectContext = self.syncManagedObjectContext.zm_userInterface
            uiManagedObjectContext?.performGroupedBlock {
                if let noneIdleCallCount = uiManagedObjectContext?.zm_callCenter?.nonIdleCalls.count {
                    self.callInProgress = noneIdleCallCount > 0
                }
            }
            
            // This will unarchive the conversation when there is an incoming call
            self.updateConversation(conversation, with: callState)

            if (self.userSession?.callNotificationStyle ?? .callKit) == .pushNotifications {
                self.localNotificationDispatcher.process(callState: callState, in: conversation, caller: caller)
            }
            
            self.updateConversationListIndicator(convObjectID: conversation.objectID, callState: callState)
            
            if let systemMessage = self.systemMessageGenerator.appendSystemMessageIfNeeded(callState: callState, conversation: conversation, caller: caller, timestamp: timestamp) {
                switch (systemMessage.systemMessageType, callState, conversation.conversationType) {
                case (.missedCall, .terminating(reason: .canceled), _ ):
                    // the caller canceled the call
                    fallthrough
                case (.missedCall, .terminating(reason: .normal), .group):
                    // group calls we didn't join, end with reason .normal. We should still insert a missed call in this case.
                    // since the systemMessageGenerator keeps track whether we joined or not, we can use it to decide whether we should show a missed call APNS
                    self.localNotificationDispatcher.processMissedCall(in: conversation, caller: caller)
                default:
                    break
                }
            }
            
            if let timestamp = timestamp {
                conversation.updateLastModifiedDateIfNeeded(timestamp)
            }
            self.syncManagedObjectContext.enqueueDelayedSave()
        }
    }
    
    public func updateConversationListIndicator(convObjectID: NSManagedObjectID, callState: CallState){
        // We need to switch to the uiContext here because we are making changes that need to be present on the UI when the change notification fires
        guard let uiMOC = self.syncManagedObjectContext.zm_userInterface else { return }
        uiMOC.performGroupedBlock {
            guard let uiConv = (try? uiMOC.existingObject(with: convObjectID)) as? ZMConversation else { return }
            
            switch callState {
            case .incoming(video: _, shouldRing: let shouldRing, degraded: _):
                uiConv.isIgnoringCall = uiConv.isSilenced || !shouldRing
                uiConv.isCallDeviceActive = false
            case .terminating, .none:
                uiConv.isCallDeviceActive = false
                uiConv.isIgnoringCall = false
            case .outgoing, .answered, .established:
                uiConv.isCallDeviceActive = true
            case .unknown, .establishedDataChannel:
                break
            }
            
            if uiMOC.zm_hasChanges {
                NotificationDispatcher.notifyNonCoreDataChanges(objectID: convObjectID,
                                                                changedKeys: [ZMConversationListIndicatorKey],
                                                                uiContext: uiMOC)
            }
        }
    }
    
    public func callCenterMissedCall(conversation: ZMConversation, caller: ZMUser, timestamp: Date, video: Bool) {
        let callerId = caller.remoteIdentifier
        let conversationId = conversation.remoteIdentifier
        
        syncManagedObjectContext.performGroupedBlock {
            guard
                let callerId = callerId,
                let conversationId = conversationId,
                let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: self.syncManagedObjectContext),
                let caller = ZMUser(remoteID: callerId, createIfNeeded: false, in: self.syncManagedObjectContext)
                else {
                    return
            }
            
            if (self.userSession?.callNotificationStyle ?? .callKit) == .pushNotifications {
                self.localNotificationDispatcher.processMissedCall(in: conversation, caller: caller)
            }
            
            conversation.appendMissedCallMessage(fromUser: caller, at: timestamp)
            self.syncManagedObjectContext.enqueueDelayedSave()
        }
    }
    
    private func updateConversation(_ conversation: ZMConversation, with callState: CallState) {
        guard conversation.isArchived, !conversation.isSilenced else { return }
        switch callState {
        case .incoming(_, shouldRing: true, degraded: _): conversation.isArchived = false
        default: break
        }
    }

}

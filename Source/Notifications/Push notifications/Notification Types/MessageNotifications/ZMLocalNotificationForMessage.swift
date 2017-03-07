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

import UIKit
import MobileCoreServices;
import UserNotifications

public protocol NotificationForMessage : LocalNotification {
    associatedtype MessageType : ZMMessage
    
    var contentType : ZMLocalNotificationContentType { get }
    init?(message: MessageType, application: Application?)
    func copyByAddingMessage(_ message: MessageType) -> Self?
    func configureAlertBody(_ message: MessageType) -> String
    static func shouldCreateNotification(_ message: MessageType) -> Bool
}

extension NotificationForMessage {
    
    public var soundName : String {
        switch contentType {
        case .knock:
            return ZMCustomSound.notificationPingSoundName()
        default:
            return ZMCustomSound.notificationNewMessageSoundName()
        }
    }
    
    public func configureNotification(_ message: MessageType, isEphemeral: Bool = false) -> UILocalNotification? {

        let shouldHideContent : Bool
        if let hide = message.managedObjectContext!.persistentStoreMetadata(forKey: ZMShouldHideNotificationContentKey) as? NSNumber, hide.boolValue == true {
            shouldHideContent = true
        } else {
            shouldHideContent = isEphemeral
        }

        if #available(iOS 10, *), contentType == .image {
            if shouldHideContent || isEphemeral {
                return createUINotification(message, isEphemeral: isEphemeral)
            }

            scheduleUNNotification(message)
            return nil
        } else {
            return createUINotification(message, isEphemeral: isEphemeral)
        }
    }

    @available(iOS 10, *)
    func scheduleUNNotification(_ message: MessageType) {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = conversationCategory(ephemeral: false)

        var info = [String: String]()
        if let userId = message.sender?.remoteIdentifier?.transportString() {
            info["sender"] = userId
        }
        if let conversationId = message.conversation?.remoteIdentifier?.transportString() {
            info["conversation"] = conversationId
        }

        let mesageNonce = message.nonce!.transportString()
        info["nonce"] = mesageNonce

        content.userInfo = info

        let request = UNNotificationRequest(identifier: mesageNonce, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            print("Error adding notification request: \(error), request: \(request)")
        }
    }

    func createUINotification(_ message: MessageType, isEphemeral: Bool = false) -> UILocalNotification {
        let notification = UILocalNotification()

        let shouldHideContent : Bool
        if let hide = message.managedObjectContext!.persistentStoreMetadata(forKey: ZMShouldHideNotificationContentKey) as? NSNumber, hide.boolValue == true {
            shouldHideContent = true
        } else {
            shouldHideContent = isEphemeral
        }
        if shouldHideContent {
            notification.alertBody = (isEphemeral ? ZMPushStringEphemeral : ZMPushStringDefault).localizedStringForPushNotification()
            notification.soundName = ZMCustomSound.notificationNewMessageSoundName()
            if isEphemeral {
                notification.category = conversationCategory(ephemeral: isEphemeral)
            }
        } else {
            notification.alertBody = configureAlertBody(message).escapingPercentageSymbols()
            notification.soundName = soundName
            notification.category = conversationCategory(ephemeral: isEphemeral)
        }

        notification.setupUserInfo(message)
        return notification
    }

    func conversationCategory(ephemeral: Bool) -> String {
        guard !ephemeral else { return ZMConversationCategory }
        switch contentType {
        case .image: return ZMConversationCategoryImage
        case .knock, .system(_), .undefined : return ZMConversationCategory
        default: return ZMConversationCategoryIncludingLike
        }
    }
    
    static public func shouldCreateNotification(_ message: MessageType) -> Bool {
        guard let sender = message.sender , !sender.isSelfUser
            else { return false }
        if let conversation = message.conversation {
            if conversation.isSilenced {
                return false
            }
            if let timeStamp = message.serverTimestamp, let lastRead = conversation.lastReadServerTimeStamp, lastRead.compare(timeStamp) != .orderedAscending {
                return false
            }
        }
        return true
    }
}


final public class ZMLocalNotificationForMessage : ZMLocalNotification, NotificationForMessage {
    public typealias MessageType = ZMOTRMessage
    public let contentType : ZMLocalNotificationContentType

    public var notifications : [UILocalNotification] = []

    let senderUUID : UUID
    let messageNonce : UUID

    public override var uiNotifications: [UILocalNotification] {
        return notifications
    }
    
    var eventCount : Int = 1
    unowned public var application : Application
    
    public required init?(message: ZMOTRMessage, application: Application?) {
        self.contentType = ZMLocalNotificationContentType.typeForMessage(message)
        guard type(of: self).canCreateNotification(message, contentType: contentType),
              let conversation = message.conversation,
              let sender = message.sender
        else {return nil}
        
        self.messageNonce = message.nonce
        self.senderUUID = sender.remoteIdentifier!
        self.application = application ?? UIApplication.shared
        super.init(conversationID: conversation.remoteIdentifier)
        
        if let notification = configureNotification(message, isEphemeral: message.isEphemeral) {
            notifications.append(notification)
        }
    }

    public func configureAlertBody(_ message: ZMOTRMessage) -> String {
        let sender = message.sender
        let conversation = message.conversation
        switch contentType {
        case .text(let content):
            return ZMPushStringMessageAdd.localizedString(with: sender, conversation: conversation, text:content)
        case .image:
            return ZMPushStringImageAdd.localizedString(with: sender, conversation: conversation)
        case .video:
            return ZMPushStringVideoAdd.localizedString(with: sender, conversation: conversation)
        case .audio:
            return ZMPushStringAudioAdd.localizedString(with: sender, conversation: conversation)
        case .fileUpload:
            return ZMPushStringFileAdd.localizedString(with: sender, conversation: conversation)
        case .location:
            return ZMPushStringLocationAdd.localizedString(with: sender, conversation: conversation)
        case .knock:
            let knockCount = NSNumber(value: eventCount)
            return ZMPushStringKnock.localizedString(with: sender, conversation:conversation, count:knockCount)
        case .undefined:
            return ZMPushStringUnknownAdd.localizedString(with: sender, conversation: conversation)
        case .system(_):
            return ""
        }
    }
    
    class func canCreateNotification(_ message : ZMOTRMessage, contentType: ZMLocalNotificationContentType) -> Bool {
        switch contentType {
        case .system:
            return false
        default:
           return shouldCreateNotification(message)
        }
    }
    
    public func copyByAddingMessage(_ message: ZMOTRMessage) -> ZMLocalNotificationForMessage? {
        let otherContentType = ZMLocalNotificationContentType.typeForMessage(message)
        guard otherContentType == contentType &&
              type(of: self).canCreateNotification(message, contentType: otherContentType),
              let conversation = message.conversation , conversation.remoteIdentifier == conversationID
        else { return nil }

        switch (otherContentType) {
        case (.knock):
            eventCount = eventCount+1
            cancelNotifications()
            if let note = configureNotification(message) {
                notifications.append(note)
            }
            return self
        default:
            return nil
        }
    }
    
    public func isNotificationFor(_ messageID: UUID) -> Bool {
        return (messageID == messageNonce)
    }
}




//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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


@testable import WireSyncEngine
import XCTest

class LocalNotificationDispatcherTests: MessagingTest {
    
    var sut: LocalNotificationDispatcher!
    var conversation1: ZMConversation!
    var conversation2: ZMConversation!
    var notificationDelegate: MockForegroundNotificationDelegate!
    
    var user1: ZMUser!
    var user2: ZMUser!
    
    var selfUser: ZMUser {
        return ZMUser.selfUser(in: self.syncMOC)
    }
    
    override func setUp() {
        super.setUp()
        self.notificationDelegate = MockForegroundNotificationDelegate()
        self.sut = LocalNotificationDispatcher(in: self.syncMOC,
                                               foregroundNotificationDelegate: self.notificationDelegate,
                                               application: self.application,
                                               operationStatus: self.mockUserSession.operationStatus)
        self.mockUserSession.operationStatus.isInBackground = true
        
        syncMOC.performGroupedBlockAndWait {
            self.user1 = ZMUser.insertNewObject(in: self.syncMOC)
            self.user2 = ZMUser.insertNewObject(in: self.syncMOC)
            self.user1.remoteIdentifier = UUID.create()
            self.user1.name = "User 1"
            self.user2.remoteIdentifier = UUID.create()
            self.user2.name = "User 2"
            self.conversation1 = ZMConversation.insertNewObject(in: self.syncMOC)
            self.conversation1.userDefinedName = "Conversation 1"
            self.conversation2 = ZMConversation.insertNewObject(in: self.syncMOC)
            self.conversation2.userDefinedName = "Conversation 2"
            [self.conversation1!, self.conversation2!].forEach {
                $0.conversationType = .group
                $0.remoteIdentifier = UUID.create()
                $0.internalAddParticipants(Set(arrayLiteral: self.user1))
            }
            self.conversation2.internalAddParticipants(Set(arrayLiteral: self.user2))
            
            self.selfUser.remoteIdentifier = UUID.create()
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
    }
    
    override func tearDown() {
        self.notificationDelegate = nil
        self.user1 = nil
        self.user2 = nil
        self.conversation1 = nil
        self.conversation2 = nil
        self.sut.tearDown()
        self.sut = nil
        super.tearDown()
    }
}


extension LocalNotificationDispatcherTests {

    func testThatItCreatesNotificationFromMessagesIfNotActive() {
        // GIVEN
        let text = UUID.create().transportString()
        let message = self.conversation1.appendMessage(withText: text) as! ZMClientMessage
        message.sender = self.user1
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
        XCTAssertEqual(self.notificationDelegate.receivedLocalNotifications.count, 0)
        guard let notification = self.application.scheduledLocalNotifications.first else { return XCTFail() }
        XCTAssertTrue(notification.alertBody!.contains(text))
    }
    
    func testThatItForwardsNotificationFromMessagesIfActive() {
        // GIVEN
        let text = UUID.create().transportString()
        let message = self.conversation1.appendMessage(withText: text) as! ZMClientMessage
        message.sender = self.user1
        self.mockUserSession.operationStatus.isInBackground = false
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 0)
        XCTAssertEqual(self.notificationDelegate.receivedLocalNotifications.count, 1)
    }

    func testThatItAddsNotificationOfDifferentConversationsToTheList() {
        
        // GIVEN
        let message1 = self.conversation1.appendMessage(withText: "foo1") as! ZMClientMessage
        message1.sender = self.user1
        let message2 = self.conversation2.appendMessage(withText: "boo2") as! ZMClientMessage
        message2.sender = self.user2
        
        // WHEN
        self.sut.process(message1)
        self.sut.process(message2)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        guard self.application.scheduledLocalNotifications.count == 2 else {
            return XCTFail("Wrong number of notifications")
        }
        XCTAssertEqual(self.application.scheduledLocalNotifications[0].conversation(in: self.syncMOC), self.conversation1)
        XCTAssertEqual(self.application.scheduledLocalNotifications[1].conversation(in: self.syncMOC), self.conversation2)
    }
    
    func testThatItDoesNotCreateANotificationForAnUnsupportedEventType() {
        // GIVEN
        let event = self.event(withPayload: nil, in: self.conversation1, type: EventConversationTyping)!
        
        // WHEN
        self.sut.didReceive(events: [event], conversationMap: [:])

        // THEN
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 0)
    }
    
    func testThatWhenFailingAMessageItSchedulesANotification() {
        self.syncMOC.performGroupedBlockAndWait {
            // GIVEN
            let message = self.conversation1.appendMessage(withText: "bar") as! ZMClientMessage
            message.sender = self.user1
            
            // WHEN
            self.sut.didFailToSend(message)
            
            // THEN
            XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
            
        }
    }
    
    func testThatItCancelsAllNotificationsForFailingMessagesWhenCancelingAllNotifications() {
        
        // GIVEN
        let note1 = ZMLocalNotification(expiredMessageIn: self.conversation1)!
        let note2 = ZMLocalNotification(expiredMessageIn: self.conversation1)!
        self.sut.eventNotifications.addObject(note1)
        self.sut.failedMessageNotifications.addObject(note2)
        
        // WHEN
        self.sut.cancelAllNotifications()
        
        // THEN
        XCTAssertEqual(self.application.cancelledLocalNotifications, [note1.uiLocalNotification, note2.uiLocalNotification])
    }

    func testThatItCancelsNotificationsForFailingMessagesWhenCancelingNotificationsForASpecificConversation() {
        
        // GIVEN
        let note1 = ZMLocalNotification(expiredMessageIn: self.conversation1)!
        let note2 = ZMLocalNotification(expiredMessageIn: self.conversation2)!
        let note3 = ZMLocalNotification(expiredMessageIn: self.conversation1)!
        let note4 = ZMLocalNotification(expiredMessageIn: self.conversation2)!
        self.sut.eventNotifications.addObject(note1)
        self.sut.eventNotifications.addObject(note2)
        self.sut.failedMessageNotifications.addObject(note3)
        self.sut.failedMessageNotifications.addObject(note4)
        
        // WHEN
        self.sut.cancelNotification(for: self.conversation1)
        
        // THEN
        XCTAssertEqual(self.application.cancelledLocalNotifications, [note1.uiLocalNotification, note3.uiLocalNotification])
        
    }
    
    func testThatItCancelsReadNotificationsIfTheLastReadChanges() {
        // GIVEN
        let message = self.conversation1.appendMessage(withText: "foo") as! ZMClientMessage
        message.sender = self.user1
        let note1 = ZMLocalNotification(expiredMessage: message)!
        let note2 = ZMLocalNotification(expiredMessageIn: self.conversation1)!
        self.sut.eventNotifications.addObject(note1)
        self.sut.eventNotifications.addObject(note2)
        
        // WHEN
        self.conversation1.updateLastReadServerTimeStampIfNeeded(withTimeStamp: Date(timeIntervalSinceNow: 1000), andSync: false)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(Set(self.application.cancelledLocalNotifications), Set([note2.uiLocalNotification, note1.uiLocalNotification]))
    }
    
    func testThatItSchedulesADefaultNotificationIfContentShouldNotBeVisible() {
        // GIVEN
        self.syncMOC.setPersistentStoreMetadata(NSNumber(value: true), key: LocalNotificationDispatcher.ZMShouldHideNotificationContentKey)
        self.syncMOC.saveOrRollback()
        let message = self.conversation1.appendMessage(withText: "foo") as! ZMClientMessage
        message.sender = self.user1
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        guard self.application.scheduledLocalNotifications.count == 1 else {
            return XCTFail("Wrong number of notifications")
        }
        XCTAssertEqual(self.application.scheduledLocalNotifications[0].alertBody, "New message")
        XCTAssertEqual(self.application.scheduledLocalNotifications[0].soundName, "new_message_apns.caf")
    
    }
        
    func testThatItDoesNotCreateNotificationForTwoMessageEventsWithTheSameNonce() {
        
        // GIVEN
        let message = self.conversation1.appendMessage(withText: "foobar") as! ZMClientMessage
        message.sender = self.user1
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        guard self.sut.messageNotifications.notifications.count == 1,
            self.application.scheduledLocalNotifications.count == 1 else {
                return XCTFail()
        }
        
        // WHEN 
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.sut.messageNotifications.notifications.count, 1)
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
    }
        
    func testThatItDoesNotCreateNotificationForFileUploadEventsWithTheSameNonce() {
    
        // GIVEN
        let url = Bundle(for: LocalNotificationDispatcherTests.self).url(forResource: "video", withExtension: "mp4")
        let audioMetadata = ZMAudioMetadata(fileURL: url!, duration: 100)
        let message = self.conversation1.appendMessage(with: audioMetadata) as! ZMAssetClientMessage
        message.sender = self.user1
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.sut.messageNotifications.notifications.count, 1)
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // THEN
        XCTAssertEqual(self.sut.messageNotifications.notifications.count, 1)
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
    }
        
    func testThatItCreatesNotificationForSelfGroupParticipation() {
    
        // GIVEN
        let message = ZMSystemMessage(nonce: UUID(), managedObjectContext: syncMOC)
        message.visibleInConversation = self.conversation1
        message.sender = self.user1
        message.systemMessageType = .participantsAdded
        message.users = [self.selfUser]
        
        // notification content
        let text = "\(message.sender!.name!) added you"
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 1)
        XCTAssertEqual(self.notificationDelegate.receivedLocalNotifications.count, 0)
        guard let notification = self.application.scheduledLocalNotifications.first else { return XCTFail() }
        XCTAssertTrue(notification.alertBody!.contains(text))
    }
    
    func testThatItDoesNotCreateNotificationForOtherGroupParticipation() {
        
        // GIVEN
        let message = ZMSystemMessage(nonce: UUID(), managedObjectContext: syncMOC)
        message.visibleInConversation = self.conversation1
        message.sender = self.user1
        message.systemMessageType = .participantsAdded
        message.users = [self.user2]
        
        // WHEN
        self.sut.process(message)
        XCTAssertTrue(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // THEN
        XCTAssertEqual(self.application.scheduledLocalNotifications.count, 0)
        XCTAssertEqual(self.notificationDelegate.receivedLocalNotifications.count, 0)
    }
    
    func testThatItCancelsNotificationWhenUserDeletesLike() {
        let conversation = ZMConversation.insertNewObject(in: self.syncMOC)
        conversation.remoteIdentifier = UUID.create()
        let sender = ZMUser.insertNewObject(in: self.syncMOC)
        sender.remoteIdentifier = UUID.create()
        
        let message = conversation.appendMessage(withText: "text") as! ZMClientMessage
        let reaction1 = ZMGenericMessage(emojiString: "❤️", messageID: message.nonce!, nonce: UUID.create())
        let reaction2 = ZMGenericMessage(emojiString: "", messageID: message.nonce!, nonce: UUID.create())
        
        let event1 = createUpdateEvent(UUID.create(), conversationID: conversation.remoteIdentifier!, genericMessage: reaction1, senderID: sender.remoteIdentifier!)
        let event2 = createUpdateEvent(UUID.create(), conversationID: conversation.remoteIdentifier!, genericMessage: reaction2, senderID: sender.remoteIdentifier!)
    
        sut.didReceive(events: [event1], conversationMap: [:])
        XCTAssertEqual(application.scheduledLocalNotifications.count, 1)
        let note = application.scheduledLocalNotifications.first!
        
        // WHEN
        sut.didReceive(events: [event2], conversationMap: [:])
        
        // THEN
        XCTAssertTrue(application.cancelledLocalNotifications.contains(note))
    }
}



// MARK: - Helpers
extension LocalNotificationDispatcherTests {
        
    func payloadForEncryptedOTRMessage(text: String, nonce: UUID) -> [String: Any] {
        let message = ZMGenericMessage.message(text: text, nonce: nonce)
        return self.payloadForOTRAsset(with: message)
    }
    
    func payloadForOTRAsset(with message: ZMGenericMessage) -> [String: Any] {
        return [
            "data": [
                "info": message.data().base64String()
            ],
            "conversation": self.conversation1.remoteIdentifier!.transportString(),
            "type": EventConversationAddOTRAsset,
            "time": Date().transportString()
        ]
    }

    func payloadForOTRMessage(with message: ZMGenericMessage) -> [String: Any] {
        return [
            "data": [
                "text": message.data().base64String()
            ],
            "conversation": self.conversation1.remoteIdentifier!.transportString(),
            "type": EventConversationAddOTRAsset,
            "time": Date().transportString()
        ]
    }
    
    func createUpdateEvent(_ nonce: UUID, conversationID: UUID, genericMessage: ZMGenericMessage, senderID: UUID = UUID.create()) -> ZMUpdateEvent {
        let payload : [String : Any] = [
            "id": UUID.create().transportString(),
            "conversation": conversationID.transportString(),
            "from": senderID.transportString(),
            "time": Date().transportString(),
            "data": ["text": genericMessage.data().base64String()],
            "type": "conversation.otr-message-add"
        ]
        
        return ZMUpdateEvent(fromEventStreamPayload: payload as ZMTransportData, uuid: nonce)!
    }
}


class MockForegroundNotificationDelegate: NSObject, ForegroundNotificationsDelegate {
    
    var receivedLocalNotifications: [UILocalNotification] = []

    func didReceieveLocal(notification: ZMLocalNotification, application: ZMApplication) {
        self.receivedLocalNotifications.append(notification.uiLocalNotification)
    }
}


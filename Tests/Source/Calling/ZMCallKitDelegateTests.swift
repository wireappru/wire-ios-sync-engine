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
import ZMCDataModel
import Intents
@testable import zmessaging

@available(iOS 10.0, *)
class MockCallKitProvider: NSObject, CallKitProviderType {
    
    required init(configuration: CXProviderConfiguration) {
        
    }
    
    public var timesSetDelegateCalled: Int = 0
    func setDelegate(_ delegate: CXProviderDelegate?, queue: DispatchQueue?) {
        timesSetDelegateCalled = timesSetDelegateCalled + 1
    }
    
    public var timesReportNewIncomingCallCalled: Int = 0
    func reportNewIncomingCall(with UUID: UUID, update: CXCallUpdate, completion: @escaping (Error?) -> Void) {
        timesReportNewIncomingCallCalled = timesReportNewIncomingCallCalled + 1
    }
    
    public var timesReportCallEndedAtCalled: Int = 0
    func reportCall(with UUID: UUID, endedAt dateEnded: Date?, reason endedReason: CXCallEndedReason) {
        timesReportCallEndedAtCalled = timesReportCallEndedAtCalled + 1
    }
    
    public var timesReportOutgoingCallConnectedAtCalled: Int = 0
    func reportOutgoingCall(with UUID: UUID, connectedAt dateConnected: Date?) {
        timesReportOutgoingCallConnectedAtCalled = timesReportOutgoingCallConnectedAtCalled + 1
    }
    
    public var timesReportOutgoingCallStartedConnectingCalled: Int = 0
    func reportOutgoingCall(with UUID: UUID, startedConnectingAt dateStartedConnecting: Date?) {
        timesReportOutgoingCallStartedConnectingCalled = timesReportOutgoingCallStartedConnectingCalled + 1
    }
}

@available(iOS 10.0, *)
class MockCallKitCallController: NSObject, CallKitCallController {
    
    public var timesRequestTransactionCalled: Int = 0
    public var requestedTransaction: CXTransaction? = .none
    
    @available(iOS 10.0, *)
    public func request(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        timesRequestTransactionCalled = timesRequestTransactionCalled + 1
        requestedTransaction = transaction
        completion(.none)
    }
}

@available(iOS 10.0, *)
class ZMCallKitDelegateTest: MessagingTest {
    var sut: ZMCallKitDelegate!
    var callKitProvider: MockCallKitProvider!
    var callKitController: MockCallKitCallController!
    
    func otherUser(moc: NSManagedObjectContext) -> ZMUser {
        let otherUser = ZMUser(context: moc)
        otherUser.remoteIdentifier = UUID()
        otherUser.name = "Other Test User"
        
        return otherUser
    }
    
    func conversation(type: ZMConversationType = .oneOnOne, moc: NSManagedObjectContext? = .none) -> ZMConversation {
        let moc = moc ?? self.uiMOC
        let conversation = ZMConversation(context: moc)
        conversation.remoteIdentifier = UUID()
        conversation.conversationType = type
        
        if type == .group {
            conversation.addParticipant(self.otherUser(moc: moc))
        }
        
        return conversation
    }
    
    override func setUp() {
        super.setUp()
        ZMUserSession.setUseCallKit(true)
        
        let selfUser = ZMUser.selfUser(in: self.uiMOC)
        selfUser.emailAddress = "self@user.mail"
        
        let configuration = ZMCallKitDelegate.providerConfiguration()
        self.callKitProvider = MockCallKitProvider(configuration: configuration)
        self.callKitController = MockCallKitCallController()
        
        self.sut = ZMCallKitDelegate(callKitProvider: self.callKitProvider,
                                     callController: self.callKitController,
                                     userSession: self.mockUserSession,
                                     mediaManager: nil)
        
        ZMCallKitDelegateTestsMocking.mockUserSession(self.mockUserSession, callKitDelegate: self.sut)
    }
    
    // Public API - provider configuration
    func testThatItReturnsTheProviderConfiguration() {
        // when
        let configuration = ZMCallKitDelegate.providerConfiguration()
        
        // then
        XCTAssertEqual(configuration.supportsVideo, true)
        XCTAssertEqual(configuration.localizedName, "zmessaging Test Host")
        XCTAssertTrue(configuration.supportedHandleTypes.contains(.phoneNumber))
        XCTAssertTrue(configuration.supportedHandleTypes.contains(.emailAddress))
        XCTAssertTrue(configuration.supportedHandleTypes.contains(.generic))
    }
    
    func testThatItReturnsDefaultRingSound() {
        // when
        let configuration = ZMCallKitDelegate.providerConfiguration()
        
        // then
        XCTAssertEqual(configuration.ringtoneSound, "ringing_from_them_long.caf")
    }
    
    func testThatItReturnsCustomRingSound() {
        defer {
            UserDefaults.standard.removeObject(forKey: "ZMCallSoundName")
        }
        let customSoundName = "harp"
        // given
        UserDefaults.standard.setValue(customSoundName, forKey: "ZMCallSoundName")
        // when
        let configuration = ZMCallKitDelegate.providerConfiguration()
        
        // then
        XCTAssertEqual(configuration.ringtoneSound, customSoundName + ".m4a")
    }
    
    // Public API - outgoing calls
    func testThatItReportsTheStartCallRequest() {
        // given
        let conversation = self.conversation(type: .oneOnOne)
        
        // when
        self.sut.requestStartCall(in: conversation, videoCall: false)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXStartCallAction

        XCTAssertEqual(action.callUUID, conversation.remoteIdentifier)
        XCTAssertEqual(action.handle.type, .emailAddress)
        XCTAssertEqual(action.handle.value, ZMUser.selfUser(in: self.uiMOC).emailAddress)
    }
    
    func testThatItReportsTheStartCallRequest_groupConversation() {
        // given
        let conversation = self.conversation(type: .group)
        
        // when
        self.sut.requestStartCall(in: conversation, videoCall: false)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
        
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXStartCallAction
        XCTAssertEqual(action.callUUID, conversation.remoteIdentifier)
        XCTAssertEqual(action.handle.type, .emailAddress)
        XCTAssertEqual(action.handle.value, ZMUser.selfUser(in: self.uiMOC).emailAddress)
        XCTAssertFalse(action.isVideo)
    }
    
    func testThatItReportsTheStartCallRequest_Video() {
        // given
        let conversation = self.conversation(type: .oneOnOne)
        
        // when
        self.sut.requestStartCall(in: conversation, videoCall: true)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXStartCallAction
        
        XCTAssertEqual(action.callUUID, conversation.remoteIdentifier)
        XCTAssertEqual(action.handle.type, .emailAddress)
        XCTAssertEqual(action.handle.value, ZMUser.selfUser(in: self.uiMOC).emailAddress)
        XCTAssertTrue(action.isVideo)
    }
    
    // Public API - report end on outgoing call
    
    func testThatItReportsTheEndOfCall() {
        // given
        let conversation = self.conversation(type: .oneOnOne)
        
        // when
        self.sut.requestEndCall(in: conversation)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXEndCallAction)
        
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXEndCallAction
        XCTAssertEqual(action.callUUID, conversation.remoteIdentifier)
    }
    
    func testThatItReportsTheEndOfCall_groupConversation() {
        // given
        let conversation = self.conversation(type: .group)
        
        // when
        self.sut.requestEndCall(in: conversation)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXEndCallAction)
        
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXEndCallAction
        XCTAssertEqual(action.callUUID, conversation.remoteIdentifier)
    }
    
    // Public API - activity & intents
    
    func userActivityFor(contacts: [INPerson]?) -> NSUserActivity {
        
        let intent = INStartAudioCallIntent(contacts: contacts)
        
        let interaction = INInteraction(intent: intent, response: .none)
        
        let activity = NSUserActivity(activityType: "voip")
        activity.setValue(interaction, forKey: "interaction")
        
        return activity
    }
    
    func testThatItStartsCallForUserKnownByEmail() {
        // given
        let otherUser = self.otherUser(moc: self.uiMOC)
        otherUser.emailAddress = "user@email.com"
        let oneToOne = ZMConversation.insertNewObject(in: self.uiMOC)
        oneToOne.conversationType = .oneOnOne

        let connection = ZMConnection.insertNewObject(in: self.uiMOC)
        connection.status = .accepted
        connection.conversation = oneToOne
        connection.to = otherUser
        
        let handle = INPersonHandle(value: otherUser.emailAddress!, type: .emailAddress)
        let person = INPerson(personHandle: handle, nameComponents: .none, displayName: .none, image: .none, contactIdentifier: .none, customIdentifier: .none)
        
        let activity = self.userActivityFor(contacts: [person])
       
        // when
        self.sut.`continue`(activity)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
        
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXStartCallAction
        XCTAssertEqual(action.handle.type, .emailAddress)
        XCTAssertEqual(action.handle.value, ZMUser.selfUser(in: self.uiMOC).emailAddress)
        XCTAssertFalse(action.isVideo)
    }
    
    func testThatItStartsCallForUserKnownByPhone() {
        // given
        let otherUser = self.otherUser(moc: self.uiMOC)
        otherUser.phoneNumber = "+123456789"
        
        let handle = INPersonHandle(value: otherUser.phoneNumber!, type: .phoneNumber)
        let person = INPerson(personHandle: handle, nameComponents: .none, displayName: .none, image: .none, contactIdentifier: .none, customIdentifier: .none)
        
        let activity = self.userActivityFor(contacts: [person])
        
        // when
        self.sut.`continue`(activity)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
        
        let action = self.callKitController.requestedTransaction!.actions.first! as! CXStartCallAction
        XCTAssertEqual(action.handle.type, .phoneNumber)
        XCTAssertEqual(action.handle.value, ZMUser.selfUser(in: self.uiMOC).phoneNumber)
        XCTAssertFalse(action.isVideo)
    }
    
    func testThatItStartsCallForGroup() {
        
    }
    
    func testThatItIgnoresUnknownActivity() {
        
    }
    
    func testThatItIgnoresActivityWitoutContacts() {
        
    }
    
    func testThatItIgnoresActivityWithManyContacts() {
        
    }
    
    func testThatItIgnoresActivityWithContactUnknown() {
        
    }
    
    // Observer API - report incoming call
    
    // Observer API - report end of call
}

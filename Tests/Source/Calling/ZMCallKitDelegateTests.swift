//
//  ZMCallKitDelegateTests.swift
//  zmessaging-cocoa
//
//  Created by Mihail Gerasimenko on 10/17/16.
//  Copyright © 2016 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import ZMCDataModel
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
    
    func conversation(type: ZMConversationType = .oneOnOne, moc: NSManagedObjectContext? = .none) -> ZMConversation {
        let moc = moc ?? self.uiMOC
        let conversation = ZMConversation(context: moc)
        conversation.remoteIdentifier = UUID.create()
        conversation.conversationType = type

        return conversation
    }
    
    override func setUp() {
        super.setUp()
        ZMUserSession.setUseCallKit(true)
        
        let configuration = ZMCallKitDelegate.providerConfiguration()
        self.callKitProvider = MockCallKitProvider(configuration: configuration)
        self.callKitController = MockCallKitCallController()
        
        self.sut = ZMCallKitDelegate(callKitProvider: self.callKitProvider,
                                     callController: self.callKitController,
                                     userSession: nil,
                                     mediaManager: nil)
    }
    
    
    // Public API
    func testThatItReportsTheStartCallRequest() {
        // given
        let conversation = self.conversation(type: .oneOnOne)
        
        // when
        self.sut.requestStartCall(in: conversation, videoCall: false)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
    }
    
    func testThatItReportsTheStartCallRequest_groupConversation() {
        // given
        let conversation = self.conversation(type: .group)
        
        // when
        self.sut.requestStartCall(in: conversation, videoCall: false)
        
        // then
        XCTAssertEqual(self.callKitController.timesRequestTransactionCalled, 1)
        XCTAssertTrue(self.callKitController.requestedTransaction!.actions.first! is CXStartCallAction)
    }
}

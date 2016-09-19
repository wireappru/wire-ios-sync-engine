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
import zmessaging
import ZMCMockTransport

class OTRTests : IntegrationTestBase
{
    override func setUp() {
        super.setUp()
    }
    
    func hasMockTransportRequest(_ count: Int = 1, filter: (ZMTransportRequest) -> Bool) -> Bool {
        return (self.mockTransportSession.receivedRequests() as! [ZMTransportRequest]).filter(filter).count >= count
    }
    
    func hasMockTransportRequest(_ method : ZMTransportRequestMethod, path : String, count : Int = 1) -> Bool  {
        return self.hasMockTransportRequest(count, filter: {
            $0.method == method && $0.path == path
        })
    }
        
    func testThatItSendsEncryptedTextMessage()
    {
        // given
        XCTAssert(logInAndWaitForSyncToBeComplete())
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        guard let conversation = self.conversation(for: self.selfToUser1Conversation) else {return XCTFail()}
        
        let text = "Foo bar, but encrypted"
        self.mockTransportSession.resetReceivedRequests()
        
        // when
        var message: ZMConversationMessage?
        userSession.performChanges {
            message = conversation.appendMessage(withText: text)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertNotNil(message)
        XCTAssertTrue(self.hasMockTransportRequest(.methodPOST, path: "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/messages"))
    }
    
    func testThatItSendsEncryptedImageMessage()
    {
        // given
        XCTAssert(self.logInAndWaitForSyncToBeComplete())
        XCTAssert(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        guard let conversation = self.conversation(for: self.selfToUser1Conversation) else {return XCTFail()}
        self.mockTransportSession.resetReceivedRequests()
        let imageData = self.verySmallJPEGData()
        
        // when
        let message = conversation.appendMessage(withImageData: imageData)
        self.uiMOC.saveOrRollback()
        XCTAssert(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertNotNil(message)
        XCTAssertTrue(self.hasMockTransportRequest(.methodPOST, path: "/conversations/\(conversation.remoteIdentifier!.transportString())/otr/assets", count: 2))
    }
    
    func testThatItSendsARequestToUpdateSignalingKeys(){
        
        // given
        XCTAssert(self.logInAndWaitForSyncToBeComplete())
        XCTAssert(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        self.mockTransportSession.resetReceivedRequests()

        var didReregister = false
        self.mockTransportSession.responseGeneratorBlock = { response in
            if response.path.contains("/clients/") && response.payload?.asDictionary()?["sigkeys"] != nil {
                didReregister = true
                return ZMTransportResponse(payload: [] as ZMTransportData, httpStatus: 200, transportSessionError: nil)
            }
            return nil
        }
        
        // when
        self.userSession.performChanges {
            UserClient.resetSignalingKeysInContext(self.uiMOC)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))

        // then
        XCTAssertTrue(didReregister)
    }

    func testThatItCreatesNewKeysIfReqeustToSyncSignalingKeysFailedWithBadRequest() {
        
        // given
        XCTAssert(self.logInAndWaitForSyncToBeComplete())
        XCTAssert(self.waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        self.mockTransportSession.resetReceivedRequests()

        var tryCount = 0
        var firstSigKeys = [String : String]()
        self.mockTransportSession.responseGeneratorBlock = { response in
            guard let payload = response.payload?.asDictionary() else {return nil}
            
            if response.path.contains("/clients/") && payload["sigkeys"] != nil {
                if tryCount == 0 {
                    tryCount += 1
                    firstSigKeys = payload["sigkeys"] as! [String : String]
                    return ZMTransportResponse(payload: ["label" : "bad-request"] as ZMTransportData, httpStatus: 400, transportSessionError: nil)
                }
                tryCount += 1
                XCTAssertNotEqual(payload["sigkeys"] as! [String : String], firstSigKeys)
                return ZMTransportResponse(payload: [] as ZMTransportData, httpStatus: 200, transportSessionError: nil)
            }
            return nil
        }
        
        // when
        self.userSession.performChanges {
            UserClient.resetSignalingKeysInContext(self.uiMOC)
        }
        XCTAssert(waitForAllGroupsToBeEmpty(withTimeout: 0.5))
        
        // then
        XCTAssertEqual(tryCount, 2)
    }
}


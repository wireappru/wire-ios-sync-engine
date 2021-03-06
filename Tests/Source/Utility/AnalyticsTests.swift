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
import XCTest
import WireTesting
@testable import WireSyncEngine



class AnalyticsTests: ZMTBaseTest {
    
    var analytics: MockAnalytics!
    var directory: ManagedObjectContextDirectory!
    var sharedContainerURL : URL!
    var accountID : UUID!

    func createSyncContext() -> NSManagedObjectContext {
        let expectation = self.expectation(description: "create directory")
        StorageStack.shared.createManagedObjectContextDirectory(accountIdentifier: accountID, applicationContainer: sharedContainerURL) {
            self.directory = $0
            expectation.fulfill()
        }
        XCTAssert(self.waitForCustomExpectations(withTimeout: 0.5))
        return self.directory.syncContext
    }

    override func setUp() {
        super.setUp()
        analytics = MockAnalytics()
        accountID = UUID()
        sharedContainerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    override func tearDown() {
        sharedContainerURL = nil
        directory = nil
        accountID = nil
        analytics = nil
        StorageStack.reset()
        super.tearDown()
    }
    
    func testThatItSetsAnalyticsOnManagedObjectContext() {
        // given
        let context = createSyncContext()
        
        // when
        context.analytics = analytics
        
        // then
        XCTAssertNotNil(context.analytics)
        XCTAssertEqual(context.analytics as? MockAnalytics, analytics)
        context.analytics = nil
        XCTAssertNil(context.analytics)
    }
}

// MARK: - Address book tag
extension AnalyticsTests {
    
    func testThatItTracksTheAddresBookSizeWhenThereIsNoLastUploadDate() {
        assertThatItTracksAddresBookUploadEnded(0)
    }

    
    func testThatItTracksTheAddresBookSizeWhenThereIsALastUploadDate() {
        assertThatItTracksAddresBookUploadEnded(12)
    }

    
    func testThatItDoesNotTrackTheIntervalSinceLastAddresBookUploadIfTheLastDateIsInTheFuture() {
        assertThatItTracksAddresBookUploadEnded(-42, shouldTrackInterval: false)
    }
    
    func testThatItDoesTrackTheIntervalBetweenTwoUploads() {
        // given
        let tracker = WireSyncEngine.AddressBookAnalytics(analytics: analytics, managedObjectContext: createSyncContext())
        
        
        // when
        tracker.tagAddressBookUploadSuccess()
        tracker.tagAddressBookUploadSuccess()
        
        // then
        XCTAssertTrue(analytics.taggedEvents.isEmpty)
        XCTAssertEqual(analytics.taggedEventsWithAttributes.count, 2)
        let eventWithAtributes = analytics.taggedEventsWithAttributes.last!
        XCTAssertEqual(eventWithAtributes.event, "connect.completed_addressbook_search")
        XCTAssertEqual((eventWithAtributes.attributes["interval"] as? NSNumber)?.intValue, 0)
    }
    
    func testThatItTracksAddresBookUploadStarted() {
        // given
        let size : UInt = 345
        let tracker = WireSyncEngine.AddressBookAnalytics(analytics: analytics, managedObjectContext: createSyncContext())
        
        // when
        tracker.tagAddressBookUploadStarted(size)
        
        // then
        XCTAssertTrue(analytics.taggedEvents.isEmpty)
        XCTAssertEqual(analytics.taggedEventsWithAttributes.count, 1)
        let eventWithAtributes = analytics.taggedEventsWithAttributes.first!
        XCTAssertEqual(eventWithAtributes.event, "connect.started_addressbook_search")
        XCTAssertEqual(eventWithAtributes.attributes, ["size": NSNumber(value: size)])
    }
}

extension AnalyticsTests {
    
    func assertThatItTracksAddresBookUploadEnded(_ hoursSinceLastUpload: Int? = nil, shouldTrackInterval: Bool = true, line: UInt = #line) {
        // given
        let tracker = WireSyncEngine.AddressBookAnalytics(analytics: analytics, managedObjectContext: createSyncContext())
        if let hours = hoursSinceLastUpload.map(TimeInterval.init) {
            let lastDate = Date(timeIntervalSinceNow: -hours * 3600)
            tracker.managedObjectContext.lastAddressBookUploadDate = lastDate
        }

        // when
        tracker.tagAddressBookUploadSuccess()
        
        // then
        XCTAssertTrue(analytics.taggedEvents.isEmpty)
        XCTAssertEqual(analytics.taggedEventsWithAttributes.count, 1, line: line)
        let eventWithAtributes = analytics.taggedEventsWithAttributes.first!
        XCTAssertEqual(eventWithAtributes.event, "connect.completed_addressbook_search", line: line)
        
        var attributes: [String: NSObject] = [:]
        
        if let hours = hoursSinceLastUpload, shouldTrackInterval {
            attributes["interval"] = NSNumber(value: hours)
        }
        XCTAssertEqual(eventWithAtributes.attributes, attributes, line: line)
    }
}

// MARK: - Helpers
struct EventWithAttributes: Equatable {
    let event: String
    let attributes: [String: NSObject]
}

func ==(lhs: EventWithAttributes, rhs: EventWithAttributes) -> Bool {
    return lhs.event == rhs.event && lhs.attributes == rhs.attributes
}

final class MockAnalytics: NSObject, AnalyticsType {

    var eventAttributes = [String : [String : NSObject]]()

    public func setPersistedAttributes(_ attributes: [String : NSObject]?, for event: String) {
        if let attributes = attributes {
            eventAttributes[event] = attributes
        } else {
            eventAttributes.removeValue(forKey: event)
        }
    }

    public func persistedAttributes(for event: String) -> [String : NSObject]? {
        let value = eventAttributes[event] ?? [:]
        return value
    }
    
    @objc func tagEvent(_ event: String) {
        taggedEvents.append(event)
    }
    
    @objc func tagEvent(_ event: String, attributes: [String : NSObject]) {
        taggedEventsWithAttributes.append(EventWithAttributes(event: event, attributes: attributes))
    }
    
    @objc func upload() {
        uploadCallCount += 1
    }
    
    var taggedEvents = [String]()
    var taggedEventsWithAttributes = [EventWithAttributes]()
    var uploadCallCount = 0
}

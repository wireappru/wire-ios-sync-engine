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

import Foundation
@testable import WireSyncEngine

class TeamRegistrationStrategyTests: MessagingTest {
    var registrationStatus : TestRegistrationStatus!
    var sut : WireSyncEngine.TeamRegistrationStrategy!
    var userInfoParser: MockUserInfoParser!
    var team: TeamToRegister!

    override func setUp() {
        super.setUp()
        registrationStatus = TestRegistrationStatus()
        userInfoParser = MockUserInfoParser()
        sut = WireSyncEngine.TeamRegistrationStrategy(groupQueue: self.syncMOC, status: registrationStatus, userInfoParser: userInfoParser)
        team = WireSyncEngine.TeamToRegister(teamName: "Dream Team", email: "some@email.com", emailCode: "23", fullName: "M. Jordan", password: "qwerty", accentColor: .brightOrange)
    }

    override func tearDown() {
        sut = nil
        registrationStatus = nil
        userInfoParser = nil
        team = nil
        super.tearDown()
    }

    // MARK: - Idle state

    func testThatItDoesNotGenerateRequestWhenPhaseIsNone() {
        let request = sut.nextRequest()
        XCTAssertNil(request);
    }

    // MARK: - Sending request

    func testThatItMakesARequestWhenStateIsCreateTeam() {
        //given
        let path = "/register"
        let payload = team.payload

        let transportRequest = ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
        registrationStatus.phase = .createTeam(team: team)

        //when

        let request = sut.nextRequest()

        //then
        XCTAssertNotNil(request);
        XCTAssertEqual(request, transportRequest)
    }

    func testThatItNotifiesStatusAfterSuccessfulResponseToTeamCreate() {
        // given
        registrationStatus.phase = .createTeam(team: team)
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil)

        // when
        XCTAssertEqual(registrationStatus.successCalled, 0)
        sut.didReceive(response, forSingleRequest: sut.registrationSync)

        // then
        XCTAssertEqual(registrationStatus.successCalled, 1)
    }

    // MARK: - Parsing user info

    func testThatItCallsParseUserInfoOnSuccess() {
        // given
        registrationStatus.phase = .createTeam(team: team)
        let response = ZMTransportResponse(payload: nil, httpStatus: 200, transportSessionError: nil)

        // when
        XCTAssertEqual(userInfoParser.parseCallCount, 0)
        sut.didReceive(response, forSingleRequest: sut.registrationSync)

        // then
        XCTAssertEqual(userInfoParser.parseCallCount, 1)
    }
}

// MARK:- error tests for team creation

extension TeamRegistrationStrategyTests: RegistrationStatusStrategyTestHelper {

    func handleResponse(response: ZMTransportResponse) {
        sut.didReceive(response, forSingleRequest: sut.registrationSync)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_BlacklistEmail() {
        checkResponseError(with: .createTeam(team: team), code: .blacklistedEmail, errorLabel: "blacklisted-email", httpStatus: 403)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_EmailExists() {
        checkResponseError(with: .createTeam(team: team), code: .emailIsAlreadyRegistered, errorLabel: "key-exists", httpStatus: 409)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_InvalidActivationCode() {
        checkResponseError(with: .createTeam(team: team), code: .invalidActivationCode, errorLabel: "invalid-code", httpStatus: 404)
    }

    func testThatItNotifiesStatusAfterErrorToEmailVerify_OtherError() {
        checkResponseError(with: .createTeam(team: team), code: .unknownError, errorLabel: "not-clear-what-happened", httpStatus: 414)
    }
}

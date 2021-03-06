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


@import WireTransport;
@import WireDataModel;
@import WireTransport;

#import "MessagingTest.h"
#import "ZMUserSessionRegistrationNotification.h"
#import "ZMCredentials.h"
#import "NSError+ZMUserSessionInternal.h"
#import <WireSyncEngine/WireSyncEngine-Swift.h>
#import "WireSyncEngine_iOS_Tests-Swift.h"


@interface ZMAuthenticationStatusTests : MessagingTest

@property (nonatomic) ZMAuthenticationStatus *sut;

@property (nonatomic) id authenticationObserverToken;
@property (nonatomic, copy) void(^authenticationCallback)(enum PreLoginAuthenticationEventObjc event, NSError *error);

@property (nonatomic) id registrationObserverToken;
@property (nonatomic, copy) void(^registrationCallback)(ZMUserSessionRegistrationNotificationType type, NSError *error);
@property (nonatomic) MockUserInfoParser *userInfoParser;

@end

@implementation ZMAuthenticationStatusTests

- (void)setUp {
    [super setUp];

    self.userInfoParser = [[MockUserInfoParser alloc] init];
    DispatchGroupQueue *groupQueue = [[DispatchGroupQueue alloc] initWithQueue:dispatch_get_main_queue()];
    self.sut = [[ZMAuthenticationStatus alloc] initWithGroupQueue:groupQueue userInfoParser:self.userInfoParser];

    // If a test fires any notification and it's not listening for it, this will fail
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error){
        NOT_USED(error);
        ZM_STRONG(self);
        XCTFail(@"Unexpected notification: %li", event);
    };
    // If a test fires any notification and it's not listening for it, this will fail
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, NSError *error){
        NOT_USED(error);
        ZM_STRONG(self);
        XCTFail(@"Unexpected notification %li", type);
    }; // forces to overwrite if a test fires this
    
    self.authenticationObserverToken = [[PreLoginAuthenticationObserverToken alloc] initWithAuthenticationStatus:self.sut handler:^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        self.authenticationCallback(event, error);
    }];
    
    self.registrationObserverToken = [ZMUserSessionRegistrationNotification addObserverInContext:self.sut withBlock:^(ZMUserSessionRegistrationNotificationType event, NSError *error) {
        ZM_STRONG(self);
        self.registrationCallback(event, error);
    }];
}

- (void)tearDown
{
    self.sut = nil;
    self.authenticationObserverToken = nil;
    self.registrationObserverToken = nil;
    self.userInfoParser = nil;
    [super tearDown];
}

- (void)testThatAllValuesAreEmptyAfterInit
{
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    
    XCTAssertNil(self.sut.registrationUser);
    XCTAssertNil(self.sut.registrationPhoneNumberThatNeedsAValidationCode);
    XCTAssertNil(self.sut.loginPhoneNumberThatNeedsAValidationCode);
    XCTAssertNil(self.sut.loginCredentials);
    XCTAssertNil(self.sut.registrationPhoneValidationCredentials);
}


- (void)testThatItIsLoggedInWhenThereIsAuthenticationDataSelfUserSyncedAndClientIsAlreadyRegistered
{
    // when
    self.sut.authenticationCookieData = NSData.data;
    [self.uiMOC setPersistentStoreMetadata:@"someID" forKey:ZMPersistedClientIdKey];
    ZMUser *selfUser = [ZMUser selfUserInContext:self.uiMOC];
    selfUser.remoteIdentifier = [NSUUID new];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseAuthenticated);
    [self.uiMOC setPersistentStoreMetadata:nil forKey:@"PersistedClientId"];
}

- (void)testThatItSetsIgnoreCookiesWhenEmailRegistrationUserIsSet
{
    XCTAssertEqual([ZMPersistentCookieStorage cookiesPolicy], NSHTTPCookieAcceptPolicyAlways);
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithEmail:@"some@example.com" password:@"password"];
    [self.sut prepareForRegistrationOfUser:regUser];
    XCTAssertEqual([ZMPersistentCookieStorage cookiesPolicy], NSHTTPCookieAcceptPolicyNever);
}

- (void)testThatItSetsAcceptCookiesWhenPhoneNumberRegistrationUserIsSet
{
    [ZMPersistentCookieStorage setCookiesPolicy:NSHTTPCookieAcceptPolicyNever];
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithPhoneNumber:@"1234567890" phoneVerificationCode:@"123456"];
    [self.sut prepareForRegistrationOfUser:regUser];
    XCTAssertEqual([ZMPersistentCookieStorage cookiesPolicy], NSHTTPCookieAcceptPolicyAlways);
}

- (void)testThatItSetsAcceptCookiesWhenLoginCredentialsAreSet
{
    //given
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithEmail:@"some@example.com" password:@"password"];
    
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(__unused  ZMUserSessionRegistrationNotificationType type, __unused NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual([ZMPersistentCookieStorage cookiesPolicy], NSHTTPCookieAcceptPolicyAlways);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRegistrationOfUser:regUser];
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut didCompleteRegistrationSuccessfullyWithResponse:nil]; // We don't care about response in here
    }];
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
}

@end

@implementation ZMAuthenticationStatusTests (PrepareMethods)

- (void)testThatItCanRegisterWithPhoneAfterSettingTheRegistrationUser
{
    // given
    NSString *phone = @"+49123456789000";
    NSString *code = @"123456";
    
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithPhoneNumber:phone phoneVerificationCode:code];
    
    // when
    [self.sut prepareForRegistrationOfUser:regUser];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRegisterWithPhone);
    XCTAssertEqualObjects(self.sut.registrationUser.phoneNumber, phone);
    XCTAssertEqualObjects(self.sut.registrationUser.phoneVerificationCode, code);
}

- (void)testThatItCanRegisterWithEmailAfterSettingTheRegistrationUser
{
    // given
    NSString *email = @"foo@foo.bar";
    NSString *pass = @"123456xcxc";
    
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithEmail:email password:pass];
    
    // when
    [self.sut prepareForRegistrationOfUser:regUser];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRegisterWithEmail);
    XCTAssertEqualObjects(self.sut.registrationUser.emailAddress, email);
    XCTAssertEqualObjects(self.sut.registrationUser.password, pass);
}

- (void)testThatItCanRegisterWithEmailInvitationAfterSettingTheRegistrationUser
{
    // given
    NSString *email = @"foo@foo.bar";
    NSString *pass = @"123456xcxc";
    NSString *code = @"12392sdksld";
    
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithEmail:email password:pass invitationCode:code];
    
    // when
    [self.sut prepareForRegistrationOfUser:regUser];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRegisterWithEmail);
    XCTAssertEqualObjects(self.sut.registrationUser.emailAddress, email);
    XCTAssertEqualObjects(self.sut.registrationUser.password, pass);
    XCTAssertEqualObjects(self.sut.registrationUser.invitationCode, code);
}

- (void)testThatItCanRegisterWithPhoneInvitationAfterSettingTheRegistrationUser
{
    // given
    NSString *phone = @"+4923238293822";
    NSString *code = @"12392sdksld";
    
    ZMCompleteRegistrationUser *regUser = [ZMCompleteRegistrationUser registrationUserWithPhoneNumber:phone invitationCode:code];
    
    // when
    [self.sut prepareForRegistrationOfUser:regUser];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRegisterWithPhone);
    XCTAssertEqualObjects(self.sut.registrationUser.phoneNumber, phone);
    XCTAssertEqualObjects(self.sut.registrationUser.invitationCode, code);
}

- (void)testThatItCanLoginWithEmailAfterSettingCredentials
{
    // given
    NSString *email = @"foo@foo.bar";
    NSString *pass = @"123456xcxc";
    
    ZMCredentials *credentials = [ZMEmailCredentials credentialsWithEmail:email password:pass];
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials];
    }];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseLoginWithEmail);
    XCTAssertEqual(self.sut.loginCredentials, credentials);
}

- (void)testThatItCanLoginWithPhoneAfterSettingCredentials
{
    // given
    NSString *phone = @"+4912345678900";
    NSString *code = @"123456";
    
    ZMCredentials *credentials = [ZMPhoneCredentials credentialsWithPhoneNumber:phone verificationCode:code];
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials];
    }];
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseLoginWithPhone);
    XCTAssertEqual(self.sut.loginCredentials, credentials);

}

- (void)testThatItCanRequestPhoneVerificationCodeForRegistrationAfterRequestingTheCode
{
    // given
    NSString *phone = @"+49(123)45678900";
    NSString *normalizedPhone = [phone copy];
    [ZMPhoneNumberValidator validateValue:&normalizedPhone error:nil];
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForRegistration:phone];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRequestPhoneVerificationCodeForRegistration);
    XCTAssertEqualObjects(self.sut.registrationPhoneNumberThatNeedsAValidationCode, normalizedPhone);
    XCTAssertNotEqualObjects(normalizedPhone, phone, @"Should not have changed original phone");
}

- (void)testThatItCanRequestPhoneVerificationCodeForLoginAfterRequestingTheCode
{
    // given
    NSString *phone = @"+49(123)45678900";
    NSString *normalizedPhone = [phone copy];
    [ZMPhoneNumberValidator validateValue:&normalizedPhone error:nil];
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForLogin:phone];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseRequestPhoneVerificationCodeForLogin);
    XCTAssertEqualObjects(self.sut.loginPhoneNumberThatNeedsAValidationCode, normalizedPhone);
    XCTAssertNotEqualObjects(normalizedPhone, phone, @"Should not have changed original phone");
}

- (void)testThatItCanVerifyPhoneCodeForRegistrationAfterSettingRegistrationCode
{
    // given
    NSString *phone = @"+49(123)45678900";
    NSString *code = @"123456";
    ZMPhoneCredentials *credentials = [ZMPhoneCredentials credentialsWithPhoneNumber:phone verificationCode:code];
    
    // when
    [self.sut prepareForRegistrationPhoneVerificationWithCredentials:credentials];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseVerifyPhoneForRegistration);
    XCTAssertEqualObjects(self.sut.registrationPhoneValidationCredentials, credentials);
}

@end


@implementation ZMAuthenticationStatusTests (CompletionMethods)

- (void)testThatItTriesToLogInAfterCompletingEmailRegistration
{
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, NSError *error) {
        ZM_STRONG(self);
        XCTAssertNil(error);
        XCTAssertEqual(type, ZMRegistrationNotificationEmailVerificationDidSucceed);
        [expectation fulfill];
    };
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForRegistrationOfUser:[ZMCompleteRegistrationUser registrationUserWithEmail:email password:password]];
        [self.sut didCompleteRegistrationSuccessfullyWithResponse:nil]; // We don't care about response in here
    }];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseLoginWithEmail);
    XCTAssertNil(self.sut.registrationUser);
    XCTAssertEqualObjects(self.sut.loginCredentials.email, email);
    XCTAssertEqualObjects(self.sut.loginCredentials.password, password);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0.5]);
}

- (void)testThatItWaitsForEmailValidationWhenRegistrationFailsBecauseOfDuplicatedEmail
{
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    
    NSError *expectedError = [NSError userSessionErrorWithErrorCode:ZMUserSessionEmailIsAlreadyRegistered userInfo:@{}];
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(error.code, expectedError.code);
        XCTAssertEqual(type, ZMUserSessionEmailIsAlreadyRegistered);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRegistrationOfUser:[ZMCompleteRegistrationUser registrationUserWithEmail:email password:password]];
    [self.sut didFailRegistrationWithDuplicatedEmail];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.registrationUser);
    XCTAssertNil(self.sut.loginCredentials);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenRegistrationFails
{
    // expect
    NSError *expectedError = [NSError userSessionErrorWithErrorCode:ZMUserSessionInvalidPhoneNumber userInfo:nil];
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(error, expectedError);
        XCTAssertEqual(type, ZMRegistrationNotificationRegistrationDidFail);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRegistrationOfUser:[ZMCompleteRegistrationUser registrationUserWithEmail:@"Foo@example.com" password:@"#@$123"]];
    [self.sut didFailRegistrationForOtherReasons:expectedError];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.registrationUser);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenCompletingTheRequestForPhoneRegistrationCode
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, __unused NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(type, ZMRegistrationNotificationPhoneNumberVerificationCodeRequestDidSucceed);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForRegistration:@"+4912345678"];
    [self.sut didCompleteRequestForPhoneRegistrationCodeSuccessfully];
    
    // then
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.registrationPhoneNumberThatNeedsAValidationCode);
}

- (void)testThatItResetsWhenFailingTheRequestForPhoneRegistrationCode
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, __unused NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(type, ZMRegistrationNotificationPhoneNumberVerificationCodeRequestDidFail);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForRegistration:@"+4912345678"];
    [self.sut didFailRequestForPhoneRegistrationCode:[NSError userSessionErrorWithErrorCode:ZMUserSessionInvalidCredentials userInfo:nil]];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.registrationPhoneNumberThatNeedsAValidationCode);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);

}

- (void)testThatItResetsWhenCompletingTheRequestForPhoneLoginCode
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, __unused NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcLoginCodeRequestDidSucceed);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForLogin:@"+4912345678"];
    [self.sut didCompleteRequestForLoginCodeSuccessfully];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginPhoneNumberThatNeedsAValidationCode);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenFailingTheRequestForPhoneLoginCode
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    NSError *expectedError = [NSError userSessionErrorWithErrorCode:ZMUserSessionInvalidPhoneNumber userInfo:nil];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcLoginCodeRequestDidFail);
        XCTAssertEqual(error, expectedError);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRequestingPhoneVerificationCodeForLogin:@"+4912345678"];
    [self.sut didFailRequestForLoginCode:expectedError];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginPhoneNumberThatNeedsAValidationCode);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenCompletingPhoneVerification
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, __unused NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(type, ZMRegistrationNotificationPhoneNumberVerificationDidSucceed);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRegistrationPhoneVerificationWithCredentials:[ZMPhoneCredentials credentialsWithPhoneNumber:@"+4912345678900" verificationCode:@"123456"]];
    [self.sut didCompletePhoneVerificationSuccessfully];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginPhoneNumberThatNeedsAValidationCode);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);

}

- (void)testThatItResetsWhenFailingPhoneVerificationNotForDuplicatedPhone
{
    // expect
    NSError *expectedError = [NSError userSessionErrorWithErrorCode:ZMUserSessionPhoneNumberIsAlreadyRegistered userInfo:nil];
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.registrationCallback = ^(ZMUserSessionRegistrationNotificationType type, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(type, ZMRegistrationNotificationPhoneNumberVerificationDidFail);
        XCTAssertEqual(error, expectedError);
        [expectation fulfill];
    };
    
    // when
    [self.sut prepareForRegistrationPhoneVerificationWithCredentials:[ZMPhoneCredentials credentialsWithPhoneNumber:@"+4912345678900" verificationCode:@"123456"]];
    [self.sut didFailPhoneVerificationForRegistration:expectedError];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginPhoneNumberThatNeedsAValidationCode);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenFailingEmailLogin
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcAuthenticationDidFail);
        XCTAssertEqualObjects(error, [NSError userSessionErrorWithErrorCode:ZMUserSessionInvalidCredentials userInfo:nil]);
        [expectation fulfill];
    };
    
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:email password:password]];
    }];
    [self.sut didFailLoginWithEmail:YES];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginCredentials);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItWaitsForEmailWhenFailingLoginBecauseOfPendingValidaton
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcAuthenticationDidFail);
        XCTAssertEqualObjects(error, [NSError userSessionErrorWithErrorCode:ZMUserSessionAccountIsPendingActivation userInfo:nil]);
        [expectation fulfill];
    };
    
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    ZMCredentials *credentials = [ZMEmailCredentials credentialsWithEmail:email password:password];
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials];
    }];
    [self.sut didFailLoginWithEmailBecausePendingValidation];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseWaitingForEmailVerification);
    XCTAssertEqualObjects(self.sut.loginCredentials, credentials);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenFailingPhoneLogin
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcAuthenticationDidFail);
        XCTAssertEqualObjects(error, [NSError userSessionErrorWithErrorCode:ZMUserSessionInvalidCredentials userInfo:nil]);
        [expectation fulfill];
    };
    
    // given
    NSString *phone = @"+49123456789000";
    NSString *code = @"324543";
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMPhoneCredentials credentialsWithPhoneNumber:phone verificationCode:code]];
    }];
    [self.sut didFailLoginWithPhone:YES];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginCredentials);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItResetsWhenTimingOutLoginWithTheSameCredentials
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcAuthenticationDidFail);
        XCTAssertEqualObjects(error, [NSError userSessionErrorWithErrorCode:ZMUserSessionNetworkError userInfo:nil]);
        [expectation fulfill];
    };
    
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    ZMCredentials *credentials = [ZMEmailCredentials credentialsWithEmail:email password:password];
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials];
    }];
    [self.sut didTimeoutLoginForCredentials:credentials];
    WaitForAllGroupsToBeEmpty(0.5);
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseUnauthenticated);
    XCTAssertNil(self.sut.loginCredentials);
    
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItDoesNotResetsWhenTimingOutLoginWithDifferentCredentials
{
    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    ZMCredentials *credentials1 = [ZMEmailCredentials credentialsWithEmail:email password:password];
    ZMCredentials *credentials2 = [ZMPhoneCredentials credentialsWithPhoneNumber:@"+4912345678900" verificationCode:@"123456"];
    
    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials1];
    }];
    [self.sut didTimeoutLoginForCredentials:credentials2];
    
    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseLoginWithEmail);
    XCTAssertEqualObjects(self.sut.loginCredentials, credentials1);
}

- (void)testThatItWaitsForBackupImportAfterLoggingInWithEmail
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcReadyToImportBackupNewAccount);
        XCTAssertNil(error);
        [expectation fulfill];
    };

    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";

    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:email password:password]];
    }];
    [self.sut loginSucceededWithResponse:nil];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseWaitingToImportBackup);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
}

- (void)testThatItAsksForUserInfoParserIfAccountForBackupExists
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcReadyToImportBackupExistingAccount);
        XCTAssertNil(error);
        [expectation fulfill];
    };

    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];
    self.userInfoParser.existingAccounts = [self.userInfoParser.existingAccounts arrayByAddingObject:response];

    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:email password:password]];
    }];

    [self.sut loginSucceededWithResponse:response];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseWaitingToImportBackup);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
    XCTAssertEqual(self.userInfoParser.accountExistsLocallyCalled, 1);
}

- (void)testThatItExtractsUserIdentifierFromLoginResponse
{
    // expect
    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        XCTAssertEqual(event, PreLoginAuthenticationEventObjcReadyToImportBackupNewAccount);
        XCTAssertNil(error);
        [expectation fulfill];
    };

    // given
    NSString *email = @"gfdgfgdfg@fds.sgf";
    NSString *password = @"#$4tewt343$";
    NSUUID *userID = [NSUUID createUUID];
    self.userInfoParser.userId = userID;
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];

    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:email password:password]];
    }];

    [self.sut loginSucceededWithResponse:response];
    WaitForAllGroupsToBeEmpty(0.5);

    // then
    XCTAssertEqual(self.sut.currentPhase, ZMAuthenticationPhaseWaitingToImportBackup);
    XCTAssertTrue([self waitForCustomExpectationsWithTimeout:0]);
    XCTAssertEqualObjects(self.sut.authenticatedUserIdentifier, userID);
    XCTAssertEqual(self.userInfoParser.userIdentifierCalled, 1);

}

@end


@implementation ZMAuthenticationStatusTests (CredentialProvider)

- (void)testThatItDoesNotReturnCredentialsIfItIsNotLoggedIn
{
    // given
    [self.sut setAuthenticationCookieData:nil];
    
    // then
    XCTAssertNil(self.sut.emailCredentials);
}

- (void)testThatItReturnsCredentialsIfLoggedIn
{
    // given
    [self.sut setAuthenticationCookieData:[NSData data]];
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:@"foo@example.com" password:@"boo"]];
    }];

    // then
    XCTAssertNotNil(self.sut.emailCredentials);
}

- (void)testThatItClearsCredentialsIfInPhaseAuthenticated
{
    // given
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:@"foo@example.com" password:@"boo"]];
    }];
    [self.sut setAuthenticationCookieData:[NSData data]];
    
    XCTAssertNotNil(self.sut.loginCredentials);

    // when
    [self.sut credentialsMayBeCleared];
    
    // then
    XCTAssertNil(self.sut.loginCredentials);
}

- (void)testThatItDoesNotClearCredentialsIfNotAuthenticated
{
    // given
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:[ZMEmailCredentials credentialsWithEmail:@"foo@example.com" password:@"boo"]];
    }];
    
    XCTAssertNotNil(self.sut.loginCredentials);
    
    // when
    [self.sut credentialsMayBeCleared];
    
    // then
    XCTAssertNotNil(self.sut.loginCredentials);
}

@end

@implementation ZMAuthenticationStatusTests (UserInfoParser)

- (void)testThatItCallsUserInfoParserAfterSuccessfulAuthentication
{
    // given
    NSString *email = @"foo@foo.bar";
    NSString *pass = @"123456xcxc";

    ZMCredentials *credentials = [ZMEmailCredentials credentialsWithEmail:email password:pass];
    ZMTransportResponse *response = [ZMTransportResponse responseWithPayload:nil HTTPStatus:200 transportSessionError:nil];

    XCTestExpectation *expectation = [self expectationWithDescription:@"notification"];
    ZM_WEAK(self);
    self.authenticationCallback = ^(enum PreLoginAuthenticationEventObjc event, NSError *error) {
        ZM_STRONG(self);
        if (!(event == PreLoginAuthenticationEventObjcReadyToImportBackupNewAccount ||
              event == PreLoginAuthenticationEventObjcAuthenticationDidSucceed)) {
            XCTFail(@"Unexpected event");
        }
        XCTAssertEqual(error, nil);
        [expectation fulfill];
    };

    // when
    [self performPretendingUiMocIsSyncMoc:^{
        [self.sut prepareForLoginWithCredentials:credentials];
        [self.sut loginSucceededWithResponse:response];
        [self.sut continueAfterBackupImportStep];
    }];

    // then
    XCTAssertEqual(self.userInfoParser.parseCallCount, 1);
    XCTAssertEqual(self.userInfoParser.parsedResponses.firstObject, response);
}

@end


@implementation ZMAuthenticationStatusTests (CookieLabel)

- (void)testThatItReturnsTheSameCookieLabel
{
    // when
    CookieLabel *cookieLabel1 = CookieLabel.current;
    CookieLabel *cookieLabel2 = CookieLabel.current;
    
    // then
    XCTAssertNotNil(cookieLabel1);
    XCTAssertEqualObjects(cookieLabel1, cookieLabel2);
}

@end

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
@import WireUtilities;
@import WireDataModel;

#import "ZMAuthenticationStatus.h"
#import "ZMCredentials+Internal.h"
#import "NSError+ZMUserSession.h"
#import "NSError+ZMUserSessionInternal.h"
#import "ZMUserSessionRegistrationNotification.h"
#import <WireSyncEngine/WireSyncEngine-Swift.h>
#import "ZMAuthenticationStatus_Internal.h"


static NSString *const TimerInfoOriginalCredentialsKey = @"credentials";
static NSString *const AuthenticationCenterDataChangeNotificationName = @"ZMAuthenticationStatusDataChangeNotificationName";
NSTimeInterval DebugLoginFailureTimerOverride = 0;

static NSString* ZMLogTag ZM_UNUSED = @"Authentication";

@interface ZMAuthenticationStatus ()

@property (nonatomic, weak) id<UserInfoParser> userInfoParser;
@property (nonatomic, strong) ZMTransportResponse *authenticationResponse;

@end

@implementation ZMAuthenticationStatus

- (instancetype)initWithGroupQueue:(id<ZMSGroupQueue>)groupQueue userInfoParser:(nullable id<UserInfoParser>)userInfoParser {
    self = [super init];
    if(self) {
        self.groupQueue = groupQueue;
        self.isWaitingForLogin = !self.isLoggedIn;
        self.userInfoParser = userInfoParser;
    }
    return self;
}

- (void)dealloc
{
    [self stopLoginTimer];
}

- (ZMCredentials *)loginCredentials
{
    return self.internalLoginCredentials;
}

- (NSUUID *)authenticatedUserIdentifier
{
    if (self.authenticationResponse != nil) {
        return [self.userInfoParser userIdentifierFromResponse:self.authenticationResponse];
    }
    return nil;
}

- (void)resetLoginAndRegistrationStatus
{
    [self stopLoginTimer];
    
    self.registrationPhoneNumberThatNeedsAValidationCode = nil;
    self.loginPhoneNumberThatNeedsAValidationCode = nil;

    self.internalLoginCredentials = nil;
    self.registrationPhoneValidationCredentials = nil;
    self.registrationUser = nil;

    self.isWaitingForEmailVerification = NO;
    self.isWaitingForBackupImport = NO;
}

- (void)setRegistrationUser:(ZMCompleteRegistrationUser *)registrationUser
{
    if(self.internalRegistrationUser != registrationUser) {
        self.internalRegistrationUser = registrationUser;
        if (self.internalRegistrationUser.emailAddress != nil) {
            [ZMPersistentCookieStorage setCookiesPolicy:NSHTTPCookieAcceptPolicyNever];
        }
        else {
            [ZMPersistentCookieStorage setCookiesPolicy:NSHTTPCookieAcceptPolicyAlways];
        }
        [[[NotificationInContext alloc] initWithName:AuthenticationCenterDataChangeNotificationName
                                             context:self object:nil userInfo:nil] post];
    }
}

- (ZMCompleteRegistrationUser *)registrationUser
{
    return self.internalRegistrationUser;
}

- (void)setLoginCredentials:(ZMCredentials *)credentials
{
    if(credentials != self.internalLoginCredentials) {
        self.internalLoginCredentials = credentials;
        [ZMPersistentCookieStorage setCookiesPolicy:NSHTTPCookieAcceptPolicyAlways];
        [[[NotificationInContext alloc] initWithName:AuthenticationCenterDataChangeNotificationName
                                             context:self object:nil userInfo:nil] post];
    }
}

- (id)addAuthenticationCenterObserver:(id<ZMAuthenticationStatusObserver>)observer;
{
    ZM_WEAK(observer);
    return [NotificationInContext addObserverWithName:AuthenticationCenterDataChangeNotificationName
                                       context:self
                                        object:nil
                                         queue:nil
                                         using:^(NotificationInContext * notification __unused) {
                                             ZM_STRONG(observer);
                                             [observer didChangeAuthenticationData];
     }];
}

- (ZMAuthenticationPhase)currentPhase
{
    if(self.isLoggedIn) {
        return ZMAuthenticationPhaseAuthenticated;
    }
    if(self.isWaitingForBackupImport) {
        return ZMAuthenticationPhaseWaitingToImportBackup;
    }
    if(self.isWaitingForEmailVerification) {
        return ZMAuthenticationPhaseWaitingForEmailVerification;
    }
    if(self.registrationUser.emailAddress != nil) {
        return ZMAuthenticationPhaseRegisterWithEmail;
    }
    if(self.registrationUser.phoneVerificationCode != nil || self.registrationUser.invitationCode != nil) {
        return ZMAuthenticationPhaseRegisterWithPhone;
    }
    if(self.internalLoginCredentials.credentialWithEmail && self.isWaitingForLogin) {
        return ZMAuthenticationPhaseLoginWithEmail;
    }
    if(self.internalLoginCredentials.credentialWithPhone && self.isWaitingForLogin) {
        return ZMAuthenticationPhaseLoginWithPhone;
    }
    if(self.registrationPhoneNumberThatNeedsAValidationCode != nil) {
        return ZMAuthenticationPhaseRequestPhoneVerificationCodeForRegistration;
    }
    if(self.loginPhoneNumberThatNeedsAValidationCode != nil) {
        return ZMAuthenticationPhaseRequestPhoneVerificationCodeForLogin;
    }
    if(self.registrationPhoneValidationCredentials != nil) {
        return ZMAuthenticationPhaseVerifyPhoneForRegistration;
    }
    return ZMAuthenticationPhaseUnauthenticated;
}

- (BOOL)needsCredentialsToLogin
{
    return !self.isLoggedIn && self.loginCredentials == nil;
}

- (BOOL)isLoggedIn
{
    return nil != self.authenticationCookieData;
}

- (void)startLoginTimer
{
    [self stopLoginTimer];
    self.loginTimer = [ZMTimer timerWithTarget:self];
    self.loginTimer.userInfo = @{ TimerInfoOriginalCredentialsKey : self.loginCredentials };
    [self.loginTimer fireAfterTimeInterval:(DebugLoginFailureTimerOverride > 0 ?: 60 )];
}

- (void)stopLoginTimer
{
    [self.loginTimer cancel];
    self.loginTimer = nil;
}

- (void)timerDidFire:(ZMTimer *)timer
{
    [self.groupQueue performGroupedBlock:^{
        [self didTimeoutLoginForCredentials:timer.userInfo[TimerInfoOriginalCredentialsKey]];
    }];
}

- (void)prepareForLoginWithCredentials:(ZMCredentials *)credentials
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.authenticationCookieData = nil;
    [self resetLoginAndRegistrationStatus];
    self.loginCredentials = credentials;
    self.isWaitingForLogin = YES;
    [self startLoginTimer];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)prepareForRegistrationOfUser:(ZMCompleteRegistrationUser *)user
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.authenticationCookieData = nil;
    self.isWaitingForLogin = YES;
    [self resetLoginAndRegistrationStatus];
    self.registrationUser = user;
}

- (void)continueAfterBackupImportStep
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self continueAuthenticationWithResponse:self.authenticationResponse];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)continueAuthenticationWithResponse:(ZMTransportResponse *)response
{
    self.isWaitingForBackupImport = NO;
    if (self.isWaitingForLogin) {
        self.isWaitingForLogin = NO;
    }
    [self notifyAuthenticationDidSucceed];
    // There might be some authentication errors after parsing the response (e.g. too many accounts)
    [self.userInfoParser parseUserInfoFromResponse:response];
}

- (void)prepareForRequestingPhoneVerificationCodeForRegistration:(NSString *)phone
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMPhoneNumberValidator validateValue:&phone error:nil];
    self.registrationPhoneNumberThatNeedsAValidationCode = phone;
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)prepareForRequestingPhoneVerificationCodeForLogin:(NSString *)phone;
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMPhoneNumberValidator validateValue:&phone error:nil];
    self.loginPhoneNumberThatNeedsAValidationCode = phone;
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)prepareForRegistrationPhoneVerificationWithCredentials:(ZMPhoneCredentials *)phoneCredentials
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    self.registrationPhoneValidationCredentials = phoneCredentials;
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailRequestForPhoneRegistrationCode:(NSError *)error
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMUserSessionRegistrationNotification notifyPhoneNumberVerificationCodeRequestDidFail:error context:self];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didCompleteRegistrationSuccessfullyWithResponse:(ZMTransportResponse *)response
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.completedRegistration = YES;
    
    if (self.currentPhase == ZMAuthenticationPhaseRegisterWithEmail) {
        ZMCredentials *credentials = [ZMEmailCredentials credentialsWithEmail:self.registrationUser.emailAddress password:self.registrationUser.password];
        //we need to set credentials first cause that will trigger notification and check for current state but we need to know that we are going from email registration to login attempts
        self.loginCredentials = credentials;
        self.registrationUser = nil;
        [ZMUserSessionRegistrationNotification notifyEmailVerificationDidSucceedInContext:self];
    } else if (self.currentPhase == ZMAuthenticationPhaseAuthenticated) {
        [self continueAuthenticationWithResponse:response];
    } else if (self.currentPhase == ZMAuthenticationPhaseRegisterWithPhone) {
        [self continueAuthenticationWithResponse:response];
    }

    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailRegistrationWithDuplicatedEmail {
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMUserSessionRegistrationNotification notifyRegistrationDidFail:[NSError userSessionErrorWithErrorCode:ZMUserSessionEmailIsAlreadyRegistered userInfo:@{}] context:self];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailRegistrationForOtherReasons:(NSError *)error;
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMUserSessionRegistrationNotification notifyRegistrationDidFail:error context:self];
}

- (void)didTimeoutLoginForCredentials:(ZMCredentials *)credentials
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    if((self.currentPhase == ZMAuthenticationPhaseLoginWithEmail || self.currentPhase == ZMAuthenticationPhaseLoginWithPhone)
       && self.loginCredentials == credentials)
    {
        self.loginCredentials = nil;
        [self notifyAuthenticationDidFail:[NSError userSessionErrorWithErrorCode:ZMUserSessionNetworkError userInfo:nil]];
    }
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didCompletePhoneVerificationSuccessfully
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMUserSessionRegistrationNotification notifyPhoneNumberVerificationDidSucceedInContext:self];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailPhoneVerificationForRegistration:(NSError *)error
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    [ZMUserSessionRegistrationNotification notifyPhoneNumberVerificationDidFail:error context:self];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)loginSucceededWithResponse:(ZMTransportResponse *)response
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    if (self.completedRegistration) {
        [self continueAuthenticationWithResponse:response];
    } else {
        self.authenticationResponse = response;
        self.isWaitingForBackupImport = YES;
        BOOL existingAccount = [self.userInfoParser accountExistsLocallyFromResponse:response];
        [self notifyAuthenticationReadyToImportBackupWithExistingAccount:existingAccount];
    }
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailLoginWithPhone:(BOOL)invalidCredentials
{
    ZMLogDebug(@"%@ invalid credentials: %d", NSStringFromSelector(_cmd), invalidCredentials);
    [self resetLoginAndRegistrationStatus];
    
    NSError *error = [NSError userSessionErrorWithErrorCode:(invalidCredentials ? ZMUserSessionInvalidCredentials : ZMUserSessionUnknownError) userInfo:nil];
    [self notifyAuthenticationDidFail:error];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailLoginWithEmail:(BOOL)invalidCredentials
{
    ZMLogDebug(@"%@ invalid credentials: %d", NSStringFromSelector(_cmd), invalidCredentials);
    
    NSError *error = [NSError userSessionErrorWithErrorCode:(invalidCredentials ? ZMUserSessionInvalidCredentials : ZMUserSessionUnknownError) userInfo:nil];
    [self notifyAuthenticationDidFail:error];
    [self resetLoginAndRegistrationStatus];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailLoginWithEmailBecausePendingValidation
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.isWaitingForEmailVerification = YES;
    NSError *error = [NSError userSessionErrorWithErrorCode:ZMUserSessionAccountIsPendingActivation userInfo:nil];
    [self notifyAuthenticationDidFail:error];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailLoginBecauseAccountSuspended
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    NSError *error = [NSError userSessionErrorWithErrorCode:ZMUserSessionAccountSuspended userInfo:nil];
    [self notifyAuthenticationDidFail:error];
    [self resetLoginAndRegistrationStatus];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)cancelWaitingForEmailVerification
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self resetLoginAndRegistrationStatus];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didCompleteRequestForPhoneRegistrationCodeSuccessfully;
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.registrationPhoneNumberThatNeedsAValidationCode = nil;
    [ZMUserSessionRegistrationNotification notifyPhoneNumberVerificationCodeRequestDidSucceedInContext:self];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)setAuthenticationCookieData:(NSData *)data;
{
    ZMLogDebug(@"Setting cookie data: %@", @(data.length));
    _authenticationCookieData = data;
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didCompleteRequestForLoginCodeSuccessfully
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    [self notifyLoginCodeRequestDidSucceed];
    self.loginPhoneNumberThatNeedsAValidationCode = nil;
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

- (void)didFailRequestForLoginCode:(NSError *)error;
{
    ZMLogDebug(@"%@", NSStringFromSelector(_cmd));
    self.loginPhoneNumberThatNeedsAValidationCode = nil;
    [self notifyLoginCodeRequestDidFail:error];
    ZMLogDebug(@"current phase: %lu", (unsigned long)self.currentPhase);
}

@end


@implementation ZMAuthenticationStatus (CredentialProvider)

- (void)credentialsMayBeCleared
{
    if (self.currentPhase == ZMAuthenticationPhaseAuthenticated) {
        [self resetLoginAndRegistrationStatus];
    }
}

- (ZMEmailCredentials *)emailCredentials
{
    if (self.loginCredentials.credentialWithEmail) {
        return [ZMEmailCredentials credentialsWithEmail:self.loginCredentials.email
                                               password:self.loginCredentials.password];
    }
    return nil;
}

@end


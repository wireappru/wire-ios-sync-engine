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


#import <WireSyncEngine/ZMUserSession.h>

@import UIKit;

@protocol ZMApplication;

@interface ZMUserSession (ZMBackground)

/// Process the payload of the remote notification. This may cause a @c UILocalNotification to be displayed.
- (void)application:(id<ZMApplication>)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler;

/// Process the local notifications.
- (void)application:(id<ZMApplication>)application didReceiveLocalNotification:(UILocalNotification *)notification;

/// Notifies the receiver about callbacks from a local notification.
- (void)application:(id<ZMApplication>)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)notification responseInfo:(NSDictionary *)responseInfo completionHandler:(void(^)(void))completionHandler;

/// Causes the user session to update its state from the backend.
- (void)application:(id<ZMApplication>)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler;

/// Lets the user session process event for a background URL session it has set up.
- (void)application:(id<ZMApplication>)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler;

/// Lets the user session process local and remote notifications contained in the launch options;
- (void)application:(id<ZMApplication>)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions;

/// Calls registerUserNotificationSettings on application
- (void)setupPushNotificationsForApplication:(id<ZMApplication>)application;

- (void)applicationDidEnterBackground:(NSNotification *)note;
- (void)applicationWillEnterForeground:(NSNotification *)note;

@end


// PRIVATE
@interface ZMUserSession (PushToken)

- (void)setPushToken:(NSData *)deviceToken;
- (void)setPushKitToken:(NSData *)deviceToken;

/// deletes the pushKit token from the backend
- (void)deletePushKitToken;

- (BOOL)isAuthenticated;

@end

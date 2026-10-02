//
//  GBLaunchAtLogin.h
//  GBLaunchAtLogin
//
//  Created by Luka Mirosevic on 04/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface GBLaunchAtLogin : NSObject

+(BOOL)isLoginItem;
/// YES when the app is registered but the user switched it off in System
/// Settings → General → Login Items, so it won't launch until they re-enable it.
+(BOOL)loginItemRequiresApproval;
+(BOOL)addAppAsLoginItem:(NSError **)error;
+(BOOL)removeAppFromLoginItems:(NSError **)error;
/// Opens System Settings → General → Login Items.
+(void)openLoginItemsSettings;

@end

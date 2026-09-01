//
//  GBLaunchAtLogin.m
//  GBLaunchAtLogin
//
//  Created by Luka Mirosevic on 04/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//
//  Rewritten around SMAppService (macOS 13+), which is the app's deployment
//  floor. The original implementation used the deprecated LSSharedFileList API.

#import "GBLaunchAtLogin.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation GBLaunchAtLogin

+(BOOL)isLoginItem {
    return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}

+(void)addAppAsLoginItem {
    NSError *error = nil;
    if (![[SMAppService mainAppService] registerAndReturnError:&error]) {
        NSLog(@"Failed to register login item: %@", error);
    }
}

+(void)removeAppFromLoginItems {
    NSError *error = nil;
    if (![[SMAppService mainAppService] unregisterAndReturnError:&error]) {
        NSLog(@"Failed to unregister login item: %@", error);
    }
}

@end

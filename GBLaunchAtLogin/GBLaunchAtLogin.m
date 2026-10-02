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

+(BOOL)loginItemRequiresApproval {
    return [SMAppService mainAppService].status == SMAppServiceStatusRequiresApproval;
}

+(BOOL)addAppAsLoginItem:(NSError **)error {
    return [[SMAppService mainAppService] registerAndReturnError:error];
}

+(BOOL)removeAppFromLoginItems:(NSError **)error {
    return [[SMAppService mainAppService] unregisterAndReturnError:error];
}

+(void)openLoginItemsSettings {
    [SMAppService openSystemSettingsLoginItems];
}

@end

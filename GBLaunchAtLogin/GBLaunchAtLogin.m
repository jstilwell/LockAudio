//
//  GBLaunchAtLogin.m
//  GBLaunchAtLogin
//
//  Created by Luka Mirosevic on 04/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//
//  Credit where credit is due, most of this code is borrowed from somewhere and is just being wrapped into a convenient ObjC library here. I don't remember the original source so if you are, or know, the author please let me know.

#import "GBLaunchAtLogin.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation GBLaunchAtLogin

+(BOOL)isLoginItem {
    // Use SMAppService on macOS 13+ for modern API
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        return service.status == SMAppServiceStatusEnabled;
    } else {
        // Fallback: Check if app exists in login items using AppleScript
        // This is a simplified check that works on macOS 11-12
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:
            [NSString stringWithFormat:@"tell application \"System Events\" to get the name of every login item"]];
        NSDictionary *error = nil;
        NSAppleEventDescriptor *result = [script executeAndReturnError:&error];

        if (!error && result) {
            NSString *appName = [[[NSBundle mainBundle] bundlePath] lastPathComponent];
            appName = [appName stringByDeletingPathExtension];
            NSString *resultString = [result stringValue];
            return [resultString containsString:appName];
        }

        return NO;
    }
}

+(void)addAppAsLoginItem {
    // Use SMAppService on macOS 13+ for modern API
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        [service registerAndReturnError:&error];
        if (error) {
            NSLog(@"Failed to register login item: %@", error);
        }
    } else {
        // Fallback: Use AppleScript for macOS 11-12
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        NSString *source = [NSString stringWithFormat:@"tell application \"System Events\" to make login item at end with properties {path:\"%@\", hidden:false}", appPath];
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *error = nil;
        [script executeAndReturnError:&error];
        if (error) {
            NSLog(@"Failed to add login item: %@", error);
        }
    }
}

+(void)removeAppFromLoginItems {
    // Use SMAppService on macOS 13+ for modern API
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        NSError *error = nil;
        [service unregisterAndReturnError:&error];
        if (error) {
            NSLog(@"Failed to unregister login item: %@", error);
        }
    } else {
        // Fallback: Use AppleScript for macOS 11-12
        NSString *appName = [[[NSBundle mainBundle] bundlePath] lastPathComponent];
        appName = [appName stringByDeletingPathExtension];
        NSString *source = [NSString stringWithFormat:@"tell application \"System Events\" to delete login item \"%@\"", appName];
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *error = nil;
        [script executeAndReturnError:&error];
        if (error) {
            NSLog(@"Failed to remove login item: %@", error);
        }
    }
}

@end

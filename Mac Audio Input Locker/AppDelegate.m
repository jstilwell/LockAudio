#import "AppDelegate.h"
#import "GBLaunchAtLogin.h"
#import <CoreAudio/CoreAudio.h>
#import <UserNotifications/UserNotifications.h>

@interface LinkCursorView : NSView
@end

@implementation LinkCursorView
- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

static NSString* const kPrefNotificationsEnabled = @"NotificationsEnabled";

// Minimum gap between forced-input notifications. Under this threshold we
// treat successive fires as CoreAudio churn (e.g. AirPods settling) and
// suppress; legitimate user-driven switches always exceed this easily.
static const NSTimeInterval kMinNotificationGap = 2.0;


@interface AppDelegate ( )
{
    BOOL paused;
    NSMenu* menu;
    NSStatusItem* statusItem;
    AudioDeviceID forcedInputID;
    NSString* forcedInputName;
    NSMutableDictionary* itemsToIDS;
    NSMenuItem *startupItem;
    NSMenuItem *notificationsItem;
    BOOL rebuildingMenu;
    NSDate* lastNotificationTime;
    BOOL notificationAuthGranted;
    NSWindow* aboutWindow;
}

@property (weak) IBOutlet NSWindow *window;
@property (strong) SPUStandardUpdaterController *updaterController;

@end


@implementation AppDelegate


OSStatus callbackFunction(  AudioObjectID inObjectID,
                            UInt32 inNumberAddresses,
                            const AudioObjectPropertyAddress inAddresses[],
                            void *inClientData)
{

    NSLog( @"default input device changed" );
    AppDelegate *delegate = (__bridge AppDelegate *)inClientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate listDevices];
    });

    return 0;
}


- ( void ) applicationDidFinishLaunching : ( NSNotification* ) aNotification
{
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];

    itemsToIDS = [ NSMutableDictionary dictionary ];
    lastNotificationTime = nil;
    notificationAuthGranted = NO;


    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs registerDefaults:@{
        kPrefNotificationsEnabled: @YES,
    }];

    NSInteger readenId = [prefs integerForKey: @"Device"];

    if (readenId == 0) {
        [prefs setInteger:UINT32_MAX forKey: @"Device"];
    }

    forcedInputID = (AudioDeviceID)readenId;
    forcedInputName = [prefs stringForKey: @"DeviceName"];

    [self requestNotificationAuthorizationIfNeeded];

    NSLog(@"Loaded device from UserDefaults: %d (name: %@)", forcedInputID, forcedInputName);

    NSImage* image = [ NSImage imageNamed : @"airpods-icon" ];
    [ image setTemplate : YES ];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.toolTip = @"Mac Audio Input Locker";
    statusItem.button.image = image;

    // add listener for detecting when input device is changed

    AudioObjectPropertyAddress inputDeviceAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &inputDeviceAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    // Listen for device list changes (devices added/removed)
    AudioObjectPropertyAddress devicesChangedAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &devicesChangedAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    // Set the runloop to the main runloop for CoreAudio callbacks
    AudioObjectPropertyAddress runLoopAddress = {
        kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    UInt32 size = sizeof(CFRunLoopRef);

    AudioObjectSetPropertyData(
        kAudioObjectSystemObject,
        &runLoopAddress,
        0,
        NULL,
        size,
        &runLoop);

    [ self listDevices ];

}


- ( void ) deviceSelected : ( NSMenuItem* ) item
{

    NSNumber* number = itemsToIDS[ item.title ];

    if ( number != nil )
    {

        AudioDeviceID newId = [ number unsignedIntValue ];

        NSLog( @"switching to new device : %u" , newId );

        forcedInputID = newId;

        forcedInputName = item.title;

        lastNotificationTime = nil;

        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        [prefs setInteger:newId forKey: @"Device"];
        [prefs setObject:forcedInputName forKey: @"DeviceName"];
        NSLog(@"Saved device to UserDefaults: %d (name: %@)", forcedInputID, forcedInputName);

        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 propertySize = sizeof(AudioDeviceID);
        AudioObjectSetPropertyData(
            kAudioObjectSystemObject,
            &propertyAddress,
            0,
            NULL,
            propertySize,
            &forcedInputID);

        // Rebuild menu to show updated selection
        dispatch_async(dispatch_get_main_queue(), ^{
            [self listDevices];
        });

    }

}


- ( void ) listDevices
{
    // Prevent recursive calls while rebuilding menu
    if (rebuildingMenu) {
        return;
    }
    rebuildingMenu = YES;

    NSDictionary *bundleInfo = [ [ NSBundle mainBundle] infoDictionary];
    NSString *versionString = [ NSString stringWithFormat : @"Version %@",
                               bundleInfo[ @"CFBundleShortVersionString" ] ];

    [ itemsToIDS removeAllObjects ];

    menu = [ [ NSMenu alloc ] init ];
    menu.delegate = self;
    [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem* item =  [ menu
            addItemWithTitle : NSLocalizedString(@"Pause", @"Pause")
            action : @selector(manualPause:)
            keyEquivalent : @"" ];

    if ( paused ) [ item setState : NSControlStateValueOn ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    [ menu addItemWithTitle : @"Forced input:" action : nil keyEquivalent : @"" ];

    UInt32 propertySize;

    // Get device count dynamically
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize);

    int numberOfDevices = ( propertySize / sizeof( AudioDeviceID ) );
    AudioDeviceID *dev_array = (AudioDeviceID *)malloc(propertySize);

    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize,
        dev_array);

    NSLog( @"devices found : %i" , numberOfDevices );

    if ( forcedInputID < UINT32_MAX )
    {

        char found = 0;

        for( int index = 0 ;
                 index < numberOfDevices ;
                 index++ )
        {

            if ( dev_array[ index] == forcedInputID ) found = 1;

        }

        if ( found == 0 )
        {
            NSLog( @"force input not found by ID, searching by name: %@", forcedInputName );

            // Device ID changed (e.g. reconnected) — try to find by name
            if ( forcedInputName != nil )
            {
                for ( int index = 0; index < numberOfDevices; index++ )
                {
                    char deviceName[256];
                    UInt32 nameSize = 256;

                    AudioObjectPropertyAddress nameAddr = {
                        kAudioDevicePropertyDeviceName,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };

                    AudioObjectGetPropertyData(
                        dev_array[index],
                        &nameAddr,
                        0,
                        NULL,
                        &nameSize,
                        deviceName);

                    NSString* nameStr = [ NSString stringWithUTF8String : deviceName ];

                    if ( [ nameStr isEqualToString : forcedInputName ] )
                    {
                        NSLog( @"force input recovered by name: %@ -> %u", nameStr, (unsigned int)dev_array[index] );
                        forcedInputID = dev_array[index];

                        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
                        [prefs setInteger:forcedInputID forKey: @"Device"];

                        found = 1;
                        break;
                    }
                }
            }

            if ( found == 0 )
            {
                NSLog( @"force input not found in device list" );
                // Don't reset — keep the name so we can recover later
            }
        }
        else NSLog( @"force input found in device list" );

    }
    else if ( forcedInputName != nil )
    {
        // forcedInputID is UINT32_MAX but we have a saved name — device was
        // previously disconnected, try to find it again
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            char deviceName[256];
            UInt32 nameSize = 256;

            AudioObjectPropertyAddress nameAddr = {
                kAudioDevicePropertyDeviceName,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };

            AudioObjectGetPropertyData(
                dev_array[index],
                &nameAddr,
                0,
                NULL,
                &nameSize,
                deviceName);

            NSString* nameStr = [ NSString stringWithUTF8String : deviceName ];

            if ( [ nameStr isEqualToString : forcedInputName ] )
            {
                NSLog( @"force input restored from saved name: %@ -> %u", nameStr, (unsigned int)dev_array[index] );
                forcedInputID = dev_array[index];

                NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
                [prefs setInteger:forcedInputID forKey: @"Device"];
                break;
            }
        }
    }


    for( int index = 0 ;
             index < numberOfDevices ;
             index++ )
    {

        AudioDeviceID oneDeviceID = dev_array[ index ];

        propertySize = 0;

        AudioObjectPropertyAddress streamsAddress = {
            kAudioDevicePropertyStreams,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        };

        AudioObjectGetPropertyDataSize(
            oneDeviceID,
            &streamsAddress,
            0,
            NULL,
            &propertySize);

        // if there are any input streams, then it is an input

        if ( propertySize > 0 )
        {

            // get name
            char deviceName[256];
            propertySize = 256;

            AudioObjectPropertyAddress nameAddress = {
                kAudioDevicePropertyDeviceName,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };

            AudioObjectGetPropertyData(
                oneDeviceID,
                &nameAddress,
                0,
                NULL,
                &propertySize,
                deviceName);

            NSLog( @"found input device : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );

            NSString* nameStr = [ NSString stringWithUTF8String : deviceName ];

            if ( [ [ nameStr lowercaseString ] containsString : @"built" ] && forcedInputID == UINT32_MAX && forcedInputName == nil )
            {

                // if there is no forced device yet and no saved preference, select "built-in" by default

                NSLog( @"setting forced device : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );

                forcedInputID = oneDeviceID;
                forcedInputName = nameStr;

                NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
                [prefs setObject:forcedInputName forKey: @"DeviceName"];

            }

            NSMenuItem* item = [ menu
                addItemWithTitle : [ NSString stringWithUTF8String : deviceName ]
                action : @selector(deviceSelected:)
                keyEquivalent : @"" ];

            if ( oneDeviceID == forcedInputID )
            {
                [ item setState : NSControlStateValueOn ];
                NSLog( @"setting device selected : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );
            }

            itemsToIDS[ nameStr ] = [ NSNumber numberWithUnsignedInt : oneDeviceID];

        }

    }

    free(dev_array);

    [ statusItem setMenu : menu ];

    // Force input device if needed (the callback will trigger another listDevices)

    AudioDeviceID deviceID = kAudioDeviceUnknown;
    propertySize = sizeof( deviceID );

    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &defaultInputAddress,
        0,
        NULL,
        &propertySize,
        &deviceID);

    NSLog( @"default input device is %u" , deviceID );

    if ( !paused && deviceID != forcedInputID )
    {

        NSLog( @"forcing input device for default : %u" , forcedInputID );

        NSArray *offendingNames = [itemsToIDS allKeysForObject:[NSNumber numberWithUnsignedInt:deviceID]];
        NSString *offendingName = offendingNames.firstObject;

        AudioObjectPropertyAddress forceInputAddress = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 forceSize = sizeof(AudioDeviceID);
        AudioObjectSetPropertyData(
            kAudioObjectSystemObject,
            &forceInputAddress,
            0,
            NULL,
            forceSize,
            &forcedInputID);

        [ self handleForceAppliedForDevice : forcedInputID
                                      name : forcedInputName
                            offendingName : offendingName ];

        // No need to dispatch listDevices here — the CoreAudio property
        // listener callback will fire and call listDevices for us.

    }

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    startupItem = [ menu
        addItemWithTitle : @"Open at login"
        action : @selector(toggleStartupItem)
        keyEquivalent : @"" ];

    notificationsItem = [ menu
        addItemWithTitle : @"Notify on forced input"
        action : @selector(toggleNotifications)
        keyEquivalent : @"" ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem *soundItem = [ menu
        addItemWithTitle : @"Sound settings…"
        action : @selector(openSoundSettings)
        keyEquivalent : @"" ];

    NSMenuItem *updateItem = [ menu
        addItemWithTitle : @"Check for updates"
        action : @selector(update)
        keyEquivalent : @"" ];

    NSMenuItem *aboutItem = [ menu
        addItemWithTitle : @"About"
        action : @selector(showAbout)
        keyEquivalent : @"" ];

    NSMenuItem *quitItem = [ menu
        addItemWithTitle : @"Quit"
        action : @selector(terminate)
        keyEquivalent : @"" ];

    if (@available(macOS 11.0, *)) {
        soundItem.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Sound settings"];
        updateItem.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:@"Check for updates"];
        aboutItem.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:@"About"];
        quitItem.image = [NSImage imageWithSystemSymbolName:@"xmark.circle" accessibilityDescription:@"Quit"];
    }

    rebuildingMenu = NO;

}

- ( void ) manualPause : ( NSMenuItem* ) item
{
    paused = !paused;
    [ self listDevices ];
}

- ( void ) terminate
{
    [ NSApp terminate : nil ];
}

- ( void ) update
{
    [self.updaterController checkForUpdates:nil];
}

- ( void ) openSoundSettings
{
    NSURL *url;
    if (@available(macOS 13.0, *)) {
        url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Sound-Settings.extension?Input"];
    } else {
        url = [NSURL fileURLWithPath:@"/System/Library/PreferencePanes/Sound.prefPane"];
    }
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- ( void ) showAbout
{
    if (aboutWindow == nil) {
        aboutWindow = [self buildAboutWindow];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [aboutWindow center];
    [aboutWindow makeKeyAndOrderFront:nil];
}

- (NSWindow *)buildAboutWindow
{
    CGFloat W = 460;
    CGFloat H = 330;
    NSRect frame = NSMakeRect(0, 0, W, H);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"";
    window.releasedWhenClosed = NO;
    window.titlebarAppearsTransparent = YES;

    NSView *content = window.contentView;

    // App icon
    CGFloat iconSize = 96;
    NSImage *iconImage = [NSImage imageNamed:@"AppIcon"];
    if (iconImage == nil) {
        iconImage = [NSImage imageNamed:@"airpods-icon"];
    }
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect((W - iconSize) / 2, H - 28 - iconSize, iconSize, iconSize)];
    iconView.image = iconImage;
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:iconView];

    // App name
    NSTextField *nameLabel = [NSTextField labelWithString:@"Mac Audio Input Locker"];
    nameLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    nameLabel.alignment = NSTextAlignmentCenter;
    nameLabel.frame = NSMakeRect(0, H - 160, W, 28);
    [content addSubview:nameLabel];

    // Version
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Version %@", version]];
    versionLabel.font = [NSFont systemFontOfSize:12];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    versionLabel.alignment = NSTextAlignmentCenter;
    versionLabel.frame = NSMakeRect(0, H - 182, W, 18);
    [content addSubview:versionLabel];

    // Links — URLs verbatim, centered
    NSArray *links = @[
        @[@"https://www.macaudioinputlocker.com", @"https://www.macaudioinputlocker.com"],
        @[@"https://github.com/jstilwell/MacAudioInputLocker", @"https://github.com/jstilwell/MacAudioInputLocker"],
        @[@"contact@macaudioinputlocker.com", @"mailto:contact@macaudioinputlocker.com"],
    ];
    CGFloat linksTop = H - 215;
    CGFloat linkHeight = 20;
    CGFloat linkSpacing = 2;
    for (NSUInteger i = 0; i < links.count; i++) {
        CGFloat y = linksTop - (i * (linkHeight + linkSpacing));
        NSView *linkView = [self linkViewWithTitle:links[i][0]
                                                url:links[i][1]
                                              frame:NSMakeRect(20, y, W - 40, linkHeight)];
        [content addSubview:linkView];
    }

    // Copyright
    NSString *copyright = [[NSBundle mainBundle] infoDictionary][@"NSHumanReadableCopyright"] ?: @"";
    NSTextField *copyrightLabel = [NSTextField labelWithString:copyright];
    copyrightLabel.font = [NSFont systemFontOfSize:11];
    copyrightLabel.textColor = [NSColor tertiaryLabelColor];
    copyrightLabel.alignment = NSTextAlignmentCenter;
    copyrightLabel.frame = NSMakeRect(20, 36, W - 40, 16);
    [content addSubview:copyrightLabel];

    return window;
}

- (NSView *)linkViewWithTitle:(NSString *)title url:(NSString *)url frame:(NSRect)frame
{
    NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
    centered.alignment = NSTextAlignmentCenter;

    NSAttributedString *attr = [[NSAttributedString alloc] initWithString:title
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor linkColor],
            NSLinkAttributeName: [NSURL URLWithString:url],
            NSParagraphStyleAttributeName: centered,
        }];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    field.editable = NO;
    field.bordered = NO;
    field.drawsBackground = NO;
    field.selectable = YES;
    field.allowsEditingTextAttributes = YES;
    field.alignment = NSTextAlignmentCenter;
    field.attributedStringValue = attr;

    LinkCursorView *wrapper = [[LinkCursorView alloc] initWithFrame:frame];
    [wrapper addSubview:field];
    return wrapper;
}

- (void)toggleStartupItem
{
    if ( [GBLaunchAtLogin isLoginItem] )
    {
        [GBLaunchAtLogin removeAppFromLoginItems];
    }
    else
    {
        [GBLaunchAtLogin addAppAsLoginItem];
    }

    [self updateStartupItemState];
}

- (void)updateStartupItemState
{
    [startupItem setState: [GBLaunchAtLogin isLoginItem] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)updateToggleStates
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [notificationsItem setState: [prefs boolForKey:kPrefNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)toggleNotifications
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![prefs boolForKey:kPrefNotificationsEnabled];
    [prefs setBool:enabled forKey:kPrefNotificationsEnabled];
    [self updateToggleStates];
    if (enabled) {
        [self requestNotificationAuthorizationIfNeeded];
    }
}

- (void)requestNotificationAuthorizationIfNeeded
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if (![prefs boolForKey:kPrefNotificationsEnabled]) {
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Notification auth error: %@", error);
        }
        self->notificationAuthGranted = granted;
    }];
}

- (void)handleForceAppliedForDevice:(AudioDeviceID)deviceID
                               name:(NSString *)deviceName
                      offendingName:(NSString *)offendingName
{
    NSDate *now = [NSDate date];
    if (lastNotificationTime != nil &&
        [now timeIntervalSinceDate:lastNotificationTime] < kMinNotificationGap) {
        return;
    }

    lastNotificationTime = now;

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    if ([prefs boolForKey:kPrefNotificationsEnabled] && notificationAuthGranted) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"Forced input active";

        NSString *forcedName = deviceName ?: @"selected device";
        if (offendingName != nil) {
            content.body = [NSString stringWithFormat:@"%@ took input control. Forced input back to %@.", offendingName, forcedName];
        } else {
            content.body = [NSString stringWithFormat:@"Another device took input control. Forced input back to %@.", forcedName];
        }

        UNNotificationRequest *request = [UNNotificationRequest
            requestWithIdentifier:[[NSUUID UUID] UUIDString]
                          content:content
                          trigger:nil];

        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:request
             withCompletionHandler:^(NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to post notification: %@", error);
                 }
             }];
    }
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateStartupItemState];
    [self updateToggleStates];
}

@end

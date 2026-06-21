#import "AppDelegate.h"
#import "GBLaunchAtLogin.h"
#import "AudioLock.h"
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

// Notify-on-forced toggles, one per direction. The input key keeps its original
// name ("NotificationsEnabled") for backward compatibility with existing installs.
static NSString* const kPrefNotificationsEnabled = @"NotificationsEnabled";
static NSString* const kPrefOutputNotificationsEnabled = @"OutputNotificationsEnabled";

// NSUserDefaults keys for the forced device id/name, per direction. The input
// keys keep their original names ("Device"/"DeviceName") for backward compat.
static NSString* const kPrefInputDevice = @"Device";
static NSString* const kPrefInputDeviceName = @"DeviceName";
static NSString* const kPrefOutputDevice = @"OutputDevice";
static NSString* const kPrefOutputDeviceName = @"OutputDeviceName";

// Persisted launch-at-login state. The app's actual login-item registration
// lives in SMAppService (queried live by GBLaunchAtLogin), but we also mirror
// it here so the preference is migratable across a future bundle-identifier
// change — the way the device preference is.
static NSString* const kPrefLaunchAtLogin = @"LaunchAtLogin";

// Bundle identifier of the app before the LockAudio rename. Used once, on first
// launch under the new identifier, to migrate the user's saved settings.
static NSString* const kLegacyBundleIdentifier = @"com.audio.locker";

// Minimum gap between forced-device notifications (per direction). Under this
// threshold we treat successive fires as CoreAudio churn (e.g. AirPods settling)
// and suppress; legitimate user-driven switches always exceed this easily.
static const NSTimeInterval kMinNotificationGap = 2.0;


@interface AppDelegate ( )
{
    NSMenu* menu;
    NSStatusItem* statusItem;
    AudioLock* inputLock;
    AudioLock* outputLock;
    NSMenuItem *startupItem;
    NSMenuItem *notificationsItem;
    NSMenuItem *outputNotificationsItem;
    BOOL rebuildingMenu;
    // Suppress the next forced-device notification for a direction after a
    // user-initiated switch (the callback can briefly see the old default and
    // re-force, which would otherwise fire a misleading notification).
    BOOL suppressNextInputNotification;
    BOOL suppressNextOutputNotification;
    NSDate* lastInputNotificationTime;
    NSDate* lastOutputNotificationTime;
    BOOL notificationAuthGranted;
    BOOL screenLocked;
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

    NSLog( @"default device changed" );
    AppDelegate *delegate = (__bridge AppDelegate *)inClientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate listDevices];
    });

    return 0;
}


// Copies the user's settings from the pre-rename app (com.audio.locker) into
// this app's preferences the first time we launch under the new bundle
// identifier. Runs at most once: as soon as a "Device" value exists in our own
// domain, there is nothing to migrate. Reads the legacy domain with
// CFPreferencesCopyAppValue, which works across bundle identifiers.
- ( void ) migrateSettingsFromLegacyBundleIfNeeded
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    // If we already have a saved device, the user has used (or migrated into)
    // this app before — don't touch anything.
    if ( [prefs objectForKey:@"Device"] != nil )
    {
        return;
    }

    CFStringRef legacyID = (__bridge CFStringRef)kLegacyBundleIdentifier;

    id legacyDevice = (__bridge_transfer id)CFPreferencesCopyAppValue(
        CFSTR("Device"), legacyID);

    // No legacy device means this is a genuine fresh install, not an upgrade.
    if ( legacyDevice == nil )
    {
        return;
    }

    [prefs setInteger:[legacyDevice integerValue] forKey:@"Device"];

    id legacyDeviceName = (__bridge_transfer id)CFPreferencesCopyAppValue(
        CFSTR("DeviceName"), legacyID);
    if ( [legacyDeviceName isKindOfClass:[NSString class]] )
    {
        [prefs setObject:legacyDeviceName forKey:@"DeviceName"];
    }

    id legacyNotifications = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kPrefNotificationsEnabled, legacyID);
    if ( legacyNotifications != nil )
    {
        [prefs setBool:[legacyNotifications boolValue] forKey:kPrefNotificationsEnabled];
    }

    // Launch-at-login: the legacy app never persisted this preference (it read
    // SMAppService live), so there is usually nothing to read here. If a value
    // is present and on, re-register LockAudio once so the behaviour carries
    // over. From now on we persist the flag (see toggleStartupItem), so this is
    // the last rename that can lose it.
    id legacyLaunchAtLogin = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kPrefLaunchAtLogin, legacyID);
    if ( [legacyLaunchAtLogin boolValue] && ![GBLaunchAtLogin isLoginItem] )
    {
        [GBLaunchAtLogin addAppAsLoginItem];
        [prefs setBool:YES forKey:kPrefLaunchAtLogin];
    }

    NSLog(@"Migrated settings from legacy bundle %@: Device=%ld name=%@",
          kLegacyBundleIdentifier, (long)[legacyDevice integerValue], legacyDeviceName);
}


- ( void ) applicationDidFinishLaunching : ( NSNotification* ) aNotification
{
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];

    lastInputNotificationTime = nil;
    lastOutputNotificationTime = nil;
    notificationAuthGranted = NO;
    screenLocked = NO;

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self
            selector:@selector(screenDidLock:)
                name:@"com.apple.screenIsLocked"
              object:nil];
    [dnc addObserver:self
            selector:@selector(screenDidUnlock:)
                name:@"com.apple.screenIsUnlocked"
              object:nil];


    // One-time migration of settings from the pre-rename app (com.audio.locker).
    // The rename to LockAudio changed the bundle identifier to com.lockaudio.app,
    // so NSUserDefaults starts empty for upgrading users. Seed it from the old
    // domain's values the first time we launch under the new identifier.
    [self migrateSettingsFromLegacyBundleIfNeeded];

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs registerDefaults:@{
        kPrefNotificationsEnabled: @YES,
        // Output locking is opt-in: notifications default off and no output
        // device is forced until the user chooses one.
        kPrefOutputNotificationsEnabled: @NO,
    }];

    inputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionInput
                                         defaultsKey:kPrefInputDevice
                                     defaultsNameKey:kPrefInputDeviceName];
    [inputLock loadFromDefaults];

    outputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionOutput
                                          defaultsKey:kPrefOutputDevice
                                      defaultsNameKey:kPrefOutputDeviceName];
    [outputLock loadFromDefaults];

    [self requestNotificationAuthorizationIfNeeded];

    NSLog(@"Loaded input lock: %d (%@), output lock: %d (%@)",
          inputLock.forcedID, inputLock.forcedName,
          outputLock.forcedID, outputLock.forcedName);

    NSImage* image = [ NSImage imageNamed : @"airpods-icon" ];
    [ image setTemplate : YES ];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.toolTip = @"LockAudio";
    statusItem.button.image = image;

    // Listen for changes to the default input and output devices.
    AudioObjectPropertyAddress inputDeviceAddress = [inputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &inputDeviceAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    AudioObjectPropertyAddress outputDeviceAddress = [outputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &outputDeviceAddress,
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
    // Each device menu item is tagged with @[ @(direction), @(deviceID) ] so we
    // know which lock the click targets (a device like AirPods can appear in
    // both the input and output lists).
    NSArray *tag = item.representedObject;
    if ( ![tag isKindOfClass:[NSArray class]] || tag.count != 2 )
    {
        return;
    }

    AudioLockDirection direction = (AudioLockDirection)[tag[0] unsignedIntegerValue];
    AudioDeviceID newId = (AudioDeviceID)[tag[1] unsignedIntValue];

    AudioLock *lock = (direction == AudioLockDirectionInput) ? inputLock : outputLock;

    NSLog( @"switching %@ to new device : %u",
           direction == AudioLockDirectionInput ? @"input" : @"output", newId );

    lock.forcedID = newId;
    lock.forcedName = item.title;

    // User-initiated switch: suppress the next forced notification for this
    // direction (see suppressNext*Notification).
    if ( direction == AudioLockDirectionInput ) {
        suppressNextInputNotification = YES;
    } else {
        suppressNextOutputNotification = YES;
    }

    [lock saveToDefaults];
    NSLog(@"Saved %@ device: %d (name: %@)",
          direction == AudioLockDirectionInput ? @"input" : @"output",
          lock.forcedID, lock.forcedName);

    [lock applyForce:newId];

    // Rebuild menu to show updated selection
    dispatch_async(dispatch_get_main_queue(), ^{
        [self listDevices];
    });
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

    menu = [ [ NSMenu alloc ] init ];
    menu.delegate = self;
    [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    // Input section (label, device list, per-direction pause)
    [ menu addItemWithTitle : @"Forced input:" action : nil keyEquivalent : @"" ];
    [ self appendDevicesForLock : inputLock toMenu : menu ];

    NSMenuItem* pauseInput = [ menu
            addItemWithTitle : @"Pause input"
            action : @selector(manualPauseInput:)
            keyEquivalent : @"" ];
    if ( inputLock.paused ) [ pauseInput setState : NSControlStateValueOn ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    // Output section (label, device list, per-direction pause)
    [ menu addItemWithTitle : @"Forced output:" action : nil keyEquivalent : @"" ];
    [ self appendDevicesForLock : outputLock toMenu : menu ];

    NSMenuItem* pauseOutput = [ menu
            addItemWithTitle : @"Pause output"
            action : @selector(manualPauseOutput:)
            keyEquivalent : @"" ];
    if ( outputLock.paused ) [ pauseOutput setState : NSControlStateValueOn ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    startupItem = [ menu
        addItemWithTitle : @"Open at login"
        action : @selector(toggleStartupItem)
        keyEquivalent : @"" ];

    notificationsItem = [ menu
        addItemWithTitle : @"Notify on forced input"
        action : @selector(toggleNotifications)
        keyEquivalent : @"" ];

    outputNotificationsItem = [ menu
        addItemWithTitle : @"Notify on forced output"
        action : @selector(toggleOutputNotifications)
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

    [ self updateToggleStates ];
    [ self updateStartupItemState ];

    [ statusItem setMenu : menu ];

    rebuildingMenu = NO;
    suppressNextInputNotification = NO;
    suppressNextOutputNotification = NO;
}


// Resolves/recovers `lock`'s forced device, appends one menu item per
// participating device (checkmark on the forced one), and re-applies the force
// if another device has stolen the default. Ported from the original
// single-direction listDevices logic.
- ( void ) appendDevicesForLock : ( AudioLock* ) lock toMenu : ( NSMenu* ) targetMenu
{
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

    BOOL isInput = ( lock.direction == AudioLockDirectionInput );
    NSString *dirName = isInput ? @"input" : @"output";
    BOOL forcedDeviceAvailable = NO;

    // Maps deviceID -> name for the participating devices, used to name the
    // "offending" device that stole the default.
    NSMutableDictionary<NSNumber *, NSString *> *idToName = [NSMutableDictionary dictionary];

    if ( lock.forcedID < UINT32_MAX )
    {

        char found = 0;

        for( int index = 0 ;
                 index < numberOfDevices ;
                 index++ )
        {

            if ( dev_array[ index] == lock.forcedID ) found = 1;

        }

        if ( found == 0 )
        {
            NSLog( @"forced %@ not found by ID, searching by name: %@", dirName, lock.forcedName );

            // Device ID changed (e.g. reconnected) — try to find by name
            if ( lock.forcedName != nil )
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

                    if ( [ nameStr isEqualToString : lock.forcedName ] )
                    {
                        NSLog( @"forced %@ recovered by name: %@ -> %u", dirName, nameStr, (unsigned int)dev_array[index] );
                        lock.forcedID = dev_array[index];
                        [lock saveToDefaults];

                        found = 1;
                        forcedDeviceAvailable = YES;
                        break;
                    }
                }
            }

            if ( found == 0 )
            {
                NSLog( @"forced %@ not found in device list", dirName );
                // Don't reset — keep the name so we can recover later
            }
        }
        else
        {
            NSLog( @"forced %@ found in device list", dirName );
            forcedDeviceAvailable = YES;
        }

    }
    else if ( lock.forcedName != nil )
    {
        // forcedID is UINT32_MAX but we have a saved name — device was
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

            if ( [ nameStr isEqualToString : lock.forcedName ] )
            {
                NSLog( @"forced %@ restored from saved name: %@ -> %u", dirName, nameStr, (unsigned int)dev_array[index] );
                lock.forcedID = dev_array[index];
                [lock saveToDefaults];
                forcedDeviceAvailable = YES;
                break;
            }
        }
    }


    for( int index = 0 ;
             index < numberOfDevices ;
             index++ )
    {

        AudioDeviceID oneDeviceID = dev_array[ index ];

        // Only list devices that participate in this lock's direction.
        if ( ![ lock deviceParticipates : oneDeviceID ] )
        {
            continue;
        }

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

        NSLog( @"found %@ device : %s  %u\n" , dirName, deviceName , (unsigned int)oneDeviceID );

        NSString* nameStr = [ NSString stringWithUTF8String : deviceName ];

        // Default the INPUT lock to the built-in device when nothing is saved.
        // Output locking is opt-in, so it has no default device.
        if ( isInput && [ [ nameStr lowercaseString ] containsString : @"built" ]
             && lock.forcedID == UINT32_MAX && lock.forcedName == nil )
        {
            NSLog( @"setting default forced %@ : %s  %u\n" , dirName, deviceName , (unsigned int)oneDeviceID );

            lock.forcedID = oneDeviceID;
            lock.forcedName = nameStr;
            forcedDeviceAvailable = YES;
            [lock saveToDefaults];
        }

        NSMenuItem* item = [ targetMenu
            addItemWithTitle : nameStr
            action : @selector(deviceSelected:)
            keyEquivalent : @"" ];
        item.representedObject = @[ @(lock.direction), @((unsigned int)oneDeviceID) ];

        if ( oneDeviceID == lock.forcedID )
        {
            [ item setState : NSControlStateValueOn ];
            NSLog( @"%@ device selected : %s  %u\n" , dirName, deviceName , (unsigned int)oneDeviceID );
        }

        idToName[ @((unsigned int)oneDeviceID) ] = nameStr;
    }

    free(dev_array);

    // Force the device if needed (the callback will trigger another listDevices)
    AudioDeviceID deviceID = [ lock currentDefaultDevice ];
    NSLog( @"default %@ device is %u" , dirName, deviceID );

    if ( !lock.paused && forcedDeviceAvailable && deviceID != lock.forcedID )
    {
        NSLog( @"forcing %@ device for default : %u" , dirName, lock.forcedID );

        NSString *offendingName = idToName[ @((unsigned int)deviceID) ];

        OSStatus forceStatus = [ lock applyForce : lock.forcedID ];

        BOOL suppress = isInput ? suppressNextInputNotification : suppressNextOutputNotification;

        if ( forceStatus == noErr )
        {
            if ( suppress )
            {
                NSLog( @"suppressing forced-%@ notification for user-initiated switch", dirName );
            }
            else
            {
                [ self handleForceAppliedForLock : lock
                                            name : lock.forcedName
                                   offendingName : offendingName ];
            }
        }
        else
        {
            NSLog( @"force %@ failed: OSStatus %d", dirName, (int)forceStatus );
        }

        // No need to dispatch listDevices here — the CoreAudio property
        // listener callback will fire and call listDevices for us.
    }
    else if ( !lock.paused && !forcedDeviceAvailable && lock.forcedName != nil )
    {
        NSLog( @"skipping %@ force: forced device '%@' is not connected", dirName, lock.forcedName );
    }
}


- ( void ) manualPauseInput : ( NSMenuItem* ) item
{
    inputLock.paused = !inputLock.paused;
    [ self listDevices ];
}

- ( void ) manualPauseOutput : ( NSMenuItem* ) item
{
    outputLock.paused = !outputLock.paused;
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
        // General Sound pane (app now manages both input and output).
        url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Sound-Settings.extension"];
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
    NSTextField *nameLabel = [NSTextField labelWithString:@"LockAudio"];
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
        @[@"https://www.lockaudio.com", @"https://www.lockaudio.com"],
        @[@"https://github.com/jstilwell/LockAudio", @"https://github.com/jstilwell/LockAudio"],
        @[@"contact@lockaudio.com", @"mailto:contact@lockaudio.com"],
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

    // Mirror the resulting state into preferences so it survives a future
    // bundle-identifier change (see migrateSettingsFromLegacyBundleIfNeeded).
    [[NSUserDefaults standardUserDefaults] setBool:[GBLaunchAtLogin isLoginItem]
                                            forKey:kPrefLaunchAtLogin];

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
    [outputNotificationsItem setState: [prefs boolForKey:kPrefOutputNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff];
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

- (void)toggleOutputNotifications
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![prefs boolForKey:kPrefOutputNotificationsEnabled];
    [prefs setBool:enabled forKey:kPrefOutputNotificationsEnabled];
    [self updateToggleStates];
    if (enabled) {
        [self requestNotificationAuthorizationIfNeeded];
    }
}

- (void)requestNotificationAuthorizationIfNeeded
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if (![prefs boolForKey:kPrefNotificationsEnabled] &&
        ![prefs boolForKey:kPrefOutputNotificationsEnabled]) {
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

- (void)handleForceAppliedForLock:(AudioLock *)lock
                             name:(NSString *)deviceName
                    offendingName:(NSString *)offendingName
{
    BOOL isInput = (lock.direction == AudioLockDirectionInput);
    NSString *dirWord = isInput ? @"input" : @"output";

    // Per-direction minimum-gap throttle.
    NSDate *now = [NSDate date];
    NSDate *last = isInput ? lastInputNotificationTime : lastOutputNotificationTime;
    if (last != nil && [now timeIntervalSinceDate:last] < kMinNotificationGap) {
        return;
    }
    if (isInput) {
        lastInputNotificationTime = now;
    } else {
        lastOutputNotificationTime = now;
    }

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *enabledKey = isInput ? kPrefNotificationsEnabled : kPrefOutputNotificationsEnabled;

    if ([prefs boolForKey:enabledKey] && notificationAuthGranted && !screenLocked) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = isInput ? @"Forced input active" : @"Forced output active";

        NSString *forcedName = deviceName ?: @"selected device";
        if (offendingName != nil) {
            content.body = [NSString stringWithFormat:@"%@ took %@ control. Forced %@ back to %@.", offendingName, dirWord, dirWord, forcedName];
        } else {
            content.body = [NSString stringWithFormat:@"Another device took %@ control. Forced %@ back to %@.", dirWord, dirWord, forcedName];
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

- (void)screenDidLock:(NSNotification *)note
{
    screenLocked = YES;
}

- (void)screenDidUnlock:(NSNotification *)note
{
    screenLocked = NO;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateStartupItemState];
    [self updateToggleStates];
}

@end
